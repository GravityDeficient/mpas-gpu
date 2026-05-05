#!/bin/bash
# setup-env.sh — canonical environment setup for MPAS on NVIDIA HPC SDK.
# Source this from any run or build script: `source <path-to-repo>/run/setup-env.sh`
#
# Expected pre-set variables (set in your shell rc, or export before sourcing):
#   NVHPC_SDK     — NVIDIA HPC SDK root, e.g. <NVHPC_SDK_ROOT>
#   MPAS_ROOT     — MPAS-Model source root, e.g. <MPAS_ROOT>
#   MPAS_RUNS     — parent for experiment run directories, e.g. <MPAS_RUNS>
#   MPAS_STATIC   — mpas_static extracted root, e.g. <MPAS_STATIC>
#
# Optional:
#   NVHPC_MPIRUN  — override path to mpirun (default: $NVHPC_SDK/comm_libs/mpi/bin/mpirun)

set -u

: "${NVHPC_SDK:?set NVHPC_SDK to NVIDIA HPC SDK root}"
: "${MPAS_ROOT:?set MPAS_ROOT to MPAS-Model source root}"
: "${MPAS_RUNS:?set MPAS_RUNS to parent run directory}"

export PATH="${NVHPC_SDK}/compilers/bin:${NVHPC_SDK}/comm_libs/mpi/bin:${PATH:-/usr/bin}"
export LD_LIBRARY_PATH="${NVHPC_SDK}/compilers/lib:${NVHPC_SDK}/comm_libs/mpi/lib:${LD_LIBRARY_PATH:-}"
export NETCDF=/usr
export PNETCDF=/usr

export NVHPC_MPIRUN="${NVHPC_MPIRUN:-${NVHPC_SDK}/comm_libs/mpi/bin/mpirun}"

# HCOLL suppresses InfiniBand collective init noise on single-node runs
export MPIRUN_FLAGS="${MPIRUN_FLAGS:-} --mca coll ^hcoll"

set +u
