! Copyright (c) 2013,  Los Alamos National Security, LLC (LANS)
! and the University Corporation for Atmospheric Research (UCAR).
!
! Unless noted otherwise source code is licensed under the BSD license.
! Additional copyright and license information can be found in the LICENSE file
! distributed with this code, or at http://mpas-dev.github.com/license.html

!=================================================================================================================
 module mpas_atmphys_rrtmgp_swcloudinit

!RRTMGP shortwave cloud-optics LUT init for MPAS-Atmosphere (Phase 2.2 scaffolding).
!Loads rrtmgp-clouds-sw-g224.nc into a ty_cloud_optics_rrtmgp object using the
!stock load_cld_lutcoeff helper copied from rte-rrtmgp/examples/all-sky.
!Verifies expected g-point and band counts (224 / 14), matching the SW gas-optics
!k-distribution spectral discretization.
!
!This module is standalone at Phase 2.2 -- not yet wired into MPAS's radiation
!driver. Cloud optics is a separate class from gas optics; the LUT carries its
!own band limits and (optionally) g-point limits, so this init has no hard
!dependency on the gas-optics class having been initialized first.

 use iso_fortran_env,         only: error_unit

 use mo_cloud_optics_rrtmgp,  only: ty_cloud_optics_rrtmgp
 use mo_load_cloud_coefficients, &
                              only: load_cld_lutcoeff

 implicit none
 private
 public:: init_rrtmgp_sw_cloud

!Expected dimensions for rrtmgp-clouds-sw-g224.nc (v1.9.2 cloud-optics LUT).
 integer, parameter :: RRTMGP_SW_CLOUD_EXPECTED_NGPT  = 224
 integer, parameter :: RRTMGP_SW_CLOUD_EXPECTED_NBAND = 14

 character(len=*), parameter :: SW_CLOUD_FILENAME = 'rrtmgp-clouds-sw-g224.nc'


 contains


!=================================================================================================================
 subroutine init_rrtmgp_sw_cloud(data_dir,cloud_optics_sw)
!=================================================================================================================

!input arguments:
 character(len=*),                intent(in)    :: data_dir

!output arguments:
 type(ty_cloud_optics_rrtmgp),    intent(inout) :: cloud_optics_sw

!local variables:
 character(len=len_trim(data_dir)+len(SW_CLOUD_FILENAME)+1) :: full_path
 integer :: ngpt,nband

!-----------------------------------------------------------------------------------------------------------------

 full_path = trim(data_dir)//'/'//SW_CLOUD_FILENAME

!load_cld_lutcoeff() is the standard loader from rte-rrtmgp/examples/all-sky; it
!opens the NetCDF file, pulls all cloud-optics LUT arrays, and calls
!cloud_optics_sw%load().
 call load_cld_lutcoeff(cloud_optics_sw,trim(full_path))

!sanity-check the loaded class has the expected g-point/band count.
!ty_cloud_optics_rrtmgp extends ty_optical_props; %get_ngpt() and %get_nband()
!are inherited from the parent.
 ngpt  = cloud_optics_sw%get_ngpt()
 nband = cloud_optics_sw%get_nband()

 if(ngpt /= RRTMGP_SW_CLOUD_EXPECTED_NGPT .or. nband /= RRTMGP_SW_CLOUD_EXPECTED_NBAND) then
    write(error_unit,'(A)')     'init_rrtmgp_sw_cloud: unexpected cloud-optics LUT dimensions'
    write(error_unit,'(A,A)')   '    file     = ',trim(full_path)
    write(error_unit,'(A,I0,A,I0)') '    got ngpt = ',ngpt, ', expected ',RRTMGP_SW_CLOUD_EXPECTED_NGPT
    write(error_unit,'(A,I0,A,I0)') '    got nband= ',nband,', expected ',RRTMGP_SW_CLOUD_EXPECTED_NBAND
    error stop 'init_rrtmgp_sw_cloud: cloud-optics LUT dimension mismatch'
 end if

 end subroutine init_rrtmgp_sw_cloud

!=================================================================================================================
 end module mpas_atmphys_rrtmgp_swcloudinit
!=================================================================================================================
