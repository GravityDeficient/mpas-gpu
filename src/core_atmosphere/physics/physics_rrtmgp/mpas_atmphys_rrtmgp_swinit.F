! Copyright (c) 2013,  Los Alamos National Security, LLC (LANS)
! and the University Corporation for Atmospheric Research (UCAR).
!
! Unless noted otherwise source code is licensed under the BSD license.
! Additional copyright and license information can be found in the LICENSE file
! distributed with this code, or at http://mpas-dev.github.com/license.html

!=================================================================================================================
 module mpas_atmphys_rrtmgp_swinit

!RRTMGP shortwave k-distribution init for MPAS-Atmosphere (Phase 2.1 scaffolding).
!Loads rrtmgp-gas-sw-g224.nc into a ty_gas_optics_rrtmgp object using the stock
!load_and_init helper copied from rte-rrtmgp/examples. Verifies expected g-point
!and band counts (224 / 14).
!
!This module is standalone at Phase 2.1 -- not yet wired into MPAS's radiation
!driver. Caller is responsible for having already initialized the ty_gas_concs
!object with the list of active gas names.

 use iso_fortran_env,       only: error_unit

 use mo_gas_concentrations, only: ty_gas_concs
 use mo_gas_optics_rrtmgp,  only: ty_gas_optics_rrtmgp
 use mo_load_coefficients,  only: load_and_init

 implicit none
 private
 public:: init_rrtmgp_sw

!Expected dimensions for rrtmgp-gas-sw-g224.nc (v1.9.2 k-distribution data).
 integer, parameter :: RRTMGP_SW_EXPECTED_NGPT  = 224
 integer, parameter :: RRTMGP_SW_EXPECTED_NBAND = 14

 character(len=*), parameter :: SW_FILENAME = 'rrtmgp-gas-sw-g224.nc'


 contains


!=================================================================================================================
 subroutine init_rrtmgp_sw(data_dir,gas_concs,k_dist_sw)
!=================================================================================================================

!input arguments:
 character(len=*),            intent(in)    :: data_dir
 type(ty_gas_concs),          intent(in)    :: gas_concs

!output arguments:
 type(ty_gas_optics_rrtmgp),  intent(inout) :: k_dist_sw

!local variables:
 character(len=len_trim(data_dir)+len(SW_FILENAME)+1) :: full_path
 integer :: ngpt,nband

!-----------------------------------------------------------------------------------------------------------------

 full_path = trim(data_dir)//'/'//SW_FILENAME

!load_and_init() is the standard loader from rte-rrtmgp/examples; it opens the
!NetCDF file, pulls all k-distribution arrays, and calls k_dist_sw%load().
 call load_and_init(k_dist_sw,trim(full_path),gas_concs)

!sanity-check the loaded class has the expected g-point/band count.
 ngpt  = k_dist_sw%get_ngpt()
 nband = k_dist_sw%get_nband()

 if(ngpt /= RRTMGP_SW_EXPECTED_NGPT .or. nband /= RRTMGP_SW_EXPECTED_NBAND) then
    write(error_unit,'(A)')     'init_rrtmgp_sw: unexpected k-distribution dimensions'
    write(error_unit,'(A,A)')   '    file     = ',trim(full_path)
    write(error_unit,'(A,I0,A,I0)') '    got ngpt = ',ngpt, ', expected ',RRTMGP_SW_EXPECTED_NGPT
    write(error_unit,'(A,I0,A,I0)') '    got nband= ',nband,', expected ',RRTMGP_SW_EXPECTED_NBAND
    error stop 'init_rrtmgp_sw: k-distribution dimension mismatch'
 end if

!Source check: SW k-distribution must carry external (solar) sources.
 if(.not. k_dist_sw%source_is_external()) then
    write(error_unit,'(A)') 'init_rrtmgp_sw: SW k-distribution missing external sources (solar_source_*)'
    error stop 'init_rrtmgp_sw: expected external-source SW k-distribution'
 end if

 end subroutine init_rrtmgp_sw

!=================================================================================================================
 end module mpas_atmphys_rrtmgp_swinit
!=================================================================================================================
