# mpas-gpu

Public, BSD-3 monorepo bundling NCAR's MPAS-Atmosphere model with the shared MMM-physics layer, plus original OpenACC GPU ports of select physics modules and tuning notes for NVIDIA Grace Blackwell unified-memory hardware.

This is a downstream **research demonstrator and consumer** of NCAR's MPAS work. The dycore-OpenACC effort is upstream NCAR's; the original contribution here is on the physics side and the whole-system memory-model experiments.

## What's in here

```
components/
  MPAS-Model/                                                # subtree of MPAS-Atmosphere (BSD-3, MPAS-Dev)
    src/core_atmosphere/physics/
      physics_mmm/                                           # subtree of MMM-physics (BSD-3, NCAR/MMM)
                                                             # — nested at the path the MPAS build expects
configs/                                                     # namelists, queue specs, streams templates
scripts/                                                     # build wrappers, run-queue runner
benchmarks/                                                  # measured results per stage (wall, GPU util, timers)
probes/                                                      # GPU profiling captures + analysis
run/                                                         # runtime env setup, forecast launcher
docs/                                                        # methodology, findings, upstream-sync workflow
```

## What's novel here

Public OpenACC GPU ports of MPAS-A physics modules — a niche where, at the time of writing, no other public artifact exists:

- **WSM6 microphysics** — full GPU port across 22 fused parallel regions. Branch: `wsm6-openacc` in the MMM-physics fork.
- **MYNN PBL** — column-parallel GPU port. Branch: `mynn-openacc`.
- **YSU PBL** — initial port. Branch: `ysu-openacc`.
- **Noah-MP land surface** — Part 1 ported.
- **RRTMGP radiation** — integration on GPU path.

The closest published analog is Kim & Kang 2021 (*Computers & Geosciences*) — WSM6 OpenACC at 2.4-5.7× speedup, but no public repo. Upstream MPAS-A's own OpenACC port covers the dycore only; the MPAS-A user forum confirms no GPU MYNN exists in any branch (April 2022).

## Hardware target

- **Primary**: NVIDIA Grace Blackwell GB10 (DGX Spark / "huginn") — Arm v9 (Cortex-X925/A725), Blackwell GPU sm_121a, 128 GB LPDDR5x unified memory
- **Future**: GB200 NVL72 / Blackwell cloud clusters (mostly the same code path)
- **Compiler**: NVIDIA HPC SDK 26.3 (`nvfortran` 26.3) on Ubuntu 24.04 aarch64
- **MPI**: NVHPC-bundled OpenMPI 4.1.7
- **Libraries**: system `netCDF-C`, `netCDF-Fortran`, `pnetcdf`

## Setup

```bash
git clone git@github.com:GravityDeficient/mpas-gpu.git
cd mpas-gpu/components/MPAS-Model
make nvhpc CORE=atmosphere PRECISION=single OPENACC=true USE_PIO2=true
```

That's it — no setup step. MMM-physics lives at the path the upstream Makefile expects (`src/core_atmosphere/physics/physics_mmm/`), nested directly inside MPAS-Model as a git subtree. No symlinks, no copy step, no patch to upstream Makefile.

## Repo organization

This is a `git subtree` monorepo. The MPAS-Model subtree carries the full history of [GravityDeficient/MPAS-Model](https://github.com/GravityDeficient/MPAS-Model). The MMM-physics subtree, nested at `components/MPAS-Model/src/core_atmosphere/physics/physics_mmm/`, carries the history of [GravityDeficient/MMM-physics](https://github.com/GravityDeficient/MMM-physics). You can edit either in place; you can pull NCAR upstream into the relevant fork and `subtree pull` it back; experimental branches can be pushed back to the source forks via `subtree push`.

See [`docs/upstream-sync.md`](docs/upstream-sync.md) for the four `git subtree pull/push` commands and prefix paths.

## Branches

- `main` — clean, integration-tested
- `wsm6-openacc` — production-tip WSM6 GPU port (22 kernels, validated at 3km Bay Area mesh)
- `mynn-openacc` — column-parallel MYNN PBL GPU port (not yet rebased onto current main)
- `wsm6-stage-e` — experimental outer-`!$acc data` region wrapper (hung GB10 in current form, under investigation)
- Other ports on similarly named branches

## License

BSD-3-Clause across both components, inherited from upstream NCAR. See `components/MPAS-Model/LICENSE` and `components/MPAS-Model/src/core_atmosphere/physics/physics_mmm/LICENSE`.

Original code in this repo (build scripts, config templates, benchmarks) is also BSD-3.

## Status

Active research project, single-developer scope. Not a supported product. Issues and PRs welcome but response cadence is hobbyist, not institutional.

For dycore questions, defer to upstream NCAR ([MPAS-Dev/MPAS-Model](https://github.com/MPAS-Dev/MPAS-Model)). For physics module questions touching the OpenACC ports, this repo is the right place.
