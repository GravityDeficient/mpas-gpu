! Copyright (c) 2013,  Los Alamos National Security, LLC (LANS)
! and the University Corporation for Atmospheric Research (UCAR).
!
! Unless noted otherwise source code is licensed under the BSD license.
! Additional copyright and license information can be found in the LICENSE file
! distributed with this code, or at http://mpas-dev.github.com/license.html

!=================================================================================================================
 module mpas_atmphys_rrtmgp_state

!Persistent RRTMGP class-object storage for MPAS-Atmosphere (Phase 2.4a scaffolding).
!Holds the four loaded class objects (LW + SW gas optics, LW + SW cloud optics) and
!the reusable ty_gas_concs container as module-scope save variables. All four class
!objects are loaded once from NetCDF at init and reused across every radiation call
!for the remainder of the run.
!
!Only H2O is updated per-timestep in gas_concs (via set_vmr in the driver module).
!Other active gases keep their climatological values established here at init time.
!
!This module is standalone at Phase 2.4a -- not yet wired into MPAS's radiation
!driver. CPU-only this phase; no OpenACC directives. A future phase (2.4b/c) handles
!the framework integration (Registry pool wiring, scheme switch, Makefile edits).

 use iso_fortran_env,         only: error_unit

 use mo_rte_kind,             only: wp
 use mo_gas_concentrations,   only: ty_gas_concs
 use mo_gas_optics_rrtmgp,    only: ty_gas_optics_rrtmgp
 use mo_cloud_optics_rrtmgp,  only: ty_cloud_optics_rrtmgp
 use mo_optical_props,        only: ty_optical_props_1scl, ty_optical_props_2str
 use mo_source_functions,     only: ty_source_func_lw

 use mpas_atmphys_rrtmgp_lwinit,      only: init_rrtmgp_lw
 use mpas_atmphys_rrtmgp_swinit,      only: init_rrtmgp_sw
 use mpas_atmphys_rrtmgp_lwcloudinit, only: init_rrtmgp_lw_cloud
 use mpas_atmphys_rrtmgp_swcloudinit, only: init_rrtmgp_sw_cloud

 implicit none
 private
 public:: mpas_atmphys_rrtmgp_init
 public:: ensure_runtime_props_allocated
 public:: k_dist_lw,      k_dist_sw
 public:: cloud_optics_lw,cloud_optics_sw
 public:: gas_concs
 public:: is_initialized
 public:: gas_props_lw,   cloud_props_lw, source_lw
 public:: gas_props_sw,   cloud_props_sw
 public:: aerosol_props_sw

!The four loaded class objects, persistent across timesteps.
 type(ty_gas_optics_rrtmgp),   save :: k_dist_lw, k_dist_sw
 type(ty_cloud_optics_rrtmgp), save :: cloud_optics_lw, cloud_optics_sw

!Gas concentrations -- reused across timesteps. Only H2O mixing ratio is updated
!per-timestep via set_vmr in the radiation driver; other gases remain at their
!climatological values set below.
 type(ty_gas_concs),           save :: gas_concs

 logical, save :: is_initialized = .false.

!Reusable per-radiation-call working objects. Allocated once on the first call
!via ensure_runtime_props_allocated(ncol,nlay) and then reused for every
!subsequent call. Module-scoping them avoids the 1-5 GB-per-call allocation
!churn that OOM-killed the 24h regression at simulated-hour 21.5 (2026-04-19).
!ty_optical_props_1scl%alloc_1scl(ncol,nlay,ngpt) holds tau(ncol,nlay,ngpt);
!ty_optical_props_2str holds tau+ssa+g (3x the memory). For bayarea-3km with
!ncol=11993, nlay=55, ngpt_lw=256, ngpt_sw=224, the total working-set memory
!is about 11 GB -- well under Huginn's 128 GB, but only if we STOP leaking.
 type(ty_optical_props_1scl), save :: gas_props_lw,  cloud_props_lw
 type(ty_optical_props_2str), save :: gas_props_sw,  cloud_props_sw
 type(ty_source_func_lw),     save :: source_lw

!Phase 2.5 aerosols (SW only, MPAS pass-through). Band-based (nband_sw = 14 for
!RRTMGP SW), populated per-call from MPAS's tauaer_p/ssaaer_p/asyaer_p pool
!arrays when aer_opt > 0. Incremented into gas_props_sw before the rte_sw
!solve; rte-rrtmgp handles band->g-point expansion automatically in %increment.
 type(ty_optical_props_2str), save :: aerosol_props_sw

