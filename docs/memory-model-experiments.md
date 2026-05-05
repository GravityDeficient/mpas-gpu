# Memory Model Experiments — NVHPC `-gpu=mem:*` on MPAS v8.3.1

**Date:** 2026-04-15
**Status:** Complete — negative result, informative
**See also:** `benchmarks/jw-memory-models.md` for the raw numbers

## TL;DR

Neither `-gpu=mem:managed` nor `-gpu=mem:unified` improves MPAS performance on the
GB10 — both regress JW baroclinic wave from 1 m 28 s @ 92% GPU SM to ~2 m 15 s @ 31%
SM. The baseline `-gpu=ccnative` (no memory mode flag) remains fastest.

The ~596 s of `ACC_data_xfer` overhead measured on the 3 km Bay Area benchmark
cannot be eliminated by a compile-time flag. It is baked into MPAS's explicit
`!$acc update` / `!$acc enter data` directives and requires source-level changes.

## NVHPC 26.3 memory model taxonomy

When testing `-gpu=unified`, the compiler emits this deprecation warning:

```
nvfortran-Warning- The -gpu=[no]unified option is deprecated;
please use -gpu=mem:unified, -gpu=mem:managed or -gpu=mem:separate instead
```

| Flag | Semantics | Intended hardware |
|---|---|---|
| `-gpu=mem:separate` | Explicit `copyin`/`copyout` perform real DMA transfers | V100, A100, H100 without coherent interconnect |
| `-gpu=mem:managed` | CUDA Managed Memory — software pool, page-migrated on access | Discrete GPUs with page migration |
| `-gpu=mem:unified` | Physically unified memory — hardware-coherent access from both CPU and GPU | Grace Hopper (GH200), Grace Blackwell (GB10, GB200) |

For a physically unified memory system like GB10, `mem:unified` is theoretically the
correct choice. Empirically, it doesn't help MPAS at sub-500k cell counts.

## Why the flag doesn't help

MPAS's `[ACC_data_xfer]` timers are **software instrumentation** wrapping its own
internal `mpas_openacc_transfer_*` routines, which in turn issue explicit
`!$acc update` and `!$acc enter data` directives. Compile-time memory model flags
change how underlying allocations are managed, but they do not remove the directive
calls themselves.

On a discrete GPU with `mem:separate`, an `!$acc update device(x)` triggers a real
DMA. On unified memory, the bytes don't move — but the OpenACC runtime still
traverses the data region's metadata, performs presence checks, and returns. That
traversal has CPU-side cost that MPAS's timers capture as "transfer time."

Additionally, `mem:managed` / `mem:unified` flags add their own per-allocation
overhead (registering arrays with the managed pool, installing page-fault handlers
in the managed case, etc.) that more than offsets any savings from cheaper transfers
— at least on the small cell counts we tested.

## Implication for the optimization roadmap

The path to reducing `ACC_data_xfer` overhead requires **source-level changes** in
MPAS:

- Restructure data regions so `!$acc enter data` happens once at model init and
  `!$acc exit data` at finalize
- Use `present()` clauses inside the timestep loop rather than `copy` or `update`
- This is a deliberate refactor, not a flag flip

That effort rolls naturally into the Tier 3 physics port work (WSM6 OpenACC, MYNN
OpenACC, RRTMGP integration) — both involve editing Fortran. Tier 2 ("compile flag
eliminates transfers") is closed.

## Files kept on Huginn for reference

| File | Content |
|---|---|
| `${MPAS_ROOT}/atmosphere_model.baseline` | Phase 5 `-gpu=ccnative` binary (known-good) |
| `${MPAS_ROOT}/atmosphere_model.managed` | Failed experiment — `-gpu=mem:managed,deepcopy` |
| `${MPAS_ROOT}/atmosphere_model.unified` | Failed experiment — `-gpu=mem:unified` |
| `${MPAS_ROOT}/Makefile.ccnative` | Known-good Makefile snapshot |
| `${MPAS_ROOT}/Makefile.managed` | Failed experiment's Makefile |
| `${MPAS_ROOT}/build_managed.log` | Build log for the managed variant |
| `${MPAS_ROOT}/build_unified.log` | Build log for the unified variant |
