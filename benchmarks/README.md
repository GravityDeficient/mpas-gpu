# Benchmarks

Measured wall-clock times and timer breakdowns for MPAS atmosphere_model
runs on GB10 host (GB10).

| File | Date | Config | Wall clock | Notes |
|---|---|---|---|---|
| `3km-baseline.md` | 2026-04-14 | mesoscale_reference, 11,993 cells, dt=18s | 7,137 s (119 m) | Phase 7a initial benchmark. Physics 53% of runtime. |
| `3km-no-tiedtke.md` | 2026-04-14 | Same as baseline + `config_convection_scheme='off'` | 5,451 s (91 m) | 24% faster. Tiedtke is inappropriate at 3km; disabling has no skill cost. |
| `jw-baseline.md` | 2026-04-07 | Pure dynamics, physics='none', global 40,962 cells | 88 s (1m28s) | Phase 6 reference. Peak GPU SM 92%. |
| `jw-memory-models.md` | 2026-04-15 | Same JW case with `-gpu=mem:managed` and `-gpu=mem:unified` | 135 s (2m15s) | **Regression.** Peak SM drops to 32%. These flags do not help MPAS. |

## Hardware

All runs on GB10 host:
- NVIDIA DGX Spark — Grace Blackwell (GB10)
- Cortex-X925 + Cortex-A725, 20 cores
- 128 GB LPDDR5x unified memory
- Ubuntu 24.04 LTS aarch64, NVIDIA HPC SDK 26.3
- MPAS v8.3.1, nvfortran, single precision, OpenACC enabled
- 1 MPI rank, 1 GPU (multi-rank not yet tested)
