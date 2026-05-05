# WSM6 OpenACC Port Scope

**Target:** `src/core_atmosphere/physics/physics_mmm/mp_wsm6.F90` in MPAS v8.3.1.
**Goal:** Move the 1,418 s per 24h forecast (26% of total runtime on the 3km Bay Area case) from CPU to the GB10 GPU via OpenACC directives, without changing scientific behavior.
**Status:** Scoping. No annotations applied yet.

## Source layout

The file is 2,449 lines. It exposes three public entry points and contains a set of private helper subroutines:

| Lines | Routine | Role | Port strategy |
|---|---|---|---|
| 73–194 | `mp_wsm6_init` | Initialize module-level constants (`qc0, qck1, bvtr*, g*pbr, ...`) from physics constants. Runs once. | Stays on CPU. After init, push module variables to GPU once via `!$acc update device` or `!$acc declare create` + `!$acc enter data`. |
| 195–212 | `mp_wsm6_finalize` | No-op cleanup | Stays on CPU. |
| 213–~1520 | **`mp_wsm6_run`** | **Main hot path.** Per-timestep microphysics for all columns. | Body is wrapped in one `!$acc data create(...)` region; inner loops become `!$acc parallel loop collapse(2)` over `(k,i)`. |
| 1525–1604 | `slope_wsm6` | Slope parameter calculation for all 3 precip species | `!$acc routine vector` — called from within `mp_wsm6_run`'s GPU region |
| 1605–1650 | `slope_rain` | Slope for rain only (used by `refl10cm_wsm6`) | `!$acc routine vector` — optional if refl10cm is kept on GPU |
| 1651–1701 | `slope_snow` | Slope for snow only | Same |
| 1702–1750 | `slope_graup` | Slope for graupel only | Same |
| 1751–1996 | `nislfv_rain_plm` | Sedimentation (rain) — non-iterative semi-Lagrangian with PLM, per-column | Outer `i_loop` → `!$acc parallel loop`; inner `k` loops stay sequential per column. Local 1D arrays become `private(...)`. |
| 1997–2274 | `nislfv_rain_plm6` | Sedimentation (snow + graupel, 2-species variant) | Same pattern as `nislfv_rain_plm` |
| 2275–2449 | `refl10cm_wsm6` | Diagnostic radar reflectivity | Low priority. Can stay on CPU initially (only called when `diagflag=true`). |

## Data surface of `mp_wsm6_run`

### Input arguments

- Loop bounds: `its, ite, kts, kte` (integers)
- Read-only 2D fields: `den(i,k), p(i,k), delz(i,k)` — environment
- Read-only scalar physics constants: `delt, g, cpd, cpv, t0c, den0, rd, rv, ep1, ep2, qmin, xls, xlv0, xlf0, cliq, cice, psat, denr` — 18 scalars

### Inout arguments

- 2D prognostic state: `t, q, qc, qi, qr, qs, qg` — temperature plus six hydrometeor mixing ratios
- 1D surface accumulators: `rain, rainncv, sr` (always present); `snow, snowncv, graupel, graupelncv` (optional); `rainprod2d, evapprod2d` (optional, for WRF-chem scavenging)

### Output

- `errmsg` (character), `errflg` (integer) — CCPP-standard error channel

### Local arrays (created fresh each call)

**3D working arrays `(its:ite, kts:kte, 3)` — species-indexed 3rd dim (1=rain, 2=snow, 3=graupel):**
- `rh, qsat, rslope, rslope2, rslope3, rslopeb, qrs_tmp, falk, fall, work1` — 10 arrays
- Total footprint per call: 10 × ite × kte × 3 × 4 bytes (single precision)

**2D process-rate arrays `(its:ite, kts:kte)`:** 27 arrays, each storing a microphysical tendency:

- Condensation/evaporation: `pcond, prevp, psevp, pgevp, pigen, pidep`
- Deposition: `psdep, pgdep`
- Autoconversion: `praut, psaut, pgaut`
- Accretion: `piacr, pracw, praci, pracs, psacw, psaci, psacr, pgacw, pgaci, pgacr, pgacs, paacw`
- Melting: `psmlt, pgmlt, pseml, pgeml`

**Other 2D working `(its:ite, kts:kte)`:** `qsum, xl, cpm, work2, denfac, xni, denqrs1, denqrs2, denqrs3, denqci, n0sfac, fallc, falkc, work1c, work2c, workr, worka, den_tmp, delz_tmp` — ~19 arrays

**1D per-column `(its:ite)`:** `delqrs1, delqrs2, delqrs3, delqi, tstepsnow, tstepgraup, mstep, numdt, flgcld, dvec1, tvec1` — 11 arrays

### Loop-local scalars (need `private()` clause)

