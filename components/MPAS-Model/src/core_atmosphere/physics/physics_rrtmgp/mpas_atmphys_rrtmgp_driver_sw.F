! Copyright (c) 2013,  Los Alamos National Security, LLC (LANS)
! and the University Corporation for Atmospheric Research (UCAR).
!
! Unless noted otherwise source code is licensed under the BSD license.
! Additional copyright and license information can be found in the LICENSE file
! distributed with this code, or at http://mpas-dev.github.com/license.html

!=================================================================================================================
 module mpas_atmphys_rrtmgp_driver_sw

!RRTMGP shortwave radiation driver for MPAS-Atmosphere (Phase 2.4a scaffolding).
!Given a block of atmospheric columns and the pre-loaded RRTMGP class objects
!held in mpas_atmphys_rrtmgp_state, computes clear-sky + clouds shortwave fluxes
!(up, down total, down direct beam) and layer heating rates.
!
!This module is standalone at Phase 2.4a -- not yet wired into MPAS's radiation
!driver. CPU-only this phase; no OpenACC directives. Aerosol optics are omitted
!(deferred to Phase 2.5). Framework plumbing (Registry pool access, scheme
!switch, Makefile edits) is Phase 2.4b/c.
!
!Sequence (mirrors rte-rrtmgp/examples/all-sky/rrtmgp_allsky.F90 minus aerosols):
!  1. Convert qv (kg/kg) -> VMR (mol/mol) and set h2o in gas_concs
!  2. Allocate gas_props_sw, cloud_props_sw (both ty_optical_props_2str) and toa_flux
!  3. k_dist_sw%gas_optics(p_lay,p_lev,t_lay,gas_concs, gas_props_sw,toa_flux)
!        (populates toa_flux(ncol,ngpt) via %solar_source internally)
!  4. Compute in-cloud LWP/IWP via compute_cloud_paths
!  5. Clamp effective radii via clamp_effective_radii
!  6. cloud_optics_sw%cloud_optics(clwp,ciwp,reliq,reice, cloud_props_sw)
!  7. cloud_props_sw%delta_scale() + cloud_props_sw%increment(gas_props_sw)
!  8. Broadcast scalar direct/diffuse surface albedos to per-band
!  9. Call rte_sw(gas_props_sw, mu0, toa_flux, sfc_alb_dir,sfc_alb_dif, fluxes)
! 10. Convert flux divergence -> heating rate (K/s)
!
!Notes:
!- SW uses ty_optical_props_2str (tau, ssa, g), not 1scl -- scattering is non-trivial.
!- mu0 is passed as (ncol); rte_sw dispatches to rte_sw_mu0_bycol which broadcasts
!  to (ncol,nlay) internally (SZA constant with height, matching MPAS convention).
!- Heating rate formula is identical to LW (flux-divergence + g/cp).
!- No Planck source -- SW is solar-driven, toa_flux comes from gas_optics output.
!
!All error-returning RRTMGP APIs are checked and fatal on failure.

 use iso_fortran_env,         only: error_unit

 use mo_rte_kind,             only: wp
 use mo_fluxes,               only: ty_fluxes_broadband
 use mo_rte_sw,               only: rte_sw

 use mpas_atmphys_rrtmgp_state,   only: k_dist_sw, cloud_optics_sw, gas_concs, &
                                        gas_props_sw, cloud_props_sw, &
                                        aerosol_props_sw, &
                                        ensure_runtime_props_allocated
 use mpas_atmphys_rrtmgp_clouds,  only: compute_cloud_paths, clamp_effective_radii

 implicit none
 private
 public:: rrtmgp_sw_solve

!WMO standard gravitational acceleration (m/s^2).
 real(wp), parameter :: G_ACCEL = 9.80665_wp

!Specific heat of dry air at constant pressure (J/kg/K).
 real(wp), parameter :: CP_DRY  = 1004.64_wp

!Molecular weights used for kg/kg -> mol/mol conversion of water vapor. See
!mpas_atmphys_rrtmgp_driver_lw for the VMR bound-check rationale.
 real(wp), parameter :: M_AIR   = 28.97_wp
 real(wp), parameter :: M_H2O   = 18.01_wp


 contains


