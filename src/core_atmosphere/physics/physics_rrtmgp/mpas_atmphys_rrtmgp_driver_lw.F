! Copyright (c) 2013,  Los Alamos National Security, LLC (LANS)
! and the University Corporation for Atmospheric Research (UCAR).
!
! Unless noted otherwise source code is licensed under the BSD license.
! Additional copyright and license information can be found in the LICENSE file
! distributed with this code, or at http://mpas-dev.github.com/license.html

!=================================================================================================================
 module mpas_atmphys_rrtmgp_driver_lw

!RRTMGP longwave radiation driver for MPAS-Atmosphere (Phase 2.4a scaffolding).
!Given a block of atmospheric columns and the pre-loaded RRTMGP class objects
!held in mpas_atmphys_rrtmgp_state, computes clear-sky + clouds longwave fluxes
!(up, down) and layer heating rates.
!
!This module is standalone at Phase 2.4a -- not yet wired into MPAS's radiation
!driver. CPU-only this phase; no OpenACC directives. Aerosol optics are omitted
!(deferred to Phase 2.5). Framework plumbing (Registry pool access, scheme
!switch, Makefile edits) is Phase 2.4b/c.
!
!Sequence (mirrors rte-rrtmgp/examples/all-sky/rrtmgp_allsky.F90 minus aerosols):
!  1. Convert qv (kg/kg) -> VMR (mol/mol) and set h2o in gas_concs
!  2. Allocate gas_props_lw (ty_optical_props_1scl) and source_lw (ty_source_func_lw)
!  3. k_dist_lw%gas_optics(p_lay,p_lev,t_lay,t_sfc,gas_concs, gas_props_lw,source_lw,tlev=t_lev)
!  4. Compute in-cloud LWP/IWP via compute_cloud_paths
!  5. Clamp effective radii via clamp_effective_radii
!  6. cloud_optics_lw%cloud_optics(clwp,ciwp,reliq,reice, cloud_props_lw)
!  7. cloud_props_lw%increment(gas_props_lw)   (gas_props_lw now holds combined optics)
!  8. Broadcast scalar surface emissivity to per-band (nband_lw, ncol) array
!  9. Call rte_lw(gas_props_lw, source_lw, sfc_emis_band, fluxes)
! 10. Convert flux divergence -> heating rate in K/s
!
!All error-returning RRTMGP APIs are checked and fatal on failure.

 use iso_fortran_env,         only: error_unit

 use mo_rte_kind,             only: wp
 use mo_fluxes,               only: ty_fluxes_broadband
 use mo_rte_lw,               only: rte_lw

 use mpas_atmphys_rrtmgp_state,   only: k_dist_lw, cloud_optics_lw, gas_concs, &
                                        gas_props_lw, cloud_props_lw, source_lw, &
                                        ensure_runtime_props_allocated
 use mpas_atmphys_rrtmgp_clouds,  only: compute_cloud_paths, clamp_effective_radii

 implicit none
 private
 public:: rrtmgp_lw_solve

!WMO standard gravitational acceleration (m/s^2).
 real(wp), parameter :: G_ACCEL = 9.80665_wp

!Specific heat of dry air at constant pressure (J/kg/K).
 real(wp), parameter :: CP_DRY  = 1004.64_wp

!Molecular weights used for kg/kg -> mol/mol conversion of water vapor.
!  VMR_h2o = mmr_h2o * (M_air / M_h2o)   where mmr = q / (1 - q)
!For typical atmospheric q (<= 0.03 kg/kg), mmr ~= q to <1% error, and
!resulting VMR remains within the [0, 1] bounds enforced by set_vmr_2d.
 real(wp), parameter :: M_AIR   = 28.97_wp
 real(wp), parameter :: M_H2O   = 18.01_wp


 contains


!=================================================================================================================
 subroutine rrtmgp_lw_solve(p_lay,p_lev,t_lay,t_lev,t_sfc,                     &
                            qv_lay,qc_rad,qi_rad,qs_rad,cldfrac,               &
                            re_cloud_pool,re_ice_pool,re_snow_pool,            &
                            sfc_emis_scalar,                                   &
                            ncol,nlay,                                         &
                            flux_up,flux_dn,heating_rate,                      &
                            o3_vmr)
!=================================================================================================================

