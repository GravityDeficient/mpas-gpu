#!/bin/bash
# build-rte-rrtmgp.sh -- bootstrap build of the rte-rrtmgp submodule with nvfortran.
#
# Usage (from MPAS-Model repo root):
#   ./scripts/build-rte-rrtmgp.sh
#
# Prereqs:
#   * rte-rrtmgp submodule initialized
#       git submodule update --init src/external/rte-rrtmgp
#   * nvhpc (nvfortran) in PATH
#   * NETCDFF_PATH env var pointing at an nvfortran-compatible netcdf-fortran
#     install. Required — script bails if unset. Fresh hosts typically need
#     to build netcdf-fortran 4.6.1 from source with nvfortran first (static
#     libs, --disable-shared, linking system libnetcdf).
#
# Produces:
#   src/external/rte-rrtmgp/install/lib/librte.a, librrtmgp.a
#   src/external/rte-rrtmgp/install/include/*.mod
#
# The top-level Makefile's RRTMGP_PATH default points here, so running this
# once pre-build is enough for `make nvhpc CORE=atmosphere OPENACC=true` to
# pick up the in-tree RRTMGP.

set -euo pipefail

MPAS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTE_DIR="${MPAS_ROOT}/src/external/rte-rrtmgp"
INSTALL_DIR="${RTE_DIR}/install"
BUILD_DIR="${RTE_DIR}/build"

: "${NETCDFF_PATH:?NETCDFF_PATH must be set to your netCDF-Fortran (NVHPC-built) install prefix, e.g. /usr/local/netcdf-fortran-nvhpc}"
NVFORTRAN="${NVFORTRAN:-nvfortran}"
# Phase 3: KERNEL_MODE=default builds the CPU kernels (Phase 2 path).
# KERNEL_MODE=accel uses rte-rrtmgp's pre-annotated OpenACC kernels in the
# accel/ subtrees -- requires passing -acc -gpu=ccnative to nvfortran so the
# directives actually activate. KERNEL_MODE=extern is for user-supplied kernels.
KERNEL_MODE="${KERNEL_MODE:-default}"
# Phase 3 Stage 1 Path B: when KERNEL_MODE=accel, GPU_MEM=managed asks nvfortran
# to make heap allocations managed memory so the accel kernels' internal
# !$acc data copyin/copyout short-circuits to pointer sharing on GB10's
# hardware unified memory. Empty/unset leaves the Stage 0 explicit-data-copy
# behavior in place.
GPU_MEM="${GPU_MEM:-}"

if [ ! -d "${RTE_DIR}/rrtmgp-frontend" ]; then
    echo "error: rte-rrtmgp submodule not initialized. Run:" >&2
    echo "  git submodule update --init src/external/rte-rrtmgp" >&2
    exit 1
fi

if ! command -v "${NVFORTRAN}" >/dev/null; then
    echo "error: ${NVFORTRAN} not in PATH. Load nvhpc module first." >&2
    exit 1
fi

if [ ! -f "${NETCDFF_PATH}/include/netcdf.mod" ]; then
    echo "error: NETCDFF_PATH=${NETCDFF_PATH} missing include/netcdf.mod." >&2
    echo "       Build an nvfortran-compatible netcdf-fortran first, or set" >&2
    echo "       NETCDFF_PATH to point at one." >&2
    exit 1
fi

# Flags depend on KERNEL_MODE: accel needs OpenACC compile flags so the
# !$acc directives in accel/ sources actually produce GPU code. default/extern
# stay CPU-only.
FFLAGS="-O3 -g"
case "${KERNEL_MODE}" in
    accel)
        GPU_ATTR="ccnative"
        if [ "${GPU_MEM}" = "managed" ]; then
            GPU_ATTR="managed,ccnative"
        elif [ -n "${GPU_MEM}" ]; then
            echo "error: GPU_MEM=${GPU_MEM} not recognized (use empty|managed)" >&2
            exit 1
        fi
        FFLAGS="${FFLAGS} -acc -gpu=${GPU_ATTR} -Minfo=accel"
        ;;
    default|extern)
        ;;
    *)
        echo "error: KERNEL_MODE=${KERNEL_MODE} not recognized (use default|accel|extern)" >&2
        exit 1
        ;;
esac

echo "=== rte-rrtmgp build ==="
echo "  repo         : ${RTE_DIR}"
echo "  install      : ${INSTALL_DIR}"
echo "  netcdff      : ${NETCDFF_PATH}"
echo "  KERNEL_MODE  : ${KERNEL_MODE}"
echo "  FFLAGS       : ${FFLAGS}"
echo ""

rm -rf "${BUILD_DIR}" "${INSTALL_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# CMake flags mirror the Phase 1 feasibility probe (reference_rrtmgp_phase1_findings.md).
# RTE_ENABLE_SP=OFF gives double precision (wp=real(8)); our MPAS-side driver
# marshaling aliases rrtmgp_wp => wp for exactly this.
cmake .. \
    -DCMAKE_Fortran_COMPILER="${NVFORTRAN}" \
    -DCMAKE_Fortran_FLAGS="${FFLAGS}" \
    -DRTE_ENABLE_SP=OFF \
    -DKERNEL_MODE="${KERNEL_MODE}" \
    -DBUILD_TESTING=OFF \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_PREFIX_PATH="${NETCDFF_PATH}"

make -j"$(nproc)"
make install

echo ""
echo "=== install tree ==="
ls -la "${INSTALL_DIR}/lib"
echo "  $(ls "${INSTALL_DIR}/include" | wc -l) .mod files in include/"

echo ""
echo "=== DONE ==="
echo "RRTMGP_PATH=${INSTALL_DIR} (top Makefile default picks this up)"
echo "Now: make nvhpc CORE=atmosphere OPENACC=true"
