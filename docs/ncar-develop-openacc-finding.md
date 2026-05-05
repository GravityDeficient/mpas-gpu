# NCAR's `atmosphere/develop-openacc` branch

**Discovered:** 2026-04-15, while setting up the MPAS fork on Huginn.
**Impact:** Significant — reshapes the WSM6 port approach from "write from scratch" to "translate proven patterns from NCAR's prior work."

## Summary

MPAS-Dev has an unreleased, stale-but-complete-looking OpenACC physics port on
the `atmosphere/develop-openacc` branch. Key facts:

- **Last commit:** 2023-04-05 (dormant for 2+ years)
- **265 commits ahead** of `upstream/master`
- **931 commits behind** `upstream/master`
- **Never released** — none of v8.0.x, v8.1, v8.2, v8.3 include this work

The branch contains OpenACC directives in nearly every physics routine:

| File (on develop-openacc) | Directive count |
|---|---|
| `src/core_atmosphere/dynamics/mpas_atm_time_integration.F` | 706 |
| `src/core_atmosphere/physics/physics_wrf/module_cu_ntiedtke.F` | 428 |
| `src/core_atmosphere/physics/physics_wrf/module_bl_ysu.F` | 250 |
| `src/core_atmosphere/physics/physics_wrf/module_sf_noahlsm.F` | 210 |
| `src/core_atmosphere/physics/physics_wrf/module_mp_wsm6.F` | **204** |
| `src/core_atmosphere/physics/physics_wrf/module_bl_gwdo.F` | 122 |
| `src/core_atmosphere/physics/mpas_atmphys_driver_convection.F` | 71 |
| `src/core_atmosphere/physics/mpas_atmphys_vars.F` | 61 |
| `src/core_atmosphere/physics/mpas_atmphys_interface.F` | 59 |
| `src/framework/mpas_dmpar.F` | 57 |
| ... plus 10+ more files with partial annotations | |

## The layout-drift problem

Between 2023 (last develop-openacc commit) and 2024 (master), MPAS-Dev reorganized
their physics tree. The key difference for WSM6:

| Branch | File location | Nature |
|---|---|---|
| develop-openacc (2023) | `physics_wrf/module_mp_wsm6.F` | **Full implementation** (all WSM6 code) |
| master / v8.3.1 (current) | `physics_wrf/module_mp_wsm6.F` | **Thin wrapper** (239 lines, just calls `mp_wsm6_run`) |
| master / v8.3.1 (current) | `physics_mmm/mp_wsm6.F90` | **Full implementation** (2,449 lines, extensively cleaned up and CCPP-compliant) |

NCAR's directives on develop-openacc annotate the old monolithic file. To use
their work against v8.3.1, we need to *translate* their directive patterns onto
the newer `physics_mmm/mp_wsm6.F90`.

The WSM6 science is effectively unchanged. Loop structure, data dependencies,
and the process-rate calculations are essentially the same. Directive placement
should transfer with minimal reasoning.

## Why NCAR may have stopped

No documented reason. Hypotheses, ranked by plausibility:

1. **Insufficient speedup at tested scales.** develop-openacc was developed against
   discrete GPUs (V100/A100 era), where host↔device transfer overhead limits
   benefit. If their benchmarks showed marginal gains on their hardware, the
   team may have decided it wasn't worth the mainline-merge complexity.

2. **Merge conflict fatigue.** As mainline physics evolved (Thompson updates,
   new LSM options, driver refactors), keeping an out-of-tree port synchronized
   became a recurring tax that exceeded its benefits.

3. **Strategic reprioritization.** Around 2022-2023, NVIDIA's Earth-2 and AI
   weather model work accelerated. NCAR's GPU efforts may have shifted toward
   ML-based parameterizations rather than porting legacy Fortran physics.

4. **Specific bugs or correctness issues.** Porting microphysics to GPU commonly
   introduces tiny floating-point deltas that fail regression tests. If the
   team couldn't reconcile bitwise-identical output (or convince maintainers
   that the deltas were physically acceptable), the work would stall in review.