!input arguments:
 integer,  intent(in) :: ncol,nlay

 real(wp), intent(in) :: p_lay        (ncol,nlay)
 real(wp), intent(in) :: p_lev        (ncol,nlay+1)
 real(wp), intent(in) :: t_lay        (ncol,nlay)
 real(wp), intent(in) :: t_lev        (ncol,nlay+1)
 real(wp), intent(in) :: t_sfc        (ncol)
 real(wp), intent(in) :: qv_lay       (ncol,nlay)
 real(wp), intent(in) :: qc_rad       (ncol,nlay)
 real(wp), intent(in) :: qi_rad       (ncol,nlay)
 real(wp), intent(in) :: qs_rad       (ncol,nlay)
 real(wp), intent(in) :: cldfrac      (ncol,nlay)
 real(wp), intent(in) :: re_cloud_pool(ncol,nlay)
 real(wp), intent(in) :: re_ice_pool  (ncol,nlay)
 real(wp), intent(in) :: re_snow_pool (ncol,nlay)
 real(wp), intent(in) :: sfc_emis_scalar(ncol)

!optional arguments:
!If o3_vmr is present, the driver sets the O3 VMR on gas_concs per-call, overriding
!the climatological scalar placed there at init time. This is the path used when
!config_o3climatology=true -- MPAS's existing CAM ozone climatology pipeline
!feeds a layer-resolved profile.
 real(wp), intent(in), optional :: o3_vmr(ncol,nlay)

!output arguments:
 real(wp), intent(out) :: flux_up     (ncol,nlay+1)
 real(wp), intent(out) :: flux_dn     (ncol,nlay+1)
 real(wp), intent(out) :: heating_rate(ncol,nlay)

!local variables:
 type(ty_fluxes_broadband)   :: fluxes

 real(wp), dimension(:,:), allocatable, target :: flux_up_loc, flux_dn_loc
 real(wp), dimension(:,:), allocatable         :: h2o_vmr
 real(wp), dimension(:,:), allocatable         :: clwp, ciwp, reliq, reice
 real(wp), dimension(:,:), allocatable         :: sfc_emis_band

 real(wp) :: q, mmr
 integer  :: i,k,nband_lw
 character(len=128) :: err_msg

!gas_props_lw, cloud_props_lw, source_lw come from mpas_atmphys_rrtmgp_state
!as module-scope save vars. They are allocated once by ensure_runtime_props_allocated
!below, then reused for every subsequent radiation call. Do NOT %finalize() them
!at the end of this subroutine -- see the comment in the state module for why.

!-----------------------------------------------------------------------------------------------------------------

!--- 1. Update H2O in gas_concs -----------------------------------------------------------------------------------
!Convert MPAS qv (kg/kg) -> VMR (mol/mol). set_vmr_2d enforces [0,1] bounds.
 allocate(h2o_vmr(ncol,nlay))
 do k = 1,nlay
    do i = 1,ncol
       q = max(0.0_wp,qv_lay(i,k))
       mmr = q / (1.0_wp - q)
       h2o_vmr(i,k) = mmr * (M_AIR / M_H2O)
    end do
 end do

 err_msg = gas_concs%set_vmr('h2o',h2o_vmr)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'rrtmgp_lw_solve: gas_concs%set_vmr(h2o) failed: ',trim(err_msg)
    error stop 'rrtmgp_lw_solve: gas_concs%set_vmr failed'
 end if

!Override the climatological o3 scalar from init with a layer-resolved profile
!if the caller passed one (config_o3climatology=true path).
 if(present(o3_vmr)) then
    err_msg = gas_concs%set_vmr('o3',o3_vmr)
    if(len_trim(err_msg) > 0) then
       write(error_unit,'(A,A)') 'rrtmgp_lw_solve: gas_concs%set_vmr(o3) failed: ',trim(err_msg)
       error stop 'rrtmgp_lw_solve: gas_concs%set_vmr(o3) failed'
    end if
 end if

!--- 2. Ensure the reusable working objects are allocated at the right size ---------------------------------------
!First call or size change allocates/reallocates gas_props_lw/sw, cloud_props_lw/sw,
!source_lw (all held as save in mpas_atmphys_rrtmgp_state). Subsequent matching-size
!calls are a no-op. We allocate BOTH LW and SW working objects from either driver so
!a pure-LW or pure-SW run still does the full setup consistently.
 call ensure_runtime_props_allocated(ncol,nlay)

!--- 3. Gas optics + Planck sources -------------------------------------------------------------------------------
 err_msg = k_dist_lw%gas_optics(p_lay,p_lev,t_lay,t_sfc,gas_concs, &
                                gas_props_lw,source_lw,tlev=t_lev)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'rrtmgp_lw_solve: k_dist_lw%gas_optics failed: ',trim(err_msg)
    error stop 'rrtmgp_lw_solve: k_dist_lw%gas_optics failed'
 end if