!=================================================================================================================
 subroutine rrtmgp_sw_solve(p_lay,p_lev,t_lay,t_lev,                           &
                            qv_lay,qc_rad,qi_rad,qs_rad,cldfrac,               &
                            re_cloud_pool,re_ice_pool,re_snow_pool,            &
                            mu0,                                               &
                            sfc_albedo_dir_scalar,sfc_albedo_dif_scalar,       &
                            ncol,nlay,                                         &
                            flux_up,flux_dn,flux_dn_dir,                       &
                            heating_rate,                                      &
                            o3_vmr,                                            &
                            aer_tau,aer_ssa,aer_g)
!=================================================================================================================

!input arguments:
 integer,  intent(in) :: ncol,nlay

 real(wp), intent(in) :: p_lay        (ncol,nlay)
 real(wp), intent(in) :: p_lev        (ncol,nlay+1)
 real(wp), intent(in) :: t_lay        (ncol,nlay)
 real(wp), intent(in) :: t_lev        (ncol,nlay+1)
 real(wp), intent(in) :: qv_lay       (ncol,nlay)
 real(wp), intent(in) :: qc_rad       (ncol,nlay)
 real(wp), intent(in) :: qi_rad       (ncol,nlay)
 real(wp), intent(in) :: qs_rad       (ncol,nlay)
 real(wp), intent(in) :: cldfrac      (ncol,nlay)
 real(wp), intent(in) :: re_cloud_pool(ncol,nlay)
 real(wp), intent(in) :: re_ice_pool  (ncol,nlay)
 real(wp), intent(in) :: re_snow_pool (ncol,nlay)
 real(wp), intent(in) :: mu0          (ncol)
 real(wp), intent(in) :: sfc_albedo_dir_scalar(ncol)
 real(wp), intent(in) :: sfc_albedo_dif_scalar(ncol)

!optional arguments:
!If o3_vmr is present, overrides the climatological scalar set at init.
!See rrtmgp_lw_solve for the full comment on this path.
 real(wp), intent(in), optional :: o3_vmr(ncol,nlay)

!Aerosol optical properties (SW only, Phase 2.5 MPAS pass-through). All three
!must be present together -- if so, the module-scope aerosol_props_sw is
!populated and incremented into gas_props_sw before the RTE solve. nband_sw
!is the RRTMGP SW band count (14), matching MPAS's nbndsw = 14. Units: tau
!is dimensionless band-integrated AOD per layer; ssa in [0,1]; g in [-1,1].
 real(wp), intent(in), optional :: aer_tau(:,:,:)   ! (ncol, nlay, nband_sw)
 real(wp), intent(in), optional :: aer_ssa(:,:,:)
 real(wp), intent(in), optional :: aer_g  (:,:,:)

!output arguments:
 real(wp), intent(out) :: flux_up     (ncol,nlay+1)
 real(wp), intent(out) :: flux_dn     (ncol,nlay+1)
 real(wp), intent(out) :: flux_dn_dir (ncol,nlay+1)
 real(wp), intent(out) :: heating_rate(ncol,nlay)

!local variables:
!gas_props_sw, cloud_props_sw come from mpas_atmphys_rrtmgp_state as module-scope
!save vars. They are allocated once by ensure_runtime_props_allocated and reused
!for every subsequent radiation call. Do NOT %finalize() them here -- see the
!state module docstring for why.
 type(ty_fluxes_broadband)   :: fluxes

 real(wp), dimension(:,:), allocatable, target :: flux_up_loc, flux_dn_loc, flux_dir_loc
 real(wp), dimension(:,:), allocatable         :: h2o_vmr
 real(wp), dimension(:,:), allocatable         :: clwp, ciwp, reliq, reice
 real(wp), dimension(:,:), allocatable         :: toa_flux
 real(wp), dimension(:,:), allocatable         :: sfc_alb_dir_band, sfc_alb_dif_band

 ! t_lev is accepted by the driver signature for symmetry with LW, but SW gas_optics
 ! does not require level temperatures -- suppress unused-variable warnings.
 real(wp) :: t_lev_unused

 real(wp) :: q, mmr
 integer  :: i,k,nband_sw,ngpt_sw
 character(len=128) :: err_msg