## Implication for our project

**Our novelty shifts, but in our favor:**

| Before this finding | After this finding |
|---|---|
| Port WSM6 from scratch | Translate NCAR's proven directive patterns onto v8.3.1 |
| Design own `!$acc` placement | Have a working reference to copy from |
| Validate our annotations work | Only need to validate the translation |
| "Novel WSM6 GPU port" | "First benchmark of NCAR's unreleased physics-GPU work on Grace Blackwell, with proposed resurrection path" |
| 2–4 week WSM6 port effort | 3–5 days to translate + rebuild + validate |

**The project is still genuinely novel because:**

- **No one has benchmarked develop-openacc on Grace Blackwell.** GB10 didn't
  exist when this code was written. Unified memory + Blackwell IST changes the
  performance calculus that may have killed the project originally.
- **If the ports work on GB10**, we have a data point for resurrecting the
  mainline merge effort — a contribution NCAR would notice.
- **If the ports *don't* work**, the failure modes are themselves publishable
  findings (e.g., "WSM6 OpenACC port assumes A100 behavior that breaks on
  Blackwell's ITS scheduling").

## Three paths forward

Ranked by speed to first meaningful result:

### A. Build develop-openacc as-is, benchmark

- Check out `upstream/atmosphere/develop-openacc` on a separate worktree
- Build with `-gpu=ccnative` (same Blackwell Makefile patch as our v8.3.1 work)
- Run JW baroclinic wave + physics to see if it builds and runs at all
- If yes, run the Bay Area 3km limited-area case
- Risk: may not build (2+ year old code, library API drift). May not run
  correctly (physics bugs). Uses an old WSM6 file that differs from the
  layout we have benchmarked.
- Time estimate: afternoon to build, evening to benchmark
- **Value:** Fastest way to see real GPU physics performance on GB10

### B. Translate WSM6 directives onto v8.3.1's `physics_mmm/mp_wsm6.F90`

- Use develop-openacc's `module_mp_wsm6.F` as the reference design
- Apply matching directive patterns to our `physics_mmm/mp_wsm6.F90`
- Build v8.3.1 with GPU WSM6, benchmark against baseline
- Cleaner result — we're working on the current code base
- Risk: subtleties in the code reorganization may mean directives need
  non-trivial adaptation. Less likely to compile first try.
- Time estimate: 3–5 days
- **Value:** Produces code suitable for upstreaming to MPAS-Dev — resurrects
  the port on the current mainline, which is what NCAR would actually accept

### C. Cherry-pick develop-openacc commits onto gb10-baseline

- Graft the 265 commits from develop-openacc onto our v8.3.1-based branch
- Resolve conflicts file by file (mostly physics drivers and frameworks)
- Effectively produces a "resurrected develop-openacc" on modern MPAS
- Risk: very high. Merge conflicts across 931 commits of mainline divergence.
  Many physics files have been completely rewritten since 2023. May end up
  spending weeks just reconciling layout changes before any testing.
- Time estimate: 1–3 weeks with no guarantee of producing a working binary
- **Value:** Comprehensive but impractical for a solo effort

## Recommendation

**Do A first (afternoon of work), then use findings to inform B (the real deliverable).**

Path A answers "does GPU physics MPAS work on GB10 at all?" in the shortest
possible time. The answer fundamentally shapes everything else:

- **If yes** — we know the approach is viable and can proceed with B confident
  that the translated directives will behave similarly on Blackwell.
- **If no** — we have specific failure modes (build errors, runtime errors,
  silent wrong-answer) to report in the writeup, and B becomes "port WSM6
  fresh with knowledge of what breaks."

Either outcome is publishable. Either outcome produces a concrete contribution
for the MPAS-Dev upstream — either a working port of their abandoned branch, or
a report on what it takes to get physics GPU working on modern unified memory
hardware.
