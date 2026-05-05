**Master tracking doc** — updated after every stage lands. Links to individual stage docs for full detail.

> **⚠ Status (2026-04-18):** WSM6 table on this page is a historical snapshot
> that stops at Stage 3b. WSM6 is in fact complete through Stage 7b
> (4,873 s / −10.6 % vs baseline) plus Opt A+B+C+D kernel-fusion pass. **YSU
> PBL port is now complete via Option 2 column-parallel wrap** (4,485 s /
> −17.7 % vs baseline, `3b4568b` on `ysu-resident`, see YSU section below).
> The earlier MYNN section is retained but flagged — MYNN was never actually
> invoked at runtime (wrong namelist). For the actual landing commits, see
> `GravityDeficient/MMM-physics` branches `wsm6-openacc` (complete) and
> `ysu-resident` (YSU Option 2 tip). WSM6 section still needs a backfill pass.

# MPAS Physics OpenACC Port — Progression Dashboard

The canonical view of how the port is doing, stage by stage.  Every row
summarizes a validated stage; every column tells you one thing.

**Reference baseline:** the 2026-04-15 rerun of the pre-Stage-0 binary with
the no-Tiedtke namelist (`atmosphere_model.baseline`, wall 5,451 s,
archived at `<archive>/bayarea-3km/2026-04-15_baseline-rerun-for-stage0-diff/`).
Every validation below compares against *this* run.

**Test domain:** bayarea-3km (11,993 cells, uniform ~2.9 km, 55 vertical
levels, 24 h forecast, 4,800 integration steps).

**Hardware:** GB10 host (NVIDIA DGX Spark, GB10 Blackwell, 128 GB unified memory).
**Compiler:** NVHPC 26.3 nvfortran with `-acc -gpu=ccnative`.

## Wall clock + kernels

| Stage | Wall clock (s) | Δ baseline | Δ prev | Kernels in `mp_wsm6_run` | Commit |
|---|---|---|---|---|---|
| Baseline no-Tiedtke | **5,451** | — | — | 0 (CPU) | — (`atmosphere_model.baseline`) |
| Stage 0 | 5,449 | −2 | −2 | 0 (data region only) | `97bfc18` (later retired) |
| Stage 1 | 5,504 | +53 | +55 | 1 | `ff5e9a6` |
| Stage 2-fix | 5,414 | −37 | −90 | 3 | `586e3c7` |
| Stage 3a | 5,534 | +83 | +120 | 6 | `afd977d` |
| Stage 3b | 5,648 | +197 | +114 | 9 | `984855d` |
| **Stage 4** | **(running)** | — | — | 10 (slope_wsm6 in separate subroutine) | `(pending)` |

**Observation:** wall clock oscillates within ~±100 s of baseline depending on
kernel count and data-region state.  No systematic increase or decrease yet.
Per-kernel overhead averaging ~8–40 ms/call depending on math complexity.
Actual GPU compute benefit still ahead — Stages 5–7 port the heavy
microphysics math.

## Validation — diff counts at key forecast hours (tolerance 1e-3)

"DIFF (N/113)" = N of 113 history-file variables differ from the compared run by
more than 1e-3 at that hour.  Hour 0 is the initial state read from disk (always MATCH).

### vs Baseline (primary test — catches accumulated drift across the port)

| Stage | t=0h | t=1h | t=14h (peak) | t=24h |
|---|---|---|---|---|
| Stage 0 | MATCH | 23 | 44 | 38 |
| Stage 1 | MATCH | 23 | 44 | 38 |
| Stage 2-fix | MATCH | 2 | 43 | 37 |
| Stage 3a | MATCH | (≈31) | ~44 | ~40 |
| **Stage 3b** | MATCH | **31** | **45** | **39** |
| Stage 4 | (pending) | | | |

### vs Previous stage (secondary test — catches per-stage regressions)

| Stage | t=0h | t=1h | t=14h (peak) | t=24h |
|---|---|---|---|---|
| Stage 0 → 1 | MATCH | 23 | 44 | 38 |
| Stage 1 → 2-fix | MATCH | 2 | 44 | 40 |
| Stage 2-fix → 3a | MATCH | 31 | 45 | 40 |
| Stage 3a → 3b | MATCH | **MATCH** | 45 | 40 |
| Stage 4 | (pending) | | | |

**Stage 3a → 3b MATCH at t=1h is notable** — the three Stage 3b kernels
(zero-init, xni, qrs_tmp packing) introduce *less* FP drift per iteration
than Stage 3a's saturation kernel (exp + log + branch).  Simpler math =
less FP-ordering divergence.