!-----------------------------------------------------------------------------------------------------------------

 t_lev_unused = t_lev(1,1)   !touch once to silence unused-arg warnings

!--- 1. Update H2O in gas_concs -----------------------------------------------------------------------------------
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
    write(error_unit,'(A,A)') 'rrtmgp_sw_solve: gas_concs%set_vmr(h2o) failed: ',trim(err_msg)
    error stop 'rrtmgp_sw_solve: gas_concs%set_vmr failed'
 end if

!Override the climatological o3 scalar from init with a layer-resolved profile
!if the caller passed one (config_o3climatology=true path).
 if(present(o3_vmr)) then
    err_msg = gas_concs%set_vmr('o3',o3_vmr)
    if(len_trim(err_msg) > 0) then
       write(error_unit,'(A,A)') 'rrtmgp_sw_solve: gas_concs%set_vmr(o3) failed: ',trim(err_msg)
       error stop 'rrtmgp_sw_solve: gas_concs%set_vmr(o3) failed'
    end if
 end if

!--- 2. Ensure the reusable working objects are allocated at the right size, and
!      prep the per-call toa_flux buffer ---
!ensure_runtime_props_allocated handles both LW and SW working props (first-call
!allocate, same-size fast path). toa_flux is small (ncol*ngpt ~= 2.7M doubles for
!bayarea-3km), so it stays as a local allocatable.
 call ensure_runtime_props_allocated(ncol,nlay)
 ngpt_sw = k_dist_sw%get_ngpt()
 allocate(toa_flux(ncol,ngpt_sw))

!--- 3. Gas optics + TOA solar source -----------------------------------------------------------------------------
!For SW, k_dist%gas_optics populates toa_flux(ncol,ngpt) internally via solar_source().
 err_msg = k_dist_sw%gas_optics(p_lay,p_lev,t_lay,gas_concs, &
                                gas_props_sw,toa_flux)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'rrtmgp_sw_solve: k_dist_sw%gas_optics failed: ',trim(err_msg)
    error stop 'rrtmgp_sw_solve: k_dist_sw%gas_optics failed'
 end if

!--- 4-6. Cloud optics --------------------------------------------------------------------------------------------
 allocate(clwp (ncol,nlay),ciwp (ncol,nlay))
 allocate(reliq(ncol,nlay),reice(ncol,nlay))

 call compute_cloud_paths(qc_rad,qi_rad,qs_rad,p_lev,cldfrac,clwp,ciwp,ncol,nlay)
 call clamp_effective_radii(re_cloud_pool,re_ice_pool,re_snow_pool,           &
                            qi_rad,qs_rad,cloud_optics_sw,                    &
                            reliq,reice,ncol,nlay)

 err_msg = cloud_optics_sw%cloud_optics(clwp,ciwp,reliq,reice,cloud_props_sw)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'rrtmgp_sw_solve: cloud_optics_sw%cloud_optics failed: ',trim(err_msg)
    error stop 'rrtmgp_sw_solve: cloud_optics_sw%cloud_optics failed'
 end if

