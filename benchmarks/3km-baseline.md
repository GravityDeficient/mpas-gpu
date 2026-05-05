# 3km Bay Area — baseline (mesoscale_reference)

**Date:** 2026-04-14
**Forecast:** 2026-04-14 00Z + 24h, GFS 0.25° boundary conditions
**Mesh:** 11,993 cells, uniform ~2.9 km, 55 vertical levels
**Physics:** `config_physics_suite = 'mesoscale_reference'`
  - Microphysics: WSM6
  - PBL: YSU
  - Surface layer: Monin-Obukhov revised
  - LSM: Noah
  - Cumulus: Tiedtke
  - Radiation: RRTMG LW + SW (30-min interval)
  - Gravity wave drag: on
**dt:** 18 s (4,800 steps)
**MPI ranks:** 1

## Result

- **Wall clock:** 7,137 s (118 m 57 s)
- GPU SM utilization (nvidia-smi dmon): **0%** (kernels too fast to sample; see ACC_data_xfer entries for proof of GPU activity)
- 0 errors, 0 critical errors
- 25 hourly history files (3.1 GB total)

## Timer breakdown

| Routine | Time (s) | % of total |
|---|---|---|
| **total** | **7,137** | 100% |
| time integration | 6,948 | 97.4% |
| — physics driver | 3,686 | 51.6% |
|    — cu_ntiedtke | 1,501 | 21.0% |
|    — mp_wsm6 | 1,424 | 20.0% |
|    — bl_ysu (PBL) | 659 | 9.2% |
|    — rrtmg_swrad | 226 | 3.2% |
|    — rrtmg_lwrad | 182 | 2.5% |
|    — bl_gwdo | 192 | 2.7% |
|    — sf_monin_obukhov_rev | 136 | 1.9% |
|    — sf_noah | 50 | 0.7% |
| — dynamics (total) | ~3,262 | 45.7% |
|    — ACC_data_xfer overhead | ~596 | 8.4% |
| diagnostic_fields | 178 | 2.5% |
| stream_output | 7 | 0.1% |

## Key findings

1. Physics is 53% of total runtime and runs 100% on CPU
2. Tiedtke convection (21%) is the largest single cost — inappropriate at 3 km
3. GPU dycore runs but `ACC_data_xfer` overhead consumes 50-80% of each dycore routine
4. WSM6 microphysics (20%) is the #1 physics port target
