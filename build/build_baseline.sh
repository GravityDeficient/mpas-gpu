#!/bin/bash
# build_baseline.sh — build MPAS atmosphere_model with the working GB10 config.
#
# Flags: -gpu=ccnative (Blackwell auto-detect, no memory model override).
# This is the known-good Phase 5 configuration. The -gpu=mem:unified and
# -gpu=mem:managed variants were tested and found to regress performance
# (see docs/memory-model-experiments.md or the private MPAS fork's build log).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../run/setup-env.sh"

cd "${MPAS_ROOT}"

echo "=== Build start: $(date) ==="
echo "=== Cleaning ==="
make clean CORE=atmosphere 2>&1 | tail -5

echo "=== Building with -gpu=ccnative ==="
time make nvhpc CORE=atmosphere OPENACC=true 2>&1 | tee build_baseline.log | tail -30

echo "=== Build end: $(date) ==="

if [ -f atmosphere_model ]; then
  echo "=== Result ==="
  ls -lh atmosphere_model
  strings atmosphere_model | grep -i "OpenACC support" | head -3
else
  echo "BUILD FAILED — no atmosphere_model binary produced"
  exit 1
fi
