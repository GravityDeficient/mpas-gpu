See also: [Stage 3a](stage3a-wsm6-substep-loop-kernels.md).

# WSM6 OpenACC Stage 3b — process-rate init + xni + qrs_tmp packing

**Date:** 2026-04-16
**Branch:** `wsm6-openacc` on MMM-physics fork, commit `984855d`
**Binary:** `atmosphere_model.wsm6_stage3b` on GB10 host

## What Stage 3b adds

Three more GPU kernels, bringing the total in `mp_wsm6_run` to nine.

### Kernel 3b-1: 27 process-rate arrays + fall/falk/falkc scratch + xni default

Pure pointwise write-only zero-init of every microphysics tendency array that
later stages will populate with actual process rates. Ideal GPU pattern — no
branches, no dependencies, no arithmetic.

```fortran
!$acc parallel vector_length(32)
!$acc loop gang vector collapse(2)
 do k = kts, kte
   do i = its, ite
     prevp(i,k) = 0.    ! rain evaporation rate
     psdep(i,k) = 0.    ! snow deposition
     pgdep(i,k) = 0.    ! graupel deposition
     praut(i,k) = 0.    ! cloud water → rain autoconversion
     psaut(i,k) = 0.    ! cloud ice → snow autoconversion
     ! ... 22 more process rates ...
     pgevp(i,k) = 0.    ! graupel evaporation
     falk(i,k,1) = 0.   ! fall tendencies for rain/snow/graupel
     fall(i,k,1) = 0.
     fallc(i,k) = 0.
     falkc(i,k) = 0.
     xni(i,k) = 1.e3    ! ice crystal number default
   enddo
 enddo
!$acc end parallel
```

### Kernel 3b-2: xni ice crystal number concentration

Eq. [HDC 5c] — ice crystal number from ice mixing ratio and air density. Uses
loop-local scalar `temp` so we declare it `private()`.

```fortran
!$acc parallel vector_length(32)
!$acc loop gang vector collapse(2) private(temp)
 do k = kts, kte
   do i = its, ite
     temp = (den(i,k) * max(qi(i,k), qmin))
     temp = sqrt(sqrt(temp*temp*temp))
     xni(i,k) = min(max(5.38e7*temp, 1.e3), 1.e6)
   enddo
 enddo
!$acc end parallel
```

### Kernel 3b-3: qrs_tmp species packing

Packs rain/snow/graupel into the 3D species-indexed `qrs_tmp(i,k,1..3)` array
that the `slope_wsm6` helper (Stage 4) will read.

```fortran
!$acc parallel vector_length(32)
!$acc loop gang vector collapse(2)
 do k = kts, kte
   do i = its, ite
     qrs_tmp(i,k,1) = qr(i,k)
     qrs_tmp(i,k,2) = qs(i,k)
     qrs_tmp(i,k,3) = qg(i,k)
   enddo
 enddo
!$acc end parallel
```

## Build and JW

- Incremental rebuild: clean
- `-Minfo=accel`: three new kernels generated GPU code correctly
- JW baroclinic wave: 1m34.9s / 87 % SM (slightly slower/lower than prior
  stages — likely JIT warmup jitter on a fresh binary; JW doesn't call
  `mp_wsm6_run` so the new kernels don't execute)

## 3km Bay Area validation

24h forecast, no-Tiedtke config, clean GB10 host (second attempt — the first
was killed due to WRF cron contention, see below).

| Metric | Stage 3a | **Stage 3b** | Δ |
|---|---|---|---|
| Total wall clock | 5,534 s | **5,648 s** | +114 s (+2.1 %) |
| Kernels in `mp_wsm6_run` | 6 | **9** | +3 |
| Errors / critical | 0 / 0 | 0 / 0 | — |

Per-new-kernel cost: +114 s / 3 kernels / 4,800 calls ≈ 7.9 ms/kernel/call.
Zero-init kernels are slightly cheaper than Stage 3a's saturation kernel
(saturation has exp + log math per cell; zero-init just writes constants).

## Scientific validation (vs Stage 3a output)

Bit-identical comparison with tolerance 1e-3 across all 25 history files:

| Hour | Stage 2-fix → 3a | Stage 3a → **3b** |
|---|---|---|
| 0 | MATCH | **MATCH** |
| 1 | 31 diffs | **MATCH** ← unusually clean |
| 2-11 | 33-43 | 33-42 |
| 12-17 | 41-45 | 42-45 (peak) |
| 18-24 | 37-42 | 38-41 |

The **MATCH at t=1h** is notable — Stage 3b's three kernels introduce *less*
FP drift than Stage 3a's saturation kernel did. Makes sense: zero-init and
simple `sqrt(sqrt(x^3))` produce fewer FP-ordering divergences than per-cell
`exp(log(x)*y)` with a branch. The peak daytime plateau at 42-45 vars
matches every prior stage-to-stage comparison — we're inside the known
compiler FP noise envelope.

Stage 3b is scientifically equivalent to Stage 3a.

## The WRF cron collision (operational note)

First launch attempt was killed mid-run because WRF's 00:15 PDT primary
forecast started at 01:42 PDT and was using all 20 CPU cores via
`mpirun -np 20`, throttling our MPAS forecast (step time went from 1.02 s
to 1.25 s — 25 % slowdown). Decided to restart on clean GB10 host.

A watcher script was deployed to auto-launch Stage 3b after WRF finished.
The watcher had a **bug**: it used `pgrep -f "wrf.exe"` to detect WRF
running, but the watcher script *file itself* contains the literal string
`"wrf.exe"` (inside the `pgrep` command), so the bash process that created
the script via heredoc matched every time. The watcher polled forever,
stuck overnight, never launched Stage 3b. Fix for next time: use
`pgrep -x wrf.exe` (exact name match on the binary) or `pidof wrf.exe`.

Stage 3b was launched manually the next morning on a clean GB10 host and
completed without issue.

## Overall progression so far

| Stage | Wall (s) | Δ baseline | Kernels | Status |
|---|---|---|---|---|
| Baseline no-Tiedtke | 5,451 | — | 0 | reference |
| Stage 0 | 5,449 | −2 | data region only | retired later |
| Stage 1 | 5,504 | +53 | 1 | ✓ |
| Stage 2-fix | 5,414 | −37 | 3 | ✓ (crashed first, fixed) |
| Stage 3a | 5,534 | +83 | 6 | ✓ |
| **Stage 3b** | **5,648** | **+197** | **9** | **✓** |

Net effect: 9 trivial GPU kernels add ~197 s of OpenACC runtime overhead on
the 3 km forecast. This is the expected pattern while we're porting
pointwise work. Real compute savings come in Stages 5-7 where the actual
microphysics math (warm-rain + cold-rain process rates, supersaturation
adjustment, sedimentation) moves to GPU.

## Status

✅ Built, JW-validated, 3 km-validated, committed, pushed.

## Next

- **Stage 4:** Port `slope_wsm6` helper via `!$acc parallel` around its
  single `do k / do i` nest, or `!$acc routine seq` to make it callable
  from within GPU regions. Single 2D loop, moderate math complexity
  (`sqrt(sqrt(...))` for lambda parameters, branches on hydrometeor
  presence). See [`port-progression-dashboard.md`](port-progression-dashboard.md) for the full stage ladder.
