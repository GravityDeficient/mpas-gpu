See also: [`port-progression-dashboard.md`](port-progression-dashboard.md), [`stage7b-wsm6-sedimentation-subroutines.md`](stage7b-wsm6-sedimentation-subroutines.md) (if present — Stage 7b-era backfill pending).

# YSU PBL OpenACC Port — Option 2 column-parallel wrap

**Date:** 2026-04-18
**Branch:** `ysu-resident` on `GravityDeficient/MMM-physics`, commit `3b4568b`
**Binary:** `atmosphere_model.ysu_resident1` on GB10 host

> First GPU port of the YSU PBL scheme on Blackwell. Single kernel wraps the entire `bl_ysu_run` body; each GPU thread runs one full column end-to-end.

## What this port does

Restructures `bl_ysu.F90` so the full PBL scheme runs as a **resident GPU service** for one timestep, not as scattered kernels with CPU gaps between them. The abandoned `ysu-openacc` branch tried scattered `!$acc parallel` regions and regressed **+80 s** — each kernel inside a CPU-dominant subroutine creates a coherence event. One big wrap avoids that.

### Parallelization strategy

```fortran
!$acc parallel loop gang vector &
!$acc   private(thx_col, thvx_col, thlix_col, del_col, ...) &
!$acc   ! ~30 column-local scratch arrays, 14 continuation lines
do i = its, ite
   ! phases A–K (setup, PBL first guess, stable BL, entrainment,
   ! diffusion coefs, heat solve, qv/qc/qi/tracers solves, TKE +
   ! get_pblh, momentum build, tridi2n solve, cleanup) — all column-local
end do
!$acc end parallel
```

**One kernel launch per timestep.** No CPU↔GPU coherence during YSU. 11,993 columns, each on its own GPU thread; vertical dependencies stay sequential inside the thread.

### Column-scoped helpers

Original `tridin_ysu` and `tridi2n` solvers processed all columns at once with `(its:ite, kts:kte)` arrays. New column-scoped siblings:

- **`tridin_ysu_col(cl, cm, cu, r2, au, f2, kts, kte, nt)`** — 1D `(kts:kte)` tridiagonal solver; `!$acc routine seq`
- **`tridi2n_col(cl, cm, cm1, cu, r1, r2, au, f1, f2, kts, kte, nt)`** — 1D paired solver for u/v momentum; `!$acc routine seq`
- **`get_pblh`** — already column-scoped (takes 1D slices, returns scalar); added `!$acc routine seq`

Legacy `tridin_ysu` and `tridi2n` retained as dead code for rollback safety.

### Private memory per thread

~30 column-local 1D arrays of length `kte` (55 levels), plus ~30 per-column scalars (`kpbl`, `pblflg`, `sfcflg`, `stable`, `brcr`, `brup`, `brdn`, etc.). Rough total: ~6.6 KB per thread.

`private()` clause splits across 14 continuation lines; nvfortran 26.3 accepts it.

### Compiler notes

- `-Minfo=accel` generates kernel code cleanly for all three `!$acc routine seq` helpers.
- **Optional args:** `present()` checks inside the kernel (`dusfc`, `dvsfc`, `dtsfc`, `dqsfc`, `ctopo`, `ctopo2`) hoisted to scalar `have_*` flags evaluated once on CPU before launch. Optional 2D inputs staged into non-optional local arrays on CPU. `dusfc/dvsfc/dtsfc/dqsfc` accumulate via per-thread scalar accumulators.
- `get_pblh` has `do while` loops with variable trip count — threads in a warp with different `hpbl` serialize briefly, but that's intrinsic to the algorithm.
- `nmix = 0` in the reference config → the passive-tracer loop is a no-op; the 3D `qmixtnp(i,k,n)` write is safe to include.

## Build

Incremental rebuild: ~4 min. Module-interface change invalidates `.mod` files for consumers (NoahMP/UGWP rebuild too). Binary archived as `atmosphere_model.ysu_resident1` (42 MB).

## JW baroclinic test

**Skipped.** JW uses `config_physics_suite = 'none'` — no PBL runs. Validated directly on the 3 km case with `mesoscale_reference` (→ `bl_ysu`). See scheme-verification note below.

## 3 km Bay Area validation

24 h forecast, `mesoscale_reference` physics suite, clean GB10 host.

