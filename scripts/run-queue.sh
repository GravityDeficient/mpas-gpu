#!/bin/bash
# run-queue.sh -- sequentially execute a queue of MPAS experiments.
#
# Generic queue runner. Reads a queue file and executes each experiment by
# staging the binary + namelist into the run directory and invoking
# run_forecast.sh. Stops on first failure (default) or continues with
# --keep-going.
#
# Deployment-specific concerns (compute lockfiles, notifications, host-side
# orchestration) are NOT this script's job — wrap it in your own harness if
# you need them. Example wrapper from one deployment:
#   flock /var/lock/compute.lock bash scripts/run-queue.sh queue.txt
#
# Queue file format (one experiment per line, # for comments):
#   label|binary|namelist_variant|run_dir|ranks|duration
#
# Where:
#   label             archive label suffix
#   binary            atmosphere_model.<binary>  (lives in ${MPAS_ROOT})
#   namelist_variant  rrtmg | rrtmgp | (custom config name from configs/)
#   run_dir           subdir under ${MPAS_RUNS} (e.g. bayarea-3km)
#   ranks             MPI rank count
#   duration          run_duration string (e.g. 1_00:00:00 for 24h)
#
# Required environment:
#   MPAS_ROOT         where atmosphere_model.<binary> lives
#   MPAS_RUNS         parent dir for run subdirectories
#   NAMELIST_ROOT     parent dir for canonical namelists (defaults to
#                     ${MPAS_RUNS}/../configs/namelists if unset)
#   LOG_ROOT          where queue logs go (defaults to ./queue-logs)

set -uo pipefail

QUEUE_FILE="${1:?queue file required — first arg}"
KEEP_GOING=0
[[ "${2:-}" == "--keep-going" ]] && KEEP_GOING=1

# Required env (no defaults — caller must set)
: "${MPAS_ROOT:?MPAS_ROOT must be set (path containing atmosphere_model binaries)}"
: "${MPAS_RUNS:?MPAS_RUNS must be set (parent dir for run subdirectories)}"

NAMELIST_ROOT="${NAMELIST_ROOT:-${MPAS_RUNS}/../configs/namelists}"
LOG_ROOT="${LOG_ROOT:-./queue-logs}"
mkdir -p "${LOG_ROOT}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

if [ ! -f "${QUEUE_FILE}" ]; then
    log "FATAL: queue file not found: ${QUEUE_FILE}"
    exit 1
fi

QUEUE_NAME="$(basename "${QUEUE_FILE}" .txt)"
QUEUE_LOG="${LOG_ROOT}/${QUEUE_NAME}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${QUEUE_LOG}") 2>&1

log "=== queue runner starting ==="
log "queue file: ${QUEUE_FILE}"
log "log:        ${QUEUE_LOG}"

TOTAL_ITEMS=$(grep -cE '^[^#[:space:]]' "${QUEUE_FILE}" || echo 0)
log "items:      ${TOTAL_ITEMS}"

ITEM=0
SUCCESS=0
FAILED=0
START_QUEUE=$(date +%s)

while IFS='|' read -r LABEL BINARY NAMELIST RUN_SUBDIR RANKS DURATION; do
    [[ -z "${LABEL// }" || "${LABEL}" =~ ^[[:space:]]*# ]] && continue
    ITEM=$((ITEM + 1))

    log ""
    log "=== [${ITEM}/${TOTAL_ITEMS}] ${LABEL} ==="
    log "  binary:    atmosphere_model.${BINARY}"
    log "  namelist:  ${NAMELIST}"
    log "  run dir:   ${RUN_SUBDIR}"
    log "  ranks:     ${RANKS}"
    log "  duration:  ${DURATION}"

    RUN_DIR="${MPAS_RUNS}/${RUN_SUBDIR}"
    BINARY_PATH="${MPAS_ROOT}/atmosphere_model.${BINARY}"

    if [ ! -x "${BINARY_PATH}" ]; then
        log "  FAIL: binary not found or not executable: ${BINARY_PATH}"
        FAILED=$((FAILED + 1))
        [ "${KEEP_GOING}" -eq 1 ] && continue || break
    fi
    if [ ! -d "${RUN_DIR}" ]; then
        log "  FAIL: run dir not found: ${RUN_DIR}"
        FAILED=$((FAILED + 1))
        [ "${KEEP_GOING}" -eq 1 ] && continue || break
    fi

    # Stage binary
    rm -f "${RUN_DIR}/atmosphere_model"
    ln -s "${BINARY_PATH}" "${RUN_DIR}/atmosphere_model"

    # Stage namelist if a canonical variant exists
    NAMELIST_SRC="${NAMELIST_ROOT}/${RUN_SUBDIR}/namelist.atmosphere.${NAMELIST}"
    if [ -f "${NAMELIST_SRC}" ]; then
        cp "${NAMELIST_SRC}" "${RUN_DIR}/namelist.atmosphere"
        log "  staged namelist: ${NAMELIST_SRC}"
    else
        log "  WARN: no canonical namelist at ${NAMELIST_SRC} — using existing ${RUN_DIR}/namelist.atmosphere"
    fi

    # Patch run_duration in the staged namelist
    sed -i -E "s/(config_run_duration[[:space:]]*=[[:space:]]*).+/\\1'${DURATION}'/" \
        "${RUN_DIR}/namelist.atmosphere"

    # CRITICAL: redirect stdin from /dev/null so mpirun/atmosphere_model
    # don't consume bytes from the queue file (parent's stdin via the
    # `done < "${QUEUE_FILE}"` redirection). Without this, lines past the
    # first item get silently eaten.
    RUN_DIR="${RUN_DIR}" \
    LABEL="$(date +%Y-%m-%d)_${LABEL}" \
    RANKS="${RANKS}" \
    ARCHIVE="${ARCHIVE:-yes}" \
    bash "${RUN_DIR}/run_forecast.sh" < /dev/null
    RC=$?

    if [ ${RC} -eq 0 ]; then
        log "  SUCCESS"
        SUCCESS=$((SUCCESS + 1))
    else
        log "  FAIL: run exit ${RC}"
        FAILED=$((FAILED + 1))
        [ "${KEEP_GOING}" -ne 1 ] && break
    fi
done < "${QUEUE_FILE}"

END_QUEUE=$(date +%s)
TOTAL_MIN=$(( (END_QUEUE - START_QUEUE) / 60 ))

log ""
log "=== queue done ==="
log "success: ${SUCCESS}/${TOTAL_ITEMS}"
log "failed:  ${FAILED}"
log "total wall: ${TOTAL_MIN} min"

[ ${FAILED} -gt 0 ] && exit 1 || exit 0