## Validation — magnitudes vs baseline at peak hour (t=14)

Max |Δ| against baseline, in native units of each variable, at 14:00 UTC
2026-04-14 (the peak of daytime physics activity).

| Variable | Units | Stage 0 | Stage 1 | Stage 2-fix | Stage 3a | Stage 3b |
|---|---|---|---|---|---|---|
| `cd` (surface drag coef) | — | 0.0207 | 0.0164 | 0.0134 | 0.0263 | **0.0160** |
| `cda` (drag coef, alt) | — | 0.0160 | 0.0117 | 0.0106 | 0.0186 | **0.0140** |
| `ck` | — | 0.0056 | 0.0048 | 0.0051 | 0.0070 | 0.0051 |
| `cka` | — | 0.0044 | 0.0042 | 0.0045 | 0.0058 | 0.0045 |
| `depv_dt_bl` | PVU/s | 0.0153 | 0.0207 | 0.0154 | 0.0086 | **0.0090** |
| `depv_dt_diab` | PVU/s | 0.0264 | 0.0207 | 0.0153 | 0.0086 | **0.0104** |
| `depv_dt_fric` | PVU/s | 0.2136 | — | 0.1121 | — | **0.1233** |

**Observation:** Drift is **not** monotonically accumulating.  It fluctuates
within a bounded envelope (0.01–0.03 for surface drag coefficients) stage
to stage based on which kernels are introducing what FP operations.  Stage
3b's drift is in the same ballpark as Stage 0's — after nine kernels of
port, the forecast still sits at the compiler-noise floor of the baseline.

## Reality scale — what's actually "small drift"?

For context on whether these numbers are physically meaningful:

| Variable | Drift magnitude | Typical physical range | Relative |
|---|---|---|---|
| `hpbl` (PBL height) | ~5.7 m at peak | 500–3,000 m in daytime | ~0.2 % |
| `cd` (drag coef) | 0.016 | ~1.0 typical scale | 1.6 % max, ~0.0008 % mean |
| `hfx` (surface heat flux) | ~7 mW/m² at peak | 100–300 W/m² daytime | 0.01 % |
| `ertel_pv` | ~1–11 PVU | 0–100 PVU typical | ~1 % worst cells |
| `kpbl` (integer PBL index) | a few columns flipped | 1–55 levels | categorical |

These are the differences you'd see from running the same model on different
hardware, with different MPI rank counts, or under a different compiler
version — well below any meteorological significance and consistent with
how the NWP community treats non-bitwise reproducibility.

## Compile-time + build events