!Cached dimensions. -1 means "not yet allocated". A size change (e.g. MPI
!rebalance between blocks) triggers finalize + re-alloc; identical sizes are
!a no-op fast path.
 integer, save :: cached_ncol = -1
 integer, save :: cached_nlay = -1

!Active gases for RRTMGP. h2o is updated per-timestep; the others are held at
!climatological scalar VMRs set in mpas_atmphys_rrtmgp_init.
 character(len=3), dimension(8), parameter :: rrtmgp_gas_names = &
   ['h2o','co2','o3 ','n2o','co ','ch4','o2 ','n2 ']

!Climatological volume mixing ratios (mol/mol) for the 7 non-H2O active gases.
!These are contemporary scalar (column-uniform) values; the real ozone field
!is strongly vertical-profile dependent and should be upgraded to a profile
!before any publishable forecast work (TODO Phase 2.5 or later).
!  co2 : ~420 ppm (contemporary)
!  o3  : 1e-6 mol/mol scalar placeholder (real profile tops out ~10 ppm in
!        stratosphere, ~30 ppb at surface)
!  n2o : ~330 ppb
!  co  : ~150 ppb (global mean)
!  ch4 : ~1.92 ppm (contemporary)
!  o2  : 20.9% of dry air
!  n2  : 78.1% of dry air
 character(len=3), dimension(7), parameter :: rrtmgp_clim_gas_names = &
   ['co2','o3 ','n2o','co ','ch4','o2 ','n2 ']
 real(wp),         dimension(7), parameter :: rrtmgp_clim_gas_vmrs = &
   [4.20e-4_wp, 1.0e-6_wp, 3.30e-7_wp, 1.50e-7_wp, 1.921e-6_wp, 0.2090_wp, 0.7810_wp]


 contains


!=================================================================================================================
 subroutine mpas_atmphys_rrtmgp_init(data_dir)
!=================================================================================================================

!input arguments:
 character(len=*), intent(in) :: data_dir

!local variables:
 character(len=128) :: err_msg
 integer            :: igas

!-----------------------------------------------------------------------------------------------------------------

 if(is_initialized) return

!Initialize the gas-concentrations container with the list of active gas names.
!H2O is populated per-timestep by the driver; climatological scalar VMRs for the
!remaining gases are set here and are not re-touched per-timestep.
 err_msg = gas_concs%init(rrtmgp_gas_names)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'mpas_atmphys_rrtmgp_init: gas_concs%init failed: ',trim(err_msg)
    error stop 'mpas_atmphys_rrtmgp_init: gas_concs%init failed'
 end if

!Set the climatological VMRs for the 7 non-H2O gases. gas_optics() dereferences
!every active gas's VMR at call time; without this, the first LW/SW solve aborts
!with "gas <name> concentration hasn't been set".
 do igas = 1,size(rrtmgp_clim_gas_names)
    err_msg = gas_concs%set_vmr(trim(rrtmgp_clim_gas_names(igas)),rrtmgp_clim_gas_vmrs(igas))
    if(len_trim(err_msg) > 0) then
       write(error_unit,'(A,A,A,A)') 'mpas_atmphys_rrtmgp_init: gas_concs%set_vmr(', &
         trim(rrtmgp_clim_gas_names(igas)),') failed: ',trim(err_msg)
       error stop 'mpas_atmphys_rrtmgp_init: gas_concs%set_vmr failed'
    end if
 end do

!Load the four k-distribution / cloud-optics classes from the standard RRTMGP v1.9.2
!NetCDF files. The init helpers validate g-point/band dimensions internally and
!error-stop on mismatch. Gas-optics loaders key their internal initialization off
!gas_concs, so gas_concs must be initialized before the first init_rrtmgp_* call.
 call init_rrtmgp_lw      (data_dir,gas_concs,k_dist_lw)
 call init_rrtmgp_sw      (data_dir,gas_concs,k_dist_sw)
 call init_rrtmgp_lw_cloud(data_dir,cloud_optics_lw)
 call init_rrtmgp_sw_cloud(data_dir,cloud_optics_sw)

 is_initialized = .true.

 end subroutine mpas_atmphys_rrtmgp_init

!=================================================================================================================
 subroutine ensure_runtime_props_allocated(ncol,nlay)
!=================================================================================================================