!--- 4-6. Cloud optics --------------------------------------------------------------------------------------------
 allocate(clwp (ncol,nlay),ciwp (ncol,nlay))
 allocate(reliq(ncol,nlay),reice(ncol,nlay))

 call compute_cloud_paths(qc_rad,qi_rad,qs_rad,p_lev,cldfrac,clwp,ciwp,ncol,nlay)
 call clamp_effective_radii(re_cloud_pool,re_ice_pool,re_snow_pool,           &
                            qi_rad,qs_rad,cloud_optics_lw,                    &
                            reliq,reice,ncol,nlay)

 err_msg = cloud_optics_lw%cloud_optics(clwp,ciwp,reliq,reice,cloud_props_lw)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'rrtmgp_lw_solve: cloud_optics_lw%cloud_optics failed: ',trim(err_msg)
    error stop 'rrtmgp_lw_solve: cloud_optics_lw%cloud_optics failed'
 end if

!--- 7. Increment gas optics with cloud optics --------------------------------------------------------------------
 err_msg = cloud_props_lw%increment(gas_props_lw)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'rrtmgp_lw_solve: cloud_props_lw%increment failed: ',trim(err_msg)
    error stop 'rrtmgp_lw_solve: cloud_props_lw%increment failed'
 end if

!--- 8. Broadcast scalar surface emissivity to per-band ------------------------------------------------------------
!rte_lw expects sfc_emis(nband, ncol).
 nband_lw = k_dist_lw%get_nband()
 allocate(sfc_emis_band(nband_lw,ncol))
 do i = 1,ncol
    sfc_emis_band(:,i) = sfc_emis_scalar(i)
 end do

!--- 9. Solver ----------------------------------------------------------------------------------------------------
!ty_fluxes_broadband uses pointer members, so we target local allocatables into it.
 allocate(flux_up_loc(ncol,nlay+1),flux_dn_loc(ncol,nlay+1))
 fluxes%flux_up => flux_up_loc
 fluxes%flux_dn => flux_dn_loc

 err_msg = rte_lw(gas_props_lw,source_lw,sfc_emis_band,fluxes)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'rrtmgp_lw_solve: rte_lw failed: ',trim(err_msg)
    error stop 'rrtmgp_lw_solve: rte_lw failed'
 end if

 flux_up = flux_up_loc
 flux_dn = flux_dn_loc

!--- 10. Heating rate from flux divergence (K/s) ------------------------------------------------------------------
!Energy balance on a layer bounded by interfaces k (top) and k+1 (bottom):
!   Q_abs = [F_dn(k) + F_up(k+1)] - [F_up(k) + F_dn(k+1)]
!         = [F_up(k+1) - F_up(k)] - [F_dn(k+1) - F_dn(k)]
!Layer mass per unit area: m = (p_lev(k+1) - p_lev(k)) / g
!Heating rate: dT/dt = Q_abs / (m * cp)
!            = +(g / cp) * Q_abs / (p_lev(k+1) - p_lev(k))
!Convention here: k=1 is top of layer 1; k=nlay+1 is surface; p_lev(k) < p_lev(k+1).
!Sign of leading (g/cp) is positive, NOT negative -- for LW, Q_abs < 0 typically
!(atmospheric cooling to space) and Δp > 0, so dT/dt < 0 (cooling) as expected.
 do k = 1,nlay
    do i = 1,ncol
       heating_rate(i,k) = (G_ACCEL / CP_DRY) *                                           &
            ( (flux_up(i,k+1) - flux_up(i,k)) - (flux_dn(i,k+1) - flux_dn(i,k)) )         &
            / (p_lev(i,k+1) - p_lev(i,k))
    end do
 end do

!--- Cleanup ------------------------------------------------------------------------------------------------------
!The ty_optical_props / ty_source_func_lw objects (gas_props_lw, cloud_props_lw,
!source_lw) are module-scope save vars in mpas_atmphys_rrtmgp_state -- DO NOT
!%finalize() them here. Doing so would defeat the reuse and reintroduce the
!per-call allocation churn that OOM-killed the 24h regression at simulated-hour
!21.5 (2026-04-19). Local allocatables deallocate explicitly below.
 deallocate(h2o_vmr)
 deallocate(clwp,ciwp,reliq,reice)
 deallocate(sfc_emis_band)
 deallocate(flux_up_loc,flux_dn_loc)

 end subroutine rrtmgp_lw_solve

!=================================================================================================================
 end module mpas_atmphys_rrtmgp_driver_lw
!=================================================================================================================
