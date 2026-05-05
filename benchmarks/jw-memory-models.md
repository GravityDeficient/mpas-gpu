# JW baroclinic wave — memory model experiments

**Date:** 2026-04-15
**Purpose:** Test whether `-gpu=mem:managed` or `-gpu=mem:unified` eliminates MPAS's
`ACC_data_xfer` overhead on GB10's physically unified memory.
**Result:** Negative. Both flags regress performance significantly.

## Test case

- Jablonowski-Williamson baroclinic wave, 120 timesteps × dt=720 s (1 simulated day)
- Global 40,962-cell icosahedral mesh (`x1.40962`), 26 vertical levels
- `config_physics_suite = 'none'` → pure dynamics, no physics CPU time
- 1 MPI rank on 1 GB10 GPU

## Builds tested

All three built cleanly in ~4.5 minutes and produced a 37 MB OpenACC-enabled binary.

| Build | Flags |
|---|---|
| baseline | `-Mnofma -acc -gpu=ccnative -Minfo=accel` |
| managed | `-Mnofma -acc -gpu=ccnative,managed,deepcopy -Minfo=accel` |
| unified | `-Mnofma -acc -gpu=ccnative,mem:unified -Minfo=accel` |

(`-gpu=managed` in NVHPC 26.3 is translated internally to `-gpu=mem:managed`.
The `-gpu=unified` form is deprecated in favor of the `mem:*` taxonomy.)

## Results

| Build | Wall clock | MPAS total time | Peak GPU SM | Verdict |
|---|---|---|---|---|
| baseline | **1 m 28 s** | 87.7 s | **92%** | Our working reference (Phase 6) |
| managed | 2 m 15 s | 134.5 s | 32% | 53% slower, GPU barely used |
| unified | 2 m 17 s | 136.0 s | 31% | Effectively identical to managed |

A second managed run produced 2 m 13 s, ruling out CUDA JIT first-run overhead.
The regression is consistent and reproducible.

## Timer analysis

The managed/unified builds' "time integration" (per-step dynamics, 65.6 s / 120 steps
≈ 0.55 s/step) is comparable to the baseline's per-step cost. The extra ~46 s of wall
clock lives in initialization and finalization — almost certainly CUDA Managed Memory
pool setup/teardown for MPAS's many allocatable arrays and derived-type blocks.

**Critically, `[ACC_data_xfer]` timers still appear in all builds.** Example from the
managed build:

```
atm_advance_acoustic_step [ACC_data_xfer]   9.858 s  (82% of routine total)
atm_rk_integration_setup [ACC_data_xfer]    1.110 s  (92% of routine total)
```

The memory model flag did not make the transfer timers disappear.

## Why the flag doesn't help

MPAS's `[ACC_data_xfer]` timers are *software instrumentation* around its own internal
`mpas_openacc_transfer_*` routines, which issue explicit `!$acc update` and
`!$acc enter data` directives. Compile-time memory model flags change how underlying
allocations are managed, but they do not remove the directive calls themselves.

On a discrete GPU with `mem:separate`, an `!$acc update device(x)` triggers a real DMA.
On unified memory, it should be a no-op — but the OpenACC runtime still traverses the
data region's metadata, performs presence checks, and returns. That traversal has
CPU-side cost that MPAS's timers capture as "transfer time."

Additionally, `mem:managed` / `mem:unified` flags add per-allocation overhead that
more than offsets any savings from cheaper transfers, *at least* at the small cell
counts (~12k) we're testing. On larger meshes (500k+ cells) the picture could differ.

## Implication for optimization roadmap

The path to reducing ACC_data_xfer overhead requires **source-level changes** in MPAS:
restructure data regions so `!$acc enter data` happens once at model init and
`!$acc exit data` at finalize, with only lightweight `present()` clauses inside the
timestep loop. This is a deliberate refactor, not a flag flip.

That work naturally merges with the Tier 3 physics port efforts — both involve
editing Fortran. Tier 2 ("compile flag eliminates transfers") is closed.

## See also

- Full writeup with NVHPC 26.3 flag taxonomy: `../docs/memory-model-experiments.md`