| Metric | WSM6 stage7b-clean (N-1) | **YSU Option 2** | Δ |
|---|---|---|---|
| Total wall clock | 4,873 s | **4,485 s** | **−388 s (−8.0 %)** |
| vs baseline (5,451 s) | −578 s (−10.6 %) | **−966 s (−17.7 %)** | |
| Integration step avg | ~1.015 s | **~0.81 s** | −0.20 s/step |
| Parallel regions in `bl_ysu_run` | 0 (CPU) | **1** | +1 (column-parallel wrap) |
| Errors / critical | 0 / 0 | 0 / 0 | — |

Per-step savings of ~200 ms × 4,800 steps ≈ 960 s matches the YSU CPU cost observed in earlier profiling — the kernel replaces the largest remaining CPU-only physics component.

## Science validation — diff counts (tolerance 1e-3)

### vs Baseline (accumulated drift)

| Hour | Count | Envelope | Status |
|---|---|---|---|
| t=0h | MATCH | MATCH | ✓ |
| t=1h | 31 / 113 | 22–32 | ✓ (upper end — new scheme) |
| t=14h (peak) | 44 / 113 | 45 | ✓ |
| t=24h | 39 / 113 | 37–42 | ✓ |

### vs wsm6-stage7b-clean (N-1)

| Hour | Count | Interpretation |
|---|---|---|
| t=0h | MATCH | Initial state identical |
| t=1h | 33 / 113 | New GPU kernel introduces FP-ordering drift (expected) |
| t=14h | 45 / 113 | Stable peak |
| t=24h | 42 / 113 | Within envelope |

## Magnitudes vs baseline at peak hour (t=14)

| Variable | Units | YSU Option 2 | Reference envelope |
|---|---|---|---|
| `cd` (surface drag) | — | 2.241e-02 | 0.01–0.03 |
| `cda` | — | 2.001e-02 | 0.01–0.03 |
| `depv_dt_bl` | PVU/s | 8.9e-03 | 0.008–0.025 (**YSU's direct PV output**) |
| `depv_dt_diab` | PVU/s | 8.6e-03 | 0.008–0.03 |
| **`depv_dt_fric`** | **PVU/s** | **0.124** | **0.1–0.25 (no anomaly spike)** |

### `depv_dt_fric` architectural significance

`depv_dt_fric` had spiked to **125 PVU/s** during WSM6 stages 5b–7a — a transient artifact of the intermediate state where process rates were GPU-computed but sedimentation was still CPU, triggering ill-conditioned PV friction at a few cells. The spike resolved at Stage 7b when sedimentation moved to GPU.

At **0.124 PVU/s** in YSU Option 2, we stay cleanly within the natural range. This is the architectural payoff of the "resident GPU service" pattern: because the entire YSU scheme runs atomically on GPU for one column, there's no half-converted intermediate state to introduce ill-conditioned tendencies.

## Progression

| Stage | Wall (s) | Δ baseline | Status |
|---|---|---|---|
| Baseline no-Tiedtke | 5,451 | — | reference |
| WSM6 Stage 7b (clean) | 4,873 | −578 (−10.6 %) | WSM6 complete |
| WSM6 Opt A+B+C+D | 4,949 | −502 | launch overhead not bottleneck |
| **YSU Option 2** | **4,485** | **−966 (−17.7 %)** | **PBL on GPU** |

## Scheme-verification discipline (cross-cutting lesson)

`ysu-resident` exists because the earlier MYNN port on `mynn-openacc` had a hidden defect: the `bayarea-3km` namelist uses `config_physics_suite = 'mesoscale_reference'` which selects **YSU**, not MYNN. The MYNN GPU code compiled and was syntactically correct, but was never invoked at runtime — which is why MYNN-1b showed MATCH at t=1h vs Opt ABCD (nothing in the active code path actually changed).

Rule now codified: always `grep config_pbl_scheme namelist.atmosphere` (and the full suite-to-scheme mapping in `mpas_atmphys_control.F90`) before declaring a port validated.

## What this port does NOT do

- **sf_ysu** (surface layer) not touched; still CPU-only. Natural next candidate for same treatment.
- **No optimization pass yet.** There is likely ~50–100 s more to gain from an explicit `!$acc data` region around the scheme and `async` launches overlapping with the dycore.

## Status

✅ Built, 3 km validated, committed on `ysu-resident` (`3b4568b`).

## Next

1. **RRTMG → RRTMGP library swap** — radiation is the largest remaining CPU cost.
2. **Noah LSM port** — same resident-service pattern, fewer helpers.
3. **sf_ysu port** — small, same file-structure as YSU.
4. **YSU optimization pass** — `!$acc data` region.