~45 scalar temporaries used inside `do k / do i` loops. Full list:

```
cpmcal, xlcal, diffus, viscos, xka, venfac, conden, diffac     (statement functions)
x, y, z, a, b, c, d, e                                          (scratch)
qdt, holdrr, holdrs, holdrg, supcol, supcolt, pvt, coeres,
supsat, dtcld, xmi, eacrs, satdt, qimax, diameter, xni0, roqi0,
fallsum, fallsum_qsi, fallsum_qg,
vt2i, vt2r, vt2s, vt2g, acrfac, egs, egi,
xlwork2, factor, source, value,
xlf, pfrzdtc, pfrzdtr, supice, alpha2, delta2, delta3,
vt2ave, holdc, holdci,
dldti, xb, xai, tr, xbi, xa, hvap, cvap, hsub, dldt, ttp        (fpvs inlining)
temp
```

## Loop inventory

Raw counts:

| Pattern | Count | Notes |
|---|---|---|
| `do i = its, ite` | 37 | Most within a `do k / do i` nest |
| `do k = kts, kte` | 29 | Outer loop of the typical nest |
| Existing `!$acc` directives | **0** | Clean port surface |

Typical nested structure (example from warm-rain process rates around line 866):

```fortran
do k = kts, kte
  do i = its, ite
    supsat = max(q(i,k),qmin) - qsat(i,k,1)
    satdt = supsat / dtcld
    if (qc(i,k) > qc0) then
      praut(i,k) = qck1 * qc(i,k)**(7./3.)
      praut(i,k) = min(praut(i,k), qc(i,k)/dtcld)
    endif
    ...
  enddo
enddo
```

Under port, this becomes:

```fortran
!$acc parallel loop collapse(2) present(q, qsat, qc, praut, ...) &
!$acc   private(supsat, satdt, ...)
do k = kts, kte
  do i = its, ite
    ! unchanged body
  enddo
enddo
```

## Branch divergence risk

WSM6's process rates are gated by conditionals on hydrometeor presence: `if (qc > qc0)`, `if (qr > qcrmin)`, `if (supcol > 0 .and. qi > qmin)`, etc. Different columns/levels take different branches based on local meteorology.

On pre-Volta NVIDIA GPUs this would be severe warp-divergence overhead. On Blackwell (GB10), **Independent Thread Scheduling** (introduced in Volta, 2017) lets divergent threads in the same warp execute independently — the performance penalty is reduced but not eliminated. Empirical data from the first 500m mesh run will tell us if this is fatal or merely a 1.5–2× efficiency hit.

No mitigation is planned initially. If profiling shows divergence is the binding constraint, we can:

- Pre-sort columns into "has precipitation" vs "no precipitation" groups and launch separate kernels
- Use `!$acc loop vector` to give the compiler more freedom in scheduling

## Sedimentation structure (the harder part)

`nislfv_rain_plm` at line 1751 is a non-iterative semi-Lagrangian forward advection with piecewise linear reconstruction. Structure:

```fortran
i_loop: do i = 1, im                     ← column-parallel on GPU
    dz(:)     = dzl(i,:)                 ← load 1D column views
    qq(:)     = rql(i,:)
    ww(:)     = wwl(i,:)
    ...
    allold = sum(qq)
    if (allold <= 0.0) cycle i_loop      ← early exit if no precip
    do k = 1, km                         ← vertical integration (sequential)
        zi(k+1) = zi(k) + dz(k)          ← k+1 depends on k — MUST stay serial
    enddo
    ... PLM reconstruction, advection, ... (all per-column k-loops)
    do k = 1, km
        rql(i,k) = qr(k)                  ← write back
    enddo
enddo i_loop
```

**Port plan:**

- `!$acc parallel loop` on the outer `i_loop` (column parallelism)
- Make `dz, ww, qq, den, denfac, tk, wi, zi, dza, qa, qmi, qpi, wa, was, qn, qr, tmp, tmp1, tmp2, tmp3, wd` — all dimension `(km)` or `(km+1)` — **private per GPU thread**
- Each thread runs the vertical sweeps sequentially, correct by construction
- The `cycle i_loop` when `allold <= 0` becomes a branch within the parallel region; harmless performance-wise (it just means some threads finish early)

**Memory footprint of private arrays:** On a 500m mesh with ~160,000 columns and km=55, each private 1D array is ~55 reals × 4 bytes = 220 B. With ~20 private arrays per thread, that's 4.4 KB per thread × 160,000 threads = ~700 MB. Fits in 128 GB unified memory trivially.

## External dependencies

### From `module_libmassv` (imported at top of file)

- `vrec(tvec, dvec, N)` — vectorized reciprocal: `tvec(i) = 1.0/dvec(i)`
- `vsqrt(dvec, tvec, N)` — vectorized square root: `dvec(i) = sqrt(tvec(i))`

