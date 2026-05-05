! RRTMGP Phase 1 Feasibility Probe — minimal test harness
! Goal: load a k-distribution NetCDF file and query core class properties
program test_harness
  use mo_rte_kind,           only: wp
  use mo_gas_concentrations, only: ty_gas_concs
  use mo_gas_optics_rrtmgp,  only: ty_gas_optics_rrtmgp
  use mo_load_coefficients,  only: load_and_init
  implicit none

  type(ty_gas_optics_rrtmgp) :: k_dist_lw, k_dist_sw
  type(ty_gas_concs)         :: gas_concs
  character(len=3), dimension(8) :: gas_names = &
      ['h2o', 'co2', 'o3 ', 'n2o', 'co ', 'ch4', 'o2 ', 'n2 ']
  character(len=*), parameter :: LW_FILE = &
      '/home/admin/rrtmgp-probe/rrtmgp-data/rrtmgp-gas-lw-g256.nc'
  character(len=*), parameter :: SW_FILE = &
      '/home/admin/rrtmgp-probe/rrtmgp-data/rrtmgp-gas-sw-g224.nc'
  character(len=128) :: err_msg
  integer :: ngpt_lw, nband_lw, ngpt_sw, nband_sw

  print *, '=== RRTMGP Phase 1 Feasibility Probe ==='
  print *, ''

  err_msg = gas_concs%init(gas_names)
  if (len_trim(err_msg) > 0) then
    print *, 'gas_concs%init ERROR: ', trim(err_msg)
    error stop 1
  end if
  print *, 'gas_concs%init: OK with ', size(gas_names), ' gas names'

  print *, ''
  print *, '--- Loading LW k-distribution ---'
  print *, 'File: ', trim(LW_FILE)
  call load_and_init(k_dist_lw, LW_FILE, gas_concs)
  ngpt_lw  = k_dist_lw%get_ngpt()
  nband_lw = k_dist_lw%get_nband()
  print '(A,I0)', 'LW get_ngpt()  = ', ngpt_lw
  print '(A,I0)', 'LW get_nband() = ', nband_lw
  print '(A,L1)', 'LW source_is_internal (should be T) = ', k_dist_lw%source_is_internal()
  print '(A,L1)', 'LW is_loaded (should be T) = ', k_dist_lw%is_loaded()

  print *, ''
  print *, '--- Loading SW k-distribution ---'
  print *, 'File: ', trim(SW_FILE)
  call load_and_init(k_dist_sw, SW_FILE, gas_concs)
  ngpt_sw  = k_dist_sw%get_ngpt()
  nband_sw = k_dist_sw%get_nband()
  print '(A,I0)', 'SW get_ngpt()  = ', ngpt_sw
  print '(A,I0)', 'SW get_nband() = ', nband_sw
  print '(A,L1)', 'SW source_is_external (should be T) = ', k_dist_sw%source_is_external()
  print '(A,L1)', 'SW is_loaded (should be T) = ', k_dist_sw%is_loaded()

  print *, ''
  print *, '=== VERIFICATION ==='
  if (ngpt_lw == 256 .and. ngpt_sw == 224) then
    print *, 'RESULT: PASS  (LW=256, SW=224 as expected)'
    stop 0
  else
    print *, 'RESULT: FAIL  (unexpected ngpt values)'
    error stop 2
  end if
end program test_harness