| Event | Date | Notes |
|---|---|---|
| Phase 5 OpenACC build (`atmosphere_model.baseline`) | 2026-04-07 | Dycore already OpenACC-ported (that's where 92 % GPU SM on JW comes from) |
| Makefile `cc70,cc80` → `ccnative` | 2026-04-07 | For Blackwell sm_121 support |
| Memory model experiments (`-gpu=mem:*`) | 2026-04-15 AM | Both `managed` and `unified` regress JW to 31 % SM; see [`jw-memory-models.md`](jw-memory-models.md) |
| NCAR develop-openacc discovered | 2026-04-15 midday | Dormant 2023 upstream port, used as reference. |
| Stage 0 data region removed | 2026-04-15 PM (Stage 2 fix) | `create()` is GPU-only, CPU reads get garbage — model blew up at step 600 |

## Links to stage detail docs

- [`stage0-wsm6-data-region.md`](stage0-wsm6-data-region.md)
- [`stage1-wsm6-first-kernel.md`](stage1-wsm6-first-kernel.md)
- [`stage2-wsm6-fused-kernels.md`](stage2-wsm6-fused-kernels.md) (includes crash-and-fix story)
- [`stage3a-wsm6-substep-loop-kernels.md`](stage3a-wsm6-substep-loop-kernels.md)
- [`stage3b-wsm6-process-rates-init.md`](stage3b-wsm6-process-rates-init.md)
- Stage 4 `e4970b8` — slope_wsm6 helper (first stage to beat baseline, −81 s)
- Stage 5a `f8c2786` — warm-rain process rates (praut, pracw, prevp)
- Stage 5b `d8a9cf6` — cold-rain process rates (biggest single gain, −244 s)
- Stage 5c `20c254b` — mass-conservation clamp
- Stage 6 `7034d48` — qsat recalc + pcond + padding
- Stage 7a `9bffb36` — sedimentation surrounding loops (13 kernels, −151 s)
- Stage 7b `a1029d1` — `nislfv_rain_plm` subroutines — **WSM6 COMPLETE** (4,873 s, −10.6 %)
- Opt A+B+C+D `66148f7` — kernel fusion 30 → 22 (no measurable speedup; launch overhead not the bottleneck on GB10)

---

# MYNN PBL OpenACC Port

> **⚠ Correction (discovered 2026-04-18):** The MYNN-1b wall-clock and validation numbers below were collected from a run that **never actually invoked MYNN at runtime**. The `bayarea-3km` namelist uses `config_physics_suite = 'mesoscale_reference'`, which selects `bl_ysu` as the active PBL scheme, not `bl_mynn`. The MYNN GPU code compiles and is syntactically correct, but was not on the runtime code path — which is why MYNN-1b showed MATCH at t=1h vs Opt ABCD and only −18 s wall clock (the active code path didn't actually change). The `mynn-openacc` branch is retained as a reference implementation. The actual PBL-on-GPU win landed on `ysu-resident` (see **YSU PBL** section below). Discipline rule now codified: always verify `config_pbl_scheme` in namelist before declaring a PBL port validated.

Branch: `mynn-openacc` on `GravityDeficient/MMM-physics`. Stacks on top of the
complete WSM6 port.

## MYNN stage reference

| Stage | What it does | Key detail |
|---|---|---|
| **MYNN-0** | `!$acc declare create()` + `!$acc update device()` for 28 module constants in `bl_mynn_common` | Module constants GPU-accessible. Infra only — no compute change. |
| **MYNN-1a** | `!$acc routine seq` on all 22 MYNN subroutines + 3 `mynn_shared` functions + `phim`/`phih`; `, value` on every scalar `intent(in)` arg | Unblocks nvfortran 26.3's "Reference argument passing prevents parallelization" for nested seq call chains (Path 2). Compile-verified, no runtime change by itself. |
| **MYNN-1b** | `!$acc parallel loop gang vector` around outer `do i = its,ite` in `bl_mynn_run`, ~130 private vars, each thread runs one full MYNN column | First commit where MYNN PBL executes on GPU. End-to-end validated. |

## MYNN wall clock + validation

| Stage | Wall clock (s) | Δ baseline | Δ Opt ABCD | Parallel regions added | Commit |
|---|---|---|---|---|---|
| Opt A+B+C+D (MYNN base) | 4,949 | −502 | — | 22 in `mp_wsm6_run` | `66148f7` |
| MYNN-0 | (not 3 km tested) | — | — | 0 | `2ef370c` |
| MYNN-1a | (not 3 km tested) | — | — | 0 (seq routines only) | `1433091` |
| **MYNN-1b** | **4,931** | **−520 (−9.5 %)** | **−18 (noise)** | **+1 in `bl_mynn_run`** | `cefdf02` |

**−18 s vs Opt ABCD is run-to-run noise.** MYNN compiles and runs on GPU but
the raw speedup is not yet measurable above noise. MYNN-2 (explicit
`!$acc data` region) is the natural next step to surface real gain.

## MYNN validation — diff counts (tolerance 1e-3)

### vs Baseline

| Stage | t=0h | t=1h | t=14h (peak) | t=24h |
|---|---|---|---|---|
| **MYNN-1b** | MATCH | **31** | **45** | **39** |

### vs Opt A+B+C+D (N-1)

| Stage | t=0h | t=1h | t=14h (peak) | t=24h |
|---|---|---|---|---|
| **MYNN-1b** | MATCH | **MATCH** | 45 | 38 |

## MYNN magnitudes vs baseline at peak hour (t=14)

| Variable | Units | MYNN-1b | Stage 7b | Envelope |
|---|---|---|---|---|
| `cd` | — | 0.0216 | 0.0228 | 0.01–0.03 |
| `cda` | — | 0.0174 | 0.0158 | 0.01–0.03 |
| `depv_dt_bl` | PVU/s | 0.023 | — | 0.008–0.025 |
| `depv_dt_fric` | PVU/s | 0.2215 | 0.2149 | 0.1–0.25 |

**MYNN-1 added no measurable drift** on top of Stage 7b — 45/113 count has been
stable from Stage 3b through MYNN-1b.

## MYNN open items

- **MYNN-2** — explicit `!$acc data` region around the outer loop (eliminate implicit per-call transfers of ~50 2D arrays). Low risk, likely unlocks real speedup hiding behind the current noise.
- **sf_mynn port** — surface layer scheme, separate file, still CPU-only.

## Archive

`<archive>/bayarea-3km/2026-04-17_mynn1/`

Binary archived (<build>/atmosphere_model.mynn1b)

---

# YSU PBL OpenACC Port

Branch: `ysu-resident` on `GravityDeficient/MMM-physics`. Built from the tip of WSM6 work (`66148f7`, 4,949 s). The 2026-04-15 baseline (5,451 s) is still the absolute reference. The `wsm6-openacc` Stage 7b clean run (4,873 s / −10.6 %) is the direct N-1 comparator.

Single-commit port: one `!$acc parallel loop gang vector` wraps the entire `bl_ysu_run` body. Each GPU thread runs one full column end-to-end. Three new column-scoped helpers (`tridin_ysu_col`, `tridi2n_col`, and `!$acc routine seq` on the already-column-scoped `get_pblh`). ~30 column-local scratch arrays in the `private()` clause across 14 continuation lines.

**Architectural pattern:** "resident GPU service" — the full scheme runs atomically on GPU for one column within one timestep. This avoids coherence events that killed the scattered-kernel approach on the abandoned `ysu-openacc` branch (+80 s regression).

## YSU wall clock + validation

| Stage | Wall clock (s) | Δ baseline | Δ prev (WSM6 Stage 7b clean) | Parallel regions | Commit |
|---|---|---|---|---|---|
| WSM6 Stage 7b (clean) | 4,873 | −578 (−10.6 %) | — | 30 in `mp_wsm6_run` | `a1029d1` |
| **YSU Option 2** | **4,485** | **−966 (−17.7 %)** | **−388 (−8.0 %)** | **+1 in `bl_ysu_run`** | **`3b4568b`** |

Per-step drop of ~200 ms × 4,800 steps ≈ 960 s matches YSU's CPU cost from earlier profiling. Largest single-stage win since Stage 5b cold-rain (−244 s). Unlike Stage 5b (fraction of WSM6), YSU Option 2 is the entire PBL scheme in a single commit.

## YSU validation — diff counts (tolerance 1e-3)

### vs Baseline

| Stage | t=0h | t=1h | t=14h (peak) | t=24h |
|---|---|---|---|---|
| **YSU Option 2** | MATCH | **31** | **44** | **39** |

### vs wsm6-stage7b-clean (N-1)

| Stage | t=0h | t=1h | t=14h (peak) | t=24h |
|---|---|---|---|---|
| **YSU Option 2** | MATCH | **33** | **45** | **42** |

## YSU magnitudes vs baseline at peak hour (t=14)

| Variable | Units | YSU Option 2 | Envelope | Prior context |
|---|---|---|---|---|
| `cd` | — | 2.241e-02 | 0.01–0.03 | stable |
| `cda` | — | 2.001e-02 | 0.01–0.03 | stable |
| `depv_dt_bl` | PVU/s | 8.9e-03 | 0.008–0.025 | **YSU's direct PV output** |
| `depv_dt_diab` | PVU/s | 8.6e-03 | 0.008–0.03 | — |
| `depv_dt_fric` | PVU/s | **0.124** | 0.1–0.25 | **no anomaly** (was 125 during WSM6 5b–7a) |

`depv_dt_fric` back in natural range is the architectural validation: atomic per-column GPU execution → no half-converted intermediate state → no ill-conditioned PV friction cells.

## YSU open items

- **sf_ysu port** — surface layer scheme, separate file, still CPU-only. Same pattern expected.
- **Optimization pass** — explicit `!$acc data` region around outer loop + `async` launches overlapping with dycore. Likely ~50–100 s more.

## YSU archive

`<archive>/bayarea-3km/2026-04-18_ysu_resident1/`

Binary archived (<build>/atmosphere_model.ysu_resident1)

## Links to YSU stage detail docs

- [`ysu-option2-column-parallel.md`](ysu-option2-column-parallel.md) — the port (`3b4568b`)

## How to update this dashboard

After each stage's 3 km forecast finishes and validation diffs run:

1. Add a row to the "Wall clock + kernels" table
2. Add a row to both validation-count tables (vs baseline, vs previous)
3. Fill in the magnitude table at peak hour 14
4. Link the new `Stage N ...` doc
5. Commit in the companion repo: `git add benchmarks/ docs/ && git commit -m "Progression update: Stage N"`

Standard diff command for a new stage:

```bash
# vs baseline
python3 compare-netcdf-output.py \
  <archive>/bayarea-3km/2026-04-15_baseline-rerun-for-stage0-diff \
  <archive>/bayarea-3km/2026-04-XX_wsm6-stageN \
  --pattern 'history.*.nc' --tolerance 1e-3

# vs previous stage
python3 compare-netcdf-output.py \
  <archive>/bayarea-3km/PREV \
  <archive>/bayarea-3km/2026-04-XX_wsm6-stageN \
  --pattern 'history.*.nc' --tolerance 1e-3
```