These are SIMD-optimized CPU intrinsics from IBM's MASS library (or vendor equivalent). They have no GPU implementation. The file uses them in exactly one spot (lines 506–510) to compute `denfac(i,k) = sqrt(den0/den(i,k))`. The code even has the direct-arithmetic version commented out at lines 497–501.

**Port plan:** Replace the `vrec`/`vsqrt` dance with the direct form inside an `!$acc parallel loop`:

```fortran
!$acc parallel loop collapse(2) present(den, denfac)
do k = kts, kte
  do i = its, ite
    denfac(i,k) = sqrt(den0 / den(i,k))
  enddo
enddo
```

nvfortran will emit fast native reciprocal + sqrt on Blackwell.

### From `mp_radar` (imported for reflectivity only)

- `rayleigh_soak_wetgraupel` — called from `refl10cm_wsm6` (the diagnostic)
- Not in the critical path. Keep `refl10cm_wsm6` on CPU initially.

## Statement functions

Seven statement functions are defined at the top of `mp_wsm6_run` (lines 418–431): `cpmcal`, `xlcal`, `diffus`, `viscos`, `xka`, `diffac`, `venfac`, `conden`. These are old-school inline Fortran functions, not modern `contains`'d internal procedures.

nvfortran should inline statement functions automatically inside `!$acc` regions (they are inlined lexically at the call site by the front-end before accelerator analysis). If they cause trouble, the fallback is to convert them to explicit `!$acc routine seq` internal procedures.

## Recommended porting order

To de-risk, approach in six stages. Each stage ends with a runnable binary and a validation check against the baseline's output (bitwise won't match due to FP associativity, but large-scale rainfall fields should be visually and statistically indistinguishable).

1. **Stage 0 — Data region scaffolding.** Add `!$acc data create(...)` at the top of `mp_wsm6_run` for all local arrays; add `!$acc data copy(...) copyin(...) copyout(...)` for input/inout/output arguments. Build; run. No kernels yet — should behave identically with zero GPU offload and some transfer overhead.

2. **Stage 1 — Warm-rain process rates (simplest block, lines ~866–902).** Wrap the `do k / do i` nest in `!$acc parallel loop collapse(2)`. Build; run JW and 3km Bay Area. Compare rain accumulation to baseline. If bitwise-different but physically identical, proceed.

3. **Stage 2 — Cold-rain process rates (lines ~917–1100).** Same pattern, more branching.

4. **Stage 3 — Remaining pointwise loops in `mp_wsm6_run`.** ~30 additional `do k / do i` nests.

5. **Stage 4 — `slope_wsm6` helper.** Add `!$acc routine vector`. Make the call site inside the GPU region.

6. **Stage 5 — Sedimentation (`nislfv_rain_plm`, `nislfv_rain_plm6`).** Hardest stage. Column-parallel with per-thread private 1D arrays. This is where branch divergence and register pressure could hurt.

After stage 5, all 1,418 s of WSM6 CPU time should be on GPU. Expected speedup: 2–4x on a 160k-cell 500m mesh, less on smaller meshes due to kernel launch overhead. Even modest speedups on WSM6 make the whole port worth it because it removes the single largest CPU bottleneck.

## What we're NOT doing (initial port)

- **No double-precision build.** Single precision stays the default; WSM6's numerical tolerances allow single precision, and Blackwell's SP throughput is ~4× DP.
- **No Thompson microphysics.** Thompson is lookup-table-based and much more complex. Stays CPU-only indefinitely unless a different research direction needs it.
- **No `refl10cm_wsm6` port.** Only runs when diagnostic output is requested, and its cost isn't in our benchmark runtime.
- **No algorithm changes.** We preserve every branch, every `max`/`min` clamp, every coefficient. The port is directive-only.

## Open questions to resolve during port

- Does nvfortran inline the statement functions correctly inside `!$acc parallel` regions, or do they need to be rewritten as `!$acc routine seq` internal procedures?
- Should the species-indexed 3D arrays (dim `(its:ite, kts:kte, 3)`) be reshaped to SoA (`(3, its:ite, kts:kte)`) for better memory coalescing on GPU? Initial port preserves existing layout; reshape is a potential stage-6 optimization.
- How does register pressure behave? The `mp_wsm6_run` body is huge (~1,300 lines) — compiling it as a single parallel region may spill registers. If so, break into multiple smaller parallel regions at natural boundaries (e.g., warm-rain vs cold-rain).
- Does `!$acc declare create` work for the module-level `save` variables (`qc0, qck1, bvtr*, g*pbr, ...`), or do they need to be moved into a data structure passed explicitly?