!Allocates (or re-allocates on size change) the five reusable working objects
!used inside rrtmgp_{lw,sw}_solve:
!  gas_props_lw   (ty_optical_props_1scl)  -- LW gas-optics output
!  cloud_props_lw (ty_optical_props_1scl)  -- LW cloud-optics increment target
!  source_lw      (ty_source_func_lw)      -- LW Planck sources (lay/lev/sfc)
!  gas_props_sw   (ty_optical_props_2str)  -- SW gas-optics output (2-stream)
!  cloud_props_sw (ty_optical_props_2str)  -- SW cloud-optics increment target
!
!First call: all allocations happen. Subsequent calls with matching (ncol,nlay)
!are a no-op (the cached sizes guard). A size change (rare in MPAS but possible
!if MPI repartitions) finalizes the old objects first, then re-allocates.
!
!Caller MUST NOT %finalize() these objects after the per-call solve -- doing so
!defeats the reuse and reintroduces the OOM-leak seen at 2026-04-19 regression.

!input arguments:
 integer, intent(in) :: ncol, nlay

!local variables:
 character(len=128) :: err_msg

!-----------------------------------------------------------------------------------------------------------------

 if(.not. is_initialized) then
    write(error_unit,'(A)') 'ensure_runtime_props_allocated: mpas_atmphys_rrtmgp_init has not been called'
    error stop 'ensure_runtime_props_allocated: state module not initialized'
 end if

!Fast path: sizes match, already allocated.
 if(cached_ncol == ncol .and. cached_nlay == nlay) return

!Size changed (or first allocation). Release any prior allocation before
!re-allocating. finalize is safe to call on never-alloc'd objects (it is
!effectively a no-op on those).
 if(cached_ncol > 0) then
    call gas_props_lw    %finalize()
    call cloud_props_lw  %finalize()
    call source_lw       %finalize()
    call gas_props_sw    %finalize()
    call cloud_props_sw  %finalize()
    call aerosol_props_sw%finalize()
 end if

 err_msg = gas_props_lw%alloc_1scl(ncol,nlay,k_dist_lw)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'ensure_runtime_props_allocated: gas_props_lw%alloc_1scl failed: ',trim(err_msg)
    error stop 'ensure_runtime_props_allocated: gas_props_lw%alloc_1scl failed'
 end if

 err_msg = cloud_props_lw%alloc_1scl(ncol,nlay,cloud_optics_lw)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'ensure_runtime_props_allocated: cloud_props_lw%alloc_1scl failed: ',trim(err_msg)
    error stop 'ensure_runtime_props_allocated: cloud_props_lw%alloc_1scl failed'
 end if

 err_msg = source_lw%alloc(ncol,nlay,k_dist_lw)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'ensure_runtime_props_allocated: source_lw%alloc failed: ',trim(err_msg)
    error stop 'ensure_runtime_props_allocated: source_lw%alloc failed'
 end if

 err_msg = gas_props_sw%alloc_2str(ncol,nlay,k_dist_sw)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'ensure_runtime_props_allocated: gas_props_sw%alloc_2str failed: ',trim(err_msg)
    error stop 'ensure_runtime_props_allocated: gas_props_sw%alloc_2str failed'
 end if

 err_msg = cloud_props_sw%alloc_2str(ncol,nlay,cloud_optics_sw)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'ensure_runtime_props_allocated: cloud_props_sw%alloc_2str failed: ',trim(err_msg)
    error stop 'ensure_runtime_props_allocated: cloud_props_sw%alloc_2str failed'
 end if

!Band-based aerosol optical-props (Phase 2.5). Spectral descriptor comes from
!k_dist_sw's band limits, so rte-rrtmgp can expand to g-points on %increment.
!Band-only init (no band_lims_gpt) -- the %increment against gas_props_sw
!later will auto-expand band values to g-points inside rte-rrtmgp.
 err_msg = aerosol_props_sw%init(band_lims_wvn=k_dist_sw%get_band_lims_wavenumber(), &
                                 name='aerosol_sw')
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'ensure_runtime_props_allocated: aerosol_props_sw%init failed: ',trim(err_msg)
    error stop 'ensure_runtime_props_allocated: aerosol_props_sw%init failed'
 end if
 err_msg = aerosol_props_sw%alloc_2str(ncol,nlay)
 if(len_trim(err_msg) > 0) then
    write(error_unit,'(A,A)') 'ensure_runtime_props_allocated: aerosol_props_sw%alloc_2str failed: ',trim(err_msg)
    error stop 'ensure_runtime_props_allocated: aerosol_props_sw%alloc_2str failed'
 end if

 cached_ncol = ncol
 cached_nlay = nlay

 end subroutine ensure_runtime_props_allocated

!=================================================================================================================
 end module mpas_atmphys_rrtmgp_state
!=================================================================================================================
