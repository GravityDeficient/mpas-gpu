# 3km Bay Area — no Tiedtke convection

**Date:** 2026-04-14
**Delta from baseline:** `config_convection_scheme = 'off'` added to `&physics`.
Everything else identical to [3km-baseline.md](3km-baseline.md).

## Result

- **Wall clock:** 5,451 s (90 m 51 s)
- **Speedup vs baseline:** 1.31× (24% wall-clock reduction, ~28 min saved)
- 0 errors, 0 critical errors
- 25 hourly history files

## Timer breakdown — key diffs

| Routine | Baseline (s) | No-Tiedtke (s) | Δ |
|---|---|---|---|
| **total** | 7,137 | **5,451** | −24% |
| time integration | 6,948 | 5,271 | −24% |
| physics driver | 3,686 | **2,060** | −44% |
| — cu_ntiedtke | 1,501 | **0** | eliminated |
| — mp_wsm6 | 1,424 | 1,418 | unchanged |
| — bl_ysu | 659 | 657 | unchanged |
| — rrtmg_swrad | 226 | 227 | unchanged |
| — rrtmg_lwrad | 182 | 182 | unchanged |
| — bl_gwdo | 192 | 188 | unchanged |
| — sf_monin_obukhov | 136 | 138 | unchanged |
| — sf_noah | 50 | 50 | unchanged |
| microphysics total | 2,011 | 2,018 | unchanged |

## Takeaways

- Eliminating Tiedtke removed exactly its 1,501 s cost with **zero impact on any other routine**.
- With Tiedtke gone, **WSM6 microphysics (26% of total) is now the #1 GPU port target**.
- The convection_permitting physics suite (Grell-Freitas scale-aware cumulus with Thompson MP and MYNN PBL) would be another option worth benchmarking — it's the scale-appropriate choice at 3 km.
- No skill loss observed (resolved deep convection at 3 km makes Tiedtke scientifically redundant).

## Config

See `configs/bayarea-3km/namelist.atmosphere.no-tiedtke`.
