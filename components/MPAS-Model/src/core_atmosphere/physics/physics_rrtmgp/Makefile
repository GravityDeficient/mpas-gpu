.SUFFIXES: .F .F90 .o

.PHONY: physics_rrtmgp physics_rrtmgp_lib

all: dummy physics_rrtmgp

dummy:
	echo "****** compiling physics_rrtmgp ******"

#
# Object order below matches the module `use` graph. Lower lines depend on
# modules defined earlier in the list, so listing in this order keeps the
# default serial compile from tripping on missing .mod files.
#
OBJS = \
	mo_simple_netcdf.o                 \
	mo_load_coefficients.o             \
	mo_load_cloud_coefficients.o       \
	mpas_atmphys_rrtmgp_lwinit.o       \
	mpas_atmphys_rrtmgp_swinit.o       \
	mpas_atmphys_rrtmgp_lwcloudinit.o  \
	mpas_atmphys_rrtmgp_swcloudinit.o  \
	mpas_atmphys_rrtmgp_clouds.o       \
	mpas_atmphys_rrtmgp_state.o        \
	mpas_atmphys_rrtmgp_driver_lw.o    \
	mpas_atmphys_rrtmgp_driver_sw.o

physics_rrtmgp: $(OBJS)

physics_rrtmgp_lib:
	ar -ru ./../libphys.a $(OBJS)

# DEPENDENCIES:
mo_load_coefficients.o:              mo_simple_netcdf.o
mo_load_cloud_coefficients.o:        mo_simple_netcdf.o
mpas_atmphys_rrtmgp_lwinit.o:        mo_load_coefficients.o
mpas_atmphys_rrtmgp_swinit.o:        mo_load_coefficients.o
mpas_atmphys_rrtmgp_lwcloudinit.o:   mo_load_cloud_coefficients.o
mpas_atmphys_rrtmgp_swcloudinit.o:   mo_load_cloud_coefficients.o
mpas_atmphys_rrtmgp_clouds.o:
mpas_atmphys_rrtmgp_state.o: \
	mpas_atmphys_rrtmgp_lwinit.o       \
	mpas_atmphys_rrtmgp_swinit.o       \
	mpas_atmphys_rrtmgp_lwcloudinit.o  \
	mpas_atmphys_rrtmgp_swcloudinit.o
mpas_atmphys_rrtmgp_driver_lw.o: \
	mpas_atmphys_rrtmgp_clouds.o       \
	mpas_atmphys_rrtmgp_state.o
mpas_atmphys_rrtmgp_driver_sw.o: \
	mpas_atmphys_rrtmgp_clouds.o       \
	mpas_atmphys_rrtmgp_state.o

clean:
	$(RM) *.f90 *.o *.mod
	@# Certain systems with intel compilers generate *.i files
	@# This removes them during the clean process
	$(RM) *.i

#
# RRTMGP_PATH / NETCDFF_PATH are exported by the top-level Makefile. The
# system netcdf.mod under /usr/include was built with gfortran and is
# unreadable by nvfortran, so we prepend the nvhpc-built netcdf-fortran
# include path here to win on the command line over $(FCINCLUDES).
#
ifndef RRTMGP_PATH
$(error RRTMGP_PATH is not set. Export to your rte-rrtmgp install prefix, e.g. RRTMGP_PATH=$(CURDIR)/../../../external/rte-rrtmgp/install after running scripts/build-rte-rrtmgp.sh)
endif
ifndef NETCDFF_PATH
$(error NETCDFF_PATH is not set. Export to your netCDF-Fortran (NVHPC-built) install prefix.)
endif
RRTMGP_INCLUDES = -I$(NETCDFF_PATH)/include -I$(RRTMGP_PATH)/include

.F.o:
ifeq "$(GEN_F90)" "true"
	$(CPP) $(CPPFLAGS) $(COREDEF) $(CPPINCLUDES) $< > $*.f90
	$(FC) $(FFLAGS) -c $*.f90 $(RRTMGP_INCLUDES) $(FCINCLUDES) -I.. -I../../../framework -I../../../external/esmf_time_f90
else
	$(FC) $(CPPFLAGS) $(COREDEF) $(FFLAGS) -c $*.F $(RRTMGP_INCLUDES) $(CPPINCLUDES) $(FCINCLUDES) -I.. -I../../../framework -I../../../external/esmf_time_f90
endif

.F90.o:
	$(FC) $(CPPFLAGS) $(COREDEF) $(FFLAGS) -c $*.F90 $(RRTMGP_INCLUDES) $(CPPINCLUDES) $(FCINCLUDES) -I.. -I../../../framework -I../../../external/esmf_time_f90
