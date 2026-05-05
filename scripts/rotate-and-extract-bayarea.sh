#!/bin/bash
# rotate-and-extract-bayarea.sh — prepare the Bay Area regional mesh.
#
# Three-stage pipeline:
#   1. Download NCAR's 60km-3km variable-resolution mesh (x20.835586) if missing
#   2. Rotate the refinement zone from 0°N/0°W to Mussel Rock (37.67°N, 122.49°W)
#      using the grid_rotate utility from MPAS-Dev/MPAS-Tools
#   3. Extract the Bay Area subset with MPAS-Limited-Area using bayarea.custom.pts
#
# Usage:
#   MPAS_MESHES=/path/to/meshes \
#   MPAS_TOOLS=/path/to/tools \
#   REPO=/path/to/mpas-gb10 \
#       bash rotate-and-extract-bayarea.sh
#
# Prerequisites:
#   - Python with netCDF4 installed (create a venv if needed)
#   - gfortran + nf-config (for building grid_rotate)
#   - git clone of MPAS-Dev/MPAS-Tools at ${MPAS_TOOLS}/MPAS-Tools
#   - git clone of MPAS-Dev/MPAS-Limited-Area at ${MPAS_TOOLS}/MPAS-Limited-Area

set -euo pipefail

: "${MPAS_MESHES:?set MPAS_MESHES to the mesh directory}"
: "${MPAS_TOOLS:?set MPAS_TOOLS to the tools parent directory}"
: "${REPO:?set REPO to the mpas-gb10 repo root}"
: "${PYTHON_BIN:=python3}"

MESH_URL="https://www2.mmm.ucar.edu/projects/mpas/atmosphere_meshes/x20.835586.tar.gz"
MESH_STEM="x20.835586"
ROTATED_STEM="x20.835586.bayarea"
REGIONAL_STEM="bayarea"

cd "${MPAS_MESHES}"

# Stage 1 — download mesh if missing
if [ ! -f "${MESH_STEM}.grid.nc" ]; then
    echo "=== Downloading ${MESH_STEM} mesh (628 MB) ==="
    wget -c "${MESH_URL}"
    tar xzf "${MESH_STEM}.tar.gz"
fi

# Stage 2 — build grid_rotate if missing
GRID_ROTATE="${MPAS_TOOLS}/MPAS-Tools/mesh_tools/grid_rotate/grid_rotate"
if [ ! -x "${GRID_ROTATE}" ]; then
    echo "=== Building grid_rotate ==="
    (cd "${MPAS_TOOLS}/MPAS-Tools/mesh_tools/grid_rotate" && make)
fi

# Stage 3 — rotate refinement center to Bay Area
cp "${REPO}/configs/grid_rotate/namelist.input.bayarea" namelist.input
cp "${MESH_STEM}.grid.nc" "${ROTATED_STEM}.grid.nc"
"${GRID_ROTATE}" "${MESH_STEM}.grid.nc" "${ROTATED_STEM}.grid.nc"

# Stage 4 — extract Bay Area regional subset
echo "=== Extracting Bay Area regional mesh ==="
cp "${REPO}/configs/bayarea-3km/bayarea.custom.pts" .
"${PYTHON_BIN}" "${MPAS_TOOLS}/MPAS-Limited-Area/create_region" \
    bayarea.custom.pts \
    "${ROTATED_STEM}.grid.nc"

# Stage 5 — partition graph for MPI
echo "=== Partitioning graph for 4 MPI ranks ==="
gpmetis "${REGIONAL_STEM}.graph.info" 4

echo "=== Done. Regional mesh ready: ${MPAS_MESHES}/${REGIONAL_STEM}.grid.nc ==="
ls -lh "${REGIONAL_STEM}.grid.nc" "${REGIONAL_STEM}.graph.info"*
