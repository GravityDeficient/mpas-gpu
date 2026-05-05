! Copyright (c) 2013,  Los Alamos National Security, LLC (LANS)
! and the University Corporation for Atmospheric Research (UCAR).
!
! Unless noted otherwise source code is licensed under the BSD license.
! Additional copyright and license information can be found in the LICENSE file
! distributed with this code, or at http://mpas-dev.github.com/license.html

!=================================================================================================================
 module mpas_atmphys_rrtmgp_clouds

!RRTMGP cloud-state bridge for MPAS-Atmosphere (Phase 2.3 scaffolding).
!Converts Thompson / WSM6 microphysics pool variables into the in-cloud liquid
!and ice water paths (g/m^2) and clamped effective radii (microns) that
!ty_cloud_optics_rrtmgp%cloud_optics() ingests.
!
!This module is standalone at Phase 2.3 -- not yet wired into MPAS's radiation
!driver. CPU-only this phase; no OpenACC directives. Driver-side plumbing
!(Registry pool access, scheme switch, optical-props increments) is Phase 2.4+.
!
!Design notes:
! - compute_cloud_paths mirrors RRTMG's LW driver (module_ra_rrtmg_lw.F
!   lines 12125-12140). Snow mixing ratio is lumped into the ice water path,
!   matching RRTMG's default iceflglw=3 behavior. Note that RRTMG packs layer
!   pressure thickness in hPa and applies a x100 factor; MPAS already supplies
!   interface pressures in Pa, so the x100 is intentionally omitted here.
! - clamp_effective_radii converts Thompson's effective radii from meters to
!   microns (RRTMGP LUT inputs are in microns) and clamps to the LUT bounds
!   returned by cloud_optics%get_min/max_radius_liq/ice(). Ice radius is a
!   mass-weighted average of Thompson's re_ice and re_snow, weighted by their
!   mixing ratios. LUT bound accessors are cached outside the (i,k) loop.

 use iso_fortran_env,         only: error_unit

 use mo_rte_kind,             only: wp
 use mo_cloud_optics_rrtmgp,  only: ty_cloud_optics_rrtmgp

 implicit none
 private
 public:: compute_cloud_paths, &
          clamp_effective_radii

!WMO standard gravitational acceleration (m/s^2).
 real(wp), parameter :: GRAV = 9.80665_wp

!Effectively-zero total ice mass threshold below which the mass-weighted ice
!radius falls back to Thompson's pure-ice radius.
 real(wp), parameter :: TINY_MASS = 1.0e-20_wp


 contains


!=================================================================================================================
 subroutine compute_cloud_paths(qc_rad,qi_rad,qs_rad,pres2_hyd,cldfrac, &
                                clwp,ciwp,ncol,nlay)
!=================================================================================================================

!input arguments:
 integer,  intent(in) :: ncol,nlay
 real(wp), intent(in) :: qc_rad   (ncol,nlay)
 real(wp), intent(in) :: qi_rad   (ncol,nlay)
 real(wp), intent(in) :: qs_rad   (ncol,nlay)
 real(wp), intent(in) :: pres2_hyd(ncol,nlay+1)
 real(wp), intent(in) :: cldfrac  (ncol,nlay)

!output arguments:
 real(wp), intent(out) :: clwp(ncol,nlay)
 real(wp), intent(out) :: ciwp(ncol,nlay)

!local variables:
 integer  :: i,k
 real(wp) :: dp,gliqwp,gicewp,cf

!-----------------------------------------------------------------------------------------------------------------

!Per-layer grid-box liquid and ice water paths, then rescaled to in-cloud
!values by dividing by the cloud fraction (floored at 0.01 to avoid division
!by zero in clear or near-clear layers).
 do k = 1,nlay
    do i = 1,ncol

       dp     = pres2_hyd(i,k) - pres2_hyd(i,k+1)
       gliqwp =  qc_rad(i,k)                   * dp / GRAV * 1000.0_wp
       gicewp = (qi_rad(i,k) + qs_rad(i,k))    * dp / GRAV * 1000.0_wp

       cf = max(0.01_wp,cldfrac(i,k))

       clwp(i,k) = gliqwp / cf
       ciwp(i,k) = gicewp / cf

    end do
 end do

 end subroutine compute_cloud_paths

!=================================================================================================================
 subroutine clamp_effective_radii(re_cloud_pool,re_ice_pool,re_snow_pool, &
                                  qi_rad,qs_rad,cloud_optics,             &
                                  reliq,reice,ncol,nlay)
!=================================================================================================================

!input arguments:
 integer,                          intent(in) :: ncol,nlay
 real(wp),                         intent(in) :: re_cloud_pool(ncol,nlay)
 real(wp),                         intent(in) :: re_ice_pool  (ncol,nlay)
 real(wp),                         intent(in) :: re_snow_pool (ncol,nlay)
 real(wp),                         intent(in) :: qi_rad       (ncol,nlay)
 real(wp),                         intent(in) :: qs_rad       (ncol,nlay)
 class(ty_cloud_optics_rrtmgp),    intent(in) :: cloud_optics

!output arguments:
 real(wp), intent(out) :: reliq(ncol,nlay)
 real(wp), intent(out) :: reice(ncol,nlay)

!local variables:
 integer  :: i,k
 real(wp) :: re_min_liq,re_max_liq,re_min_ice,re_max_ice
 real(wp) :: reliq_um,reice_um,reice_weighted,total_ice_mass

!Unit conversion: Thompson's pool variables are in meters, RRTMGP LUT is in
!microns.
 real(wp), parameter :: M_TO_UM = 1.0e6_wp

!-----------------------------------------------------------------------------------------------------------------

!Cache LUT radius bounds outside the hot loop. Accessors return microns.
 re_min_liq = cloud_optics%get_min_radius_liq()
 re_max_liq = cloud_optics%get_max_radius_liq()
 re_min_ice = cloud_optics%get_min_radius_ice()
 re_max_ice = cloud_optics%get_max_radius_ice()

 do k = 1,nlay
    do i = 1,ncol

       !--- liquid: direct unit convert + clamp
       reliq_um = re_cloud_pool(i,k) * M_TO_UM
       reliq(i,k) = min(re_max_liq,max(re_min_liq,reliq_um))

       !--- ice: mass-weighted average of Thompson's ice and snow radii
       total_ice_mass = qi_rad(i,k) + qs_rad(i,k)
       if(total_ice_mass > TINY_MASS) then
          reice_weighted = ( qi_rad(i,k)*re_ice_pool (i,k)   &
                           + qs_rad(i,k)*re_snow_pool(i,k) ) &
                         / total_ice_mass
       else
          reice_weighted = re_ice_pool(i,k)
       end if

       reice_um = reice_weighted * M_TO_UM
       reice(i,k) = min(re_max_ice,max(re_min_ice,reice_um))

    end do
 end do

 end subroutine clamp_effective_radii

!=================================================================================================================
 end module mpas_atmphys_rrtmgp_clouds
!=================================================================================================================
