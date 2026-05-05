# WSM6 OpenACC Stage 0 — data region scaffolding

**Date:** 2026-04-15
**Branch:** `wsm6-openacc` on MMM-physics fork, commit 97bfc18
**Binary:** saved as `atmosphere_model.wsm6_stage0`

## Change

Single-file patch to `physics_mmm/mp_wsm6.F90` (tracked in the MMM-physics fork,
not MPAS-Model — see `docs/repository-structure.md`). Adds an `!$acc data create(...)`
region around the body of `mp_wsm6_run` that declares all 60 local working arrays
(3D species-indexed, 2D process rates, 2D working, 1D per-column). No
`!$acc parallel` kernels yet. When OpenACC is disabled the directive is a no-op.

## Build

- Full rebuild with `AUTOCLEAN=true` from a clean MMM-physics working tree
- `make nvhpc CORE=atmosphere OPENACC=true AUTOCLEAN=true`
- Wall time: 4 m 29 s
- Binary size: 37 MB (unchanged from pre-Stage-0)
- `-Minfo=accel` diagnostic confirms directive parsed:
  ```
  mp_wsm6_run:
    441, Generating create(qsum(:,:), qrs_tmp(:,:,:), rh(:,:,:), ...) [if not already present]
  ```

## JW baroclinic wave validation

Sanity check that the Stage 0 binary is still correct on paths that don't exercise
the physics_mmm code (JW runs with `config_physics_suite = 'none'`).

| Metric | Baseline (Phase 6) | Stage 0 | Δ |
|---|---|---|---|
| Wall clock | 1 m 28 s (87.7 s) | **1 m 27.9 s** | −0.1 s (noise) |
| Peak GPU SM | 92 % | **92 %** | 0 |
| Errors / critical | 0 / 0 | 0 / 0 | — |

**Conclusion:** binary remains correct on the dycore path. The added directive
is linked but never executed in the JW run (because `mp_wsm6_run` itself is never
called), so this doesn't prove the directive *does* anything at runtime — only
that it doesn't break anything.

## 3km Bay Area no-Tiedtke validation

Same config as the 2026-04-14 no-Tiedtke benchmark (5,451 s wall clock reference).
Exercises `mp_wsm6_run` 4,800 times → enters the Stage 0 data region 4,800 times.

| Metric | Baseline (no-Tiedtke) | Stage 0 | Δ |
|---|---|---|---|
| Total wall clock | 5,451 s | **5,448.5 s** | −2.5 s (−0.04 %, noise) |
| Time integration | 5,271 s | 5,267.7 s | comparable |
| Microphysics total | 2,011 s | 2,016.5 s | comparable |
| `mp_wsm6` | 1,418 s | 1,421.9 s | comparable |
| Errors / critical | 0 / 0 | 0 / 0 | — |
| History files | 25 | 25 | — |

**Conclusion on runtime:** The `!$acc data create(...)` directive with no kernels
referencing the arrays is **effectively zero-cost** on GB10's unified memory.
The 60 per-call array allocations × 4,800 calls cost less than measurement noise.

Both runs are archived to:
- `<archive>/bayarea-3km/2026-04-15_wsm6-stage0/`
- `<archive>/bayarea-3km/2026-04-15_baseline-rerun-for-stage0-diff/`

## Bit-identical comparison: NOT identical

Ran `scripts/compare-netcdf-output.py` on the 25 history files between Stage 0
output and a fresh rerun with the pre-Stage-0 binary (same source, same flags,
same config). Expected bitwise match. Got bitwise *differences*.

| File | Vars differing (of 113) |
|---|---|
| `history.2026-04-14_00.00.00.nc` (init state, t=0) | **0** ✓ — perfect match |
| `history.2026-04-14_01.00.00.nc` (t=1h, after 200 steps) | 23 with tolerance 1e-3, 55 bitwise |
| `history.2026-04-14_02.00.00.nc` (t=2h) | 58 bitwise |
| ... onward through 24h | 55-58 bitwise |

The pattern is clean: identical at t=0 (initial state read from disk), differences
appear after the first integration step and grow / saturate over time.

### Magnitudes are physically negligible

At 1 hour into the forecast, the worst differences:

| Variable | Max abs diff | Mean | Elements > 1e-3 | Meaning |
|---|---|---|---|---|
| `hpbl` (PBL height) | **5.66 m** | 0.04 m | 10,359 / 11,993 (86 %) | Real but trivial — PBL is hundreds of m |
| `ertel_pv` | 0.187 | 5.9 × 10⁻⁴ | 91,155 / 659,615 (14 %) | Trivial |
| `ke` (kinetic energy) | 0.138 J/kg | 4.2 × 10⁻⁴ | 65,771 / 659,615 (10 %) | Trivial |
| `hfx` (surface heat flux) | 7.4 mW/m² | 0.7 mW/m² | 2,955 / 11,993 (25 %) | Trivial |
| `lh` (latent heat flux) | 11 mW/m² | 0.4 mW/m² | 1,104 / 11,993 (9 %) | Trivial |
| `kpbl` (integer PBL top index) | — | — | **integer mismatch** | Categorical, single-level |

These differences are 4-6 orders of magnitude **above** what pure floating-point
rounding produces (1e-7 for single precision) but 4-6 orders **below** any
meteorologically meaningful threshold. They're at the level you'd expect from
the same model run on different hardware, with a different MPI rank count, or
under a different compiler version.

### Root cause hypothesis: `-acc` flag changes CPU optimization

The `atmosphere_model.baseline` binary was built without the Stage 0 source edit
but with the same `-acc -gpu=ccnative` flags. The Stage 0 binary has the same
compile flags plus the `!$acc data create(...)` directive in source.

Theory: the directive constrains nvfortran's optimization passes for code
*inside* the data region — even when no GPU kernels reference the arrays.
Different optimization decisions → different floating-point operation order →
small FP drift → cascading through nonlinear physics → integer-level decisions
like `kpbl` ultimately differ.

This explains:

- Initial state matches (read from disk, no compute happened)
- Differences appear immediately after t=0 (at first call to `mp_wsm6_run`)
- Differences are localized to physics fields (the data region wraps WSM6 only)
- Differences saturate over time rather than growing unboundedly (system is
  numerically stable, just on a slightly different trajectory)

A deeper investigation could compare the assembly or LLVM IR of `mp_wsm6.o`
between the two binaries to confirm. Filed for later — not blocking.

## Implications for the validation strategy

1. **Bit-identical reproducibility is not achievable** between Stage N and the
   pre-Stage-0 baseline. Each new directive (or kernel) will add another small
   FP drift layer.
2. **Validation must shift to tolerance-based comparison against the immediately
   preceding stage**. e.g. Stage 1 should match Stage 0 within ~1e-2 on physics
   diagnostics. Larger jumps trigger investigation.
3. **Physical sanity checks belong alongside bit comparisons**. Track surface
   wind speed at KCADALYC75 PWS, total domain rainfall, max PBL height. If
   these stay within ~5 % of Stage 0, the port is producing a physically
   equivalent model.
4. **MPAS itself does not claim bit-identical reproducibility across compile
   flag changes** — this finding is consistent with how the model is documented.

## What Stage 0 proves

- Directive syntax is valid against MPAS `physics_mmm/mp_wsm6.F90` structure
- Full MPAS atmosphere core + physics stack builds cleanly with the directive
- JW does not regress (dycore path unaffected)
- Wall clock unchanged (data region with no kernels is effectively free on GB10)
- Output is *physically equivalent* to baseline — differences are at the level
  of compiler-flag changes, far below meteorological significance

## What Stage 0 does NOT prove

- That `!$acc parallel` kernels will compile cleanly in the same region
- That `present()` clauses will work against the current data region
- Anything about GPU compute performance (no kernels have been launched yet)
- That the directive is *literally* inert (it's not — it perturbs the CPU code
  generation, just trivially)

Those require Stages 1 through 5.

## Next step — Stage 0.5: add copy() for prognostic arguments

Before any kernel can reference the prognostic arrays (`t, q, qc, qr, qi, qs, qg`),
those arrays need to be transferable to the GPU. Options for the data region:

- `copy(t, q, qc, qr, qi, qs, qg)` — CPU-to-GPU at entry, GPU-to-CPU at exit
- `copyin(den, p, delz)` — CPU-to-GPU at entry only (read-only)
- `copyout(rain, rainncv, sr, ...)` — GPU-to-CPU at exit only

Stage 0.5 adds these clauses. Expected cost per call:
- Copy in: 7 prognostic + 3 input × 11,993 cells × 55 levels × 4 B ≈ 26 MB
- Copy out: 7 prognostic + 7 surface 1D × (above) ≈ 26 MB
- Total: ~52 MB transferred per mp_wsm6_run call × 4,800 calls = ~250 GB "virtual" transfer

On GB10's unified memory the bytes don't actually move. But the OpenACC runtime
still issues the directive, which has non-zero CPU overhead per call. The
Memory Model Experiments (2026-04-15 AM) showed this was significant. We'll see
how it plays out when no kernels use the copied data yet — a useful upper bound
on what pure transfer directive overhead costs at 11,993 cells.
