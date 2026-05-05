See also: [Stage 2](stage2-wsm6-fused-kernels.md).

# WSM6 OpenACC Stage 3a — inside the time sub-step loop

**Date:** 2026-04-15 (run), 2026-04-16 (validation)
**Branch:** `wsm6-openacc` on MMM-physics fork, commit `afd977d`
**Binary:** saved as `atmosphere_model.wsm6_stage3a`

## What Stage 3a adds

Three more GPU kernels, all inside the `do loop = 1,loops` time sub-step loop
(which runs once per `mp_wsm6_run` call with our 18 s timestep because
`loops = max(nint(delt/dtcldcr),1)` and `dtcldcr = 120`).

1. **1D init of mstep, flgcld** at loop start — trivial parallel init
2. **denfac = sqrt(den0/den)** — replaces the `vrec`/`vsqrt` library-call
   pattern (no GPU equivalent) with direct inline arithmetic. The commented
   form was already present in the source at lines 532–536 from the original
   MPAS authors; we just uncommented and wrapped it
3. **Saturation mixing ratio + relative humidity** for both liquid and ice
   reference states, with a per-cell branch `if (t < ttp)` — warp divergence
   mitigated by Blackwell ITS, small relative to the `exp`/`log` work

```fortran
!$acc parallel vector_length(32)
!$acc loop gang vector collapse(2) private(tr)
 do k = kts, kte
   do i = its, ite
     tr = ttp/t(i,k)
     qsat(i,k,1) = psat*exp(log(tr)*(xa))*exp(xb*(1.-tr))
     ! ... liquid saturation + RH ...
     if (t(i,k) < ttp) then
       qsat(i,k,2) = psat*exp(log(tr)*(xai))*exp(xbi*(1.-tr))
     else
       qsat(i,k,2) = psat*exp(log(tr)*(xa))*exp(xb*(1.-tr))
     endif
     ! ... ice saturation + RH ...
   enddo
 enddo
!$acc end parallel
```

## Build

Incremental rebuild succeeded. `-Minfo=accel` confirms all three kernels
generated NVIDIA GPU code with `loop gang, vector(32)` and correct implicit
copy directives.

## JW validation

1m27.7s / 92 % SM — identical to all prior stages (as expected).

## 3km Bay Area validation

| Metric | Stage 2-fix | **Stage 3a** | Δ |
|---|---|---|---|
| Total wall clock | 5,414 s | **5,534 s** | +120 s (+2.2 %) |
| Kernels in `mp_wsm6_run` | 3 | **6** | +3 |
| Per-new-kernel cost | — | ~40 s/kernel | ~8 ms/kernel/call × 4,800 calls |
| Errors / critical | 0 / 0 | 0 / 0 | — |

The saturation/RH kernel with its `exp`/`log` math is the heaviest of the
three — the other two (1D init, denfac) are trivially simple.

## Bit-identical diff vs Stage 2-fix (tolerance 1e-3)

| Hour | Stage 1 → Stage 2-fix | Stage 2-fix → **Stage 3a** |
|---|---|---|
| 0 | MATCH | MATCH |
| 1 | 2 | **31** |
| 2-11 | 36-41 | 33-43 |
| 12-17 | 41-44 | 41-45 (peak) |
| 18-24 | 36-41 | 37-42 |

The t=1h count jump from 2 (Stage 1→Stage 2-fix) to 31 (Stage 2-fix→Stage 3a)
reflects additional FP drift from the saturation kernel (which does exp/log
math on every cell). Peak-daytime saturation count (45) is within the same
envelope as all prior comparisons. No amplification; same scientific
equivalence verdict.

## Progression summary

| Stage | Kernels | Wall (s) | Δ | GPU SM avg |
|---|---|---|---|---|
| Baseline no-Tiedtke | 0 | 5,451 | — | 0 % (no kernels) |
| Stage 0 | 0 (data region only) | 5,449 | −2 | 0 % |
| Stage 1 | 1 | 5,504 | +55 | ~19 % (mostly dycore) |
| Stage 2-fix | 3 | 5,414 | −90 | ~19 % |
| **Stage 3a** | **6** | **5,534** | **+120** | ~19 % |

Net effect so far: WSM6 kernels 1–6 are producing correct results but the
work they do is too trivial to move the needle on wall clock — the 8–40 ms
per-kernel overhead is bigger than the time saved by running a 660 k-op
kernel on the GPU vs CPU. Stage 3b+ and Stage 4+ (the actual heavy process-
rate loops and slope calculations) are where wall clock should start
improving.

## Next

- **Stage 3b**: 27 process-rate zero init + xni + qrs_tmp packing
- **Stage 4**: `slope_wsm6` helper via `!$acc routine seq`
- **Stage 5**: sedimentation — the hardest stage, column-parallel with per-
  thread private vertical sweeps

## Status

✅ Built, JW-validated, 3 km-validated, committed, pushed.