!--- 7. Delta-scale + increment gas optics with cloud optics ------------------------------------------------------
!Delta-scale treatment is used in SW to approximate forward-scattering lobe of the
!phase function (matching the allsky example's do_clouds branch).
 err_msg = cloud_props_sw%delta_scale()
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'rrtmgp_sw_solve: cloud_props_sw%delta_scale failed: ',trim(err_msg)
    error stop 'rrtmgp_sw_solve: cloud_props_sw%delta_scale failed'
 end if

 err_msg = cloud_props_sw%increment(gas_props_sw)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'rrtmgp_sw_solve: cloud_props_sw%increment failed: ',trim(err_msg)
    error stop 'rrtmgp_sw_solve: cloud_props_sw%increment failed'
 end if

!--- 7b. Aerosol optics (optional; MPAS pass-through when aer_opt > 0) --------------------------------------------
!Populate band-based aerosol_props_sw from caller inputs, delta-scale to
!account for the forward-scattering lobe (same as clouds), and increment into
!gas_props_sw. rte-rrtmgp expands band -> g-point inside %increment because
!aerosol_props_sw has band_lims_wvn from k_dist_sw but no band_lims_gpt.
 if(present(aer_tau) .and. present(aer_ssa) .and. present(aer_g)) then
    aerosol_props_sw%tau = aer_tau
    aerosol_props_sw%ssa = aer_ssa
    aerosol_props_sw%g   = aer_g
    err_msg = aerosol_props_sw%delta_scale()
    if(len_trim(err_msg) > 0) then
       write(error_unit,'(A,A)') 'rrtmgp_sw_solve: aerosol_props_sw%delta_scale failed: ',trim(err_msg)
       error stop 'rrtmgp_sw_solve: aerosol_props_sw%delta_scale failed'
    end if
    err_msg = aerosol_props_sw%increment(gas_props_sw)
    if(len_trim(err_msg) > 0) then
       write(error_unit,'(A,A)') 'rrtmgp_sw_solve: aerosol_props_sw%increment failed: ',trim(err_msg)
       error stop 'rrtmgp_sw_solve: aerosol_props_sw%increment failed'
    end if
 end if

!--- 8. Broadcast scalar surface albedos to per-band --------------------------------------------------------------
!rte_sw expects sfc_alb_dir(nband,ncol), sfc_alb_dif(nband,ncol).
 nband_sw = k_dist_sw%get_nband()
 allocate(sfc_alb_dir_band(nband_sw,ncol))
 allocate(sfc_alb_dif_band(nband_sw,ncol))
 do i = 1,ncol
    sfc_alb_dir_band(:,i) = sfc_albedo_dir_scalar(i)
    sfc_alb_dif_band(:,i) = sfc_albedo_dif_scalar(i)
 end do

!--- 9. Solver ----------------------------------------------------------------------------------------------------
!ty_fluxes_broadband uses pointer members, so we target local allocatables into it.
!mu0(ncol) triggers dispatch to rte_sw_mu0_bycol, which broadcasts SZA to all layers.
 allocate(flux_up_loc (ncol,nlay+1))
 allocate(flux_dn_loc (ncol,nlay+1))
 allocate(flux_dir_loc(ncol,nlay+1))
 fluxes%flux_up     => flux_up_loc
 fluxes%flux_dn     => flux_dn_loc
 fluxes%flux_dn_dir => flux_dir_loc

 err_msg = rte_sw(gas_props_sw,mu0,toa_flux,                                  &
                  sfc_alb_dir_band,sfc_alb_dif_band,fluxes)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'rrtmgp_sw_solve: rte_sw failed: ',trim(err_msg)
    error stop 'rrtmgp_sw_solve: rte_sw failed'
 end if

 flux_up     = flux_up_loc
 flux_dn     = flux_dn_loc
 flux_dn_dir = flux_dir_loc

!--- 10. Heating rate from flux divergence (K/s) ------------------------------------------------------------------
!Same formula and sign as LW: dT/dt = +(g/cp) * Q_abs / Δp where
!   Q_abs = [F_up(k+1) - F_up(k)] - [F_dn(k+1) - F_dn(k)]
!For SW, Q_abs > 0 where solar absorption dominates (H2O bands, cloud layers)
!and Δp > 0, so dT/dt > 0 (heating) as expected.
 do k = 1,nlay
    do i = 1,ncol
       heating_rate(i,k) = (G_ACCEL / CP_DRY) *                                           &
            ( (flux_up(i,k+1) - flux_up(i,k)) - (flux_dn(i,k+1) - flux_dn(i,k)) )         &
            / (p_lev(i,k+1) - p_lev(i,k))
    end do
 end do

!--- Cleanup ------------------------------------------------------------------------------------------------------
!gas_props_sw and cloud_props_sw are module-scope save vars in
!mpas_atmphys_rrtmgp_state -- DO NOT %finalize() them here. See state module
!docstring. Only the local allocatables get released.
 deallocate(h2o_vmr)
 deallocate(clwp,ciwp,reliq,reice)
 deallocate(toa_flux)
 deallocate(sfc_alb_dir_band,sfc_alb_dif_band)
 deallocate(flux_up_loc,flux_dn_loc,flux_dir_loc)

 end subroutine rrtmgp_sw_solve

!=================================================================================================================
 end module mpas_atmphys_rrtmgp_driver_sw
!=================================================================================================================
