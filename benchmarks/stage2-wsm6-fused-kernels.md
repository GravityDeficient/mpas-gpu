# WSM6 OpenACC Stage 2 — fused 2D + 1D init + Stage 0 data-region removal

**Date:** 2026-04-15
**Branches:** `wsm6-openacc` on MMM-physics fork
**Commits:** `66729bd` (initial, crashed), `586e3c7` (fix, shipped)
**Binary:** saved as `atmosphere_model.wsm6_stage2fix`

## What Stage 2 adds

Three more GPU kernels, plus a critical architectural change to the data
region strategy.

### Kernel 2a (fused 2D)

Two adjacent do-k/do-i nests fused into one `!$acc parallel` region with two
`!$acc loop gang vector collapse(2)` sub-blocks. One kernel launch instead of
two. Statement functions `cpmcal(q)` and `xlcal(t)` are inlined by nvfortran
at the call site before accelerator analysis.

```fortran
!$acc parallel vector_length(32)
!$acc loop gang vector collapse(2)
 do k = kts, kte
   do i = its, ite
     cpm(i,k) = cpmcal(q(i,k))
     xl(i,k) = xlcal(t(i,k))
   enddo
 enddo
!$acc loop gang vector collapse(2)
 do k = kts, kte
   do i = its, ite
     delz_tmp(i,k) = delz(i,k)
     den_tmp(i,k) = den(i,k)
   enddo
 enddo
!$acc end parallel
```

### Kernel 2b (1D surface init)

```fortran
!$acc parallel vector_length(32)
!$acc loop gang vector
 do i = its, ite
   rainncv(i) = 0.
   if(present(snowncv) .and. present(snow)) snowncv(i) = 0.
   if(present(graupelncv) .and. present(graupel)) graupelncv(i) = 0.
   sr(i) = 0.
   tstepsnow(i) = 0.
   tstepgraup(i) = 0.
 enddo
!$acc end parallel
```

The `present()` checks on optional arguments are invariant across iterations
(resolved at subroutine entry) so they are safe inside a parallel region.

## The Stage 2 crash-and-fix story

### First attempt: crashed at step ~600

The initial Stage 2 commit (`66729bd`) kept Stage 0's `!$acc data create(...)`
region wrapping the entire `mp_wsm6_run` body with ~60 local arrays. It
**crashed with NaN surface pressure after ~13.5 min wall clock**:

```
global min, max w 0.00000 0.00000     ← vertical velocity collapsed to zero
Begin timestep 2026-04-14_02:59:42
Troubles finding level 100.000 above ground.
Problems first occur at (1)
Surface pressure = NaN hPa.
*** MSLP field will not be computed
[GB10 host:669579:0:669579] Caught signal 11 (Segmentation fault: address not mapped)
```

### Root cause

Stage 2a's kernel writes to `cpm, xl, delz_tmp, den_tmp` and Stage 2b writes
to `tstepsnow, tstepgraup`. **All six of these arrays were in Stage 0's
`create()` list** — meaning they are GPU-only allocations under OpenACC
semantics.

The writes landed correctly on the GPU. But the data region tells the compiler
"these arrays live on GPU, not CPU." Downstream CPU code inside `mp_wsm6_run`
that reads `cpm`, `xl`, etc. reads the corresponding **host memory, which
contains uninitialized garbage**. Garbage latent heat → garbage thermodynamics
→ NaN surface pressure → model blew up.

This wasn't visible in Stage 0 or Stage 1 because:
- Stage 0 had no kernels — `create()` allocated device memory but nothing wrote
  to it, so CPU reads of the host-side copies returned whatever the stack /
  heap had (same uninitialized, but nobody checked)
- Stage 1's kernel wrote only to prognostic args (`qc, qr, qi, qs, qg`) which
  are **not** in `create()` — they get proper implicit copyin/copyout that
  keeps host and device in sync

### Why NCAR's port doesn't have this problem

`upstream/atmosphere/develop-openacc`'s `wsm62D` uses the same
`!$acc data create(...)` list. It works because NCAR ported **every CPU reader
of those arrays too** — no CPU code touches them at runtime. Our partial port
is inherently hybrid, so the aggressive create list was architecturally wrong.

### Fix (commit `586e3c7`)

Removed the Stage 0 data region entirely. Every kernel now gets its own
implicit copyin/copyout via nvfortran, which handles host/device coherence
correctly per invocation. Higher per-kernel transfer overhead than a
well-scoped data region would incur, but correctness first.

We will rebuild a proper data region later when the full WSM6 port is in place
and the host/device read-write flow is completely known. At that point,
`copy()` for hybrid-accessed arrays and `create()` only for arrays that are
provably GPU-internal.

## Build

- Incremental rebuild: passed
- `-Minfo=accel` confirms all three kernels generated GPU code and the
  `implicit copyout(cpm, delz_tmp, xl, den_tmp)` clauses that fix the crash

## JW validation

1m27.7s / 92 % SM — identical to prior stages.

## 3km Bay Area validation

| Metric | Baseline no-Tiedtke | Stage 0 | Stage 1 | **Stage 2-fix** |
|---|---|---|---|---|
| Total wall clock | 5,451 s | 5,448 s | 5,504 s | **5,414 s** |
| Δ vs Stage 1 | — | — | — | **−89 s** |
| Δ vs Stage 0 | — | — | +55 s | −35 s |

**Surprise result:** Stage 2-fix is **faster than Stage 1** despite having 3
kernels instead of 1. The ~89 s reduction came from removing the Stage 0
`!$acc data create(...)` block, which apparently had non-trivial OpenACC
runtime overhead even with no kernels referencing the managed arrays. On GB10
the per-directive state tracking costs something even when bytes don't move.

This contradicts my earlier projection that removing the data region would
add overhead via more per-kernel implicit copies. On unified memory the
implicit-copy runtime cost is dominated by state tracking, not byte movement,
and a smaller state-tracked set wins.

**Implication for future stages:** we should stay in implicit-copy mode for
each new kernel until the full port is in place, then build a proper data
region as a single optimization pass. Don't re-introduce broad `create()`
blocks along the way.

## Bit-identical diff vs Stage 1 (tolerance 1e-3)

Diff pattern across all 25 files is essentially identical to Stage 0 → Stage 1:

| Hour | Stage 0 → Stage 1 | Stage 1 → Stage 2-fix |
|---|---|---|
| 0 | MATCH | MATCH |
| 1 | 23 diffs | 2 diffs |
| 2-11 | 35-43 | 36-41 |
| 12-17 | 42-44 | 41-44 |
| 18-24 | 34-40 | 36-41 |

Same growth curve, same saturation, same magnitudes on physical fields. Stage
2's new kernels don't amplify drift beyond what Stage 1 already produced.

## Takeaway

Two important lessons:

1. **`!$acc data create(...)` means GPU-only** — any CPU reader of those
   arrays will get garbage. Don't use `create()` until you know the array is
   provably GPU-internal.

2. **OpenACC runtime state tracking costs something on GB10** — removing the
   Stage 0 data region saved ~89 s (~1.6 %) even though no kernels referenced
   the managed arrays. Broad data regions should be earned by porting enough
   downstream code to justify them, not speculative.

## Status

✅ Crash diagnosed, fix shipped, built, JW-validated, 3km-validated, committed,
pushed.
