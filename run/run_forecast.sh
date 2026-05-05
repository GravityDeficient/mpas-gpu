#!/bin/bash
# run_forecast.sh -- run MPAS atmosphere_model in a staged run directory,
# capture the log + GPU monitor, and archive output to long-term storage.
#
# Usage:  RUN_DIR=<abs path> LABEL=<date_config> bash run_forecast.sh
#
# Inputs (required):
#   RUN_DIR       Absolute path to staged run directory containing
#                 atmosphere_model (binary or symlink), namelist.atmosphere,
#                 streams.atmosphere, stream_list.atmosphere.*, mesh .grid.nc,
#                 graph.info*, init .nc, LBC .nc files, static .nc.
#
# Inputs (optional):
#   LABEL         Suffix for archive dir (default: timestamp). Combined with
#                 domain name to form the archive path:
#                 ${MPAS_ARCHIVE}/<domain>/<LABEL>
#   DOMAIN        Domain directory under ${MPAS_ARCHIVE}. Default: basename
#                 of RUN_DIR (e.g. bayarea-3km).
#   RANKS         MPI rank count. Default: 1.
#   ARCHIVE       "yes" (default) to move output to ${MPAS_ARCHIVE} after
#                 completion; "no" to leave files in RUN_DIR.
#   MPAS_ARCHIVE  Long-term archive root. Default: ./output (under RUN_DIR).
#                 Set to a deployment-specific path (e.g. NFS mount) in your
#                 orchestration layer.
#
# Expects setup-env.sh to have been sourced (or NVHPC_SDK/MPAS_ROOT exported).

set -euo pipefail

: "${RUN_DIR:?set RUN_DIR to the absolute path of a staged MPAS run}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/setup-env.sh"

cd "${RUN_DIR}"

RANKS="${RANKS:-1}"
LABEL="${LABEL:-$(date +%Y-%m-%d_%H%M%S)}"
DOMAIN="${DOMAIN:-$(basename "${RUN_DIR}")}"
ARCHIVE="${ARCHIVE:-yes}"
MPAS_ARCHIVE="${MPAS_ARCHIVE:-${RUN_DIR}/output}"

GPU_LOG="${RUN_DIR}/gpu_monitor.${LABEL}.log"
MODEL_LOG="${RUN_DIR}/model.${LABEL}.log"

echo "=== run_forecast.sh ==="
echo "mpirun      : ${NVHPC_MPIRUN}"
echo "ranks       : ${RANKS}"
echo "run dir     : ${RUN_DIR}"
echo "label       : ${LABEL}"
echo "domain      : ${DOMAIN}"
echo "archive     : ${ARCHIVE}"
if [ "${ARCHIVE}" = "yes" ]; then
    echo "archive to  : ${MPAS_ARCHIVE}/${DOMAIN}/${LABEL}"
fi
echo ""

nvidia-smi dmon -s pucvmet -d 5 > "${GPU_LOG}" 2>&1 &
GPU_PID=$!
trap 'kill ${GPU_PID} 2>/dev/null || true' EXIT

START=$(date +%s)
time "${NVHPC_MPIRUN}" ${MPIRUN_FLAGS} -np "${RANKS}" ./atmosphere_model 2>&1 \
    | tee "${MODEL_LOG}"
END=$(date +%s)
ELAPSED=$((END - START))

echo ""
echo "=== forecast complete in ${ELAPSED}s ==="

# Check for clean termination
if grep -q "Finished running the atmosphere core" log.atmosphere.0000.out 2>/dev/null; then
    echo "status: SUCCESS (clean exit)"
    STATUS="success"
else
    echo "status: INCOMPLETE (no 'Finished running' in log)"
    STATUS="incomplete"
fi

if [ "${ARCHIVE}" != "yes" ]; then
    echo "archive skipped (ARCHIVE=${ARCHIVE})"
    exit 0
fi

ARCHIVE_DIR="${MPAS_ARCHIVE}/${DOMAIN}/${LABEL}"
echo ""
echo "=== archiving to ${ARCHIVE_DIR} ==="
mkdir -p "${ARCHIVE_DIR}"

# Move output files (the bulky ones)
for pattern in "history.*.nc" "diag.*.nc" "restart.*.nc" "diag_ugwp.*.nc"; do
    shopt -s nullglob
    files=( ${pattern} )
    shopt -u nullglob
    if [ ${#files[@]} -gt 0 ]; then
        echo "  moving ${#files[@]} ${pattern} files..."
        mv ${pattern} "${ARCHIVE_DIR}/"
    fi
done

# Copy (not move) the smaller config + log artifacts for reproducibility
for f in namelist.atmosphere streams.atmosphere log.atmosphere.0000.out \
         "${MODEL_LOG}" "${GPU_LOG}"; do
    if [ -f "${f}" ]; then
        cp "${f}" "${ARCHIVE_DIR}/"
    fi
done

# Generate a human-readable run info file
cat > "${ARCHIVE_DIR}/RUN_INFO.md" << EOF
# MPAS Forecast Run

- Label        : ${LABEL}
- Domain       : ${DOMAIN}
- Run dir      : ${RUN_DIR}
- Host         : $(hostname)
- Ranks        : ${RANKS}
- Started      : $(date -d @${START} -Iseconds)
- Finished     : $(date -d @${END} -Iseconds)
- Wall time    : ${ELAPSED}s
- Status       : ${STATUS}

## Binary
$(ls -la "${RUN_DIR}/atmosphere_model" 2>/dev/null | sed 's/^/- /')

## Build
$(strings "${RUN_DIR}/atmosphere_model" 2>/dev/null | grep -E "OpenACC support|real precision" | head -5 | sed 's/^/- /')

## Namelist key settings
$(grep -E "config_dt|config_run_duration|config_physics_suite|config_convection_scheme|config_apply_lbcs" namelist.atmosphere 2>/dev/null | sed 's/^/- /')

## Files archived
$(ls "${ARCHIVE_DIR}/" | sed 's/^/- /')
EOF

echo "  archive complete. See ${ARCHIVE_DIR}/RUN_INFO.md"
echo ""
ls -lh "${ARCHIVE_DIR}/" | head -5
