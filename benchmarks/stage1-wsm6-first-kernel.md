# WSM6 OpenACC Stage 1 — first GPU kernel (pad-zero loop)

**Date:** 2026-04-15
**Branch:** `wsm6-openacc` on MMM-physics fork, commit `ff5e9a6`
**Binary:** saved as `atmosphere_model.wsm6_stage1`

## Change

Wrap the "pad 0 for negative values" loop (the first hot loop in `mp_wsm6_run`)
in the standard NCAR pattern:

```fortran
!$acc parallel vector_length(32)
!$acc loop gang vector collapse(2)
 do k = kts, kte
   do i = its, ite
     qc(i,k) = max(qc(i,k),0.0)
     qr(i,k) = max(qr(i,k),0.0)
     qi(i,k) = max(qi(i,k),0.0)
     qs(i,k) = max(qs(i,k),0.0)
     qg(i,k) = max(qg(i,k),0.0)
   enddo
 enddo
!$acc end parallel
```

`qc, qr, qi, qs, qg` are `intent(inout)` subroutine arguments, not in any
surrounding data region, so nvfortran generates implicit copyin+copyout per
kernel invocation.

## Build

- Incremental rebuild (source change only, no flag change): passed
- `-Minfo=accel` confirms:
  ```
  459, Generating NVIDIA GPU code
       461, !$acc loop gang, vector(32) collapse(2)
  459, Generating implicit copy(qc, qs, qr, qg, qi)
  ```

## JW validation

| Metric | Baseline | Stage 1 |
|---|---|---|
| Wall clock | 1m28s | 1m27.6s |
| Peak GPU SM | 92 % | 92 % |
| Errors | 0 | 0 |

Identical within noise. Expected — JW uses `physics_suite='none'` so
`mp_wsm6_run` is never called; the new kernel is linked but not executed.

## 3km Bay Area validation

24 h forecast, no-Tiedtke config, 1 MPI rank.

| Metric | Stage 0 | **Stage 1** | Δ |
|---|---|---|---|
| Total wall clock | 5,448.5 s | **5,503.5 s** | +55 s (+1.0 %) |
| physics driver | 2,059.9 s | 2,075.3 s | +15 s |
| microphysics | 2,016.5 s | 2,054.3 s | +38 s |
| `mp_wsm6` | 1,421.9 s | 1,441.6 s | +20 s |
| Peak GPU SM | 0 % | 87 % | first real GPU kernel launches |
| Avg GPU SM (full run) | ~0 % | 19 % (shared with dycore) | — |
| Errors / critical | 0 / 0 | 0 / 0 | — |

**Per-kernel overhead** from the implicit copy: (5,503 − 5,448) / 4,800 calls
≈ 11.5 ms per call. That's copy-in of 5 prognostic arrays (~13 MB) + GPU kernel
launch + copy-out of 5 prognostic arrays + runtime bookkeeping.

## Bit-identical diff vs Stage 0 (tolerance 1e-3)

Across all 25 history files: 55–58 variables differ at `t=1h+` of simulated time.
Growth curve and magnitudes are **essentially identical to Stage 0 vs
baseline-rerun**, confirming Stage 1 adds no meaningful additional FP drift
beyond what Stage 0's data region already introduced. See
[stage0-wsm6-data-region.md](stage0-wsm6-data-region.md) for the root-cause
analysis of the FP drift pattern.

Key physical diagnostics at t=1h:

| Variable | Max abs diff | Meaning |
|---|---|---|
| hpbl | 5.66 m | trivial (PBL is hundreds of m) |
| ertel_pv | 0.187 | trivial |
| ke | 0.14 J/kg | trivial |
| hfx | 7.4 mW/m² | trivial |
| kpbl | integer mismatch | categorical |

Within compiler-level FP drift envelope. Stage 1 is scientifically equivalent
to Stage 0.

## Takeaway

Stage 1 proves the mechanism works end-to-end: build, link, launch, validate.
The kernel itself (5 `max()` ops per grid point) is trivially simple — the ~11
ms/call overhead dominates the actual compute. Real compute savings require
Stages 3+ where we port the process-rate loops that dominate `mp_wsm6` runtime.

## Status

✅ Built, JW-validated, 3km-validated, committed, pushed.
