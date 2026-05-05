# Upstream sync workflow

This monorepo bundles two NCAR-derived components via `git subtree`:

- `components/MPAS-Model/` — subtree of [GravityDeficient/MPAS-Model](https://github.com/GravityDeficient/MPAS-Model) (fork of [MPAS-Dev/MPAS-Model](https://github.com/MPAS-Dev/MPAS-Model))
- `components/MPAS-Model/src/core_atmosphere/physics/physics_mmm/` — subtree of [GravityDeficient/MMM-physics](https://github.com/GravityDeficient/MMM-physics) (fork of [NCAR/MMM-physics](https://github.com/NCAR/MMM-physics)), nested at the path the MPAS-Model build expects

Subtree means the history of each component is *part of* this repo's history under the corresponding prefix. You can edit components in place; you can pull NCAR updates into the relevant fork and `subtree pull` them back; experimental branches can be `subtree push`'d to the source forks.

## Why MMM-physics is nested inside MPAS-Model

MPAS-Model's physics Makefile hardcodes `physics_mmm/` as a sibling of `physics_wrf/`, `physics_noahmp/`, etc. The rules use `cd physics_mmm; $(MAKE) -f Makefile.mpas all` (line 61) and `-I./physics_mmm` in the compile rules (lines 273, 275). NCAR's official workflow is "user clones MMM-physics into that directory before building." This repo bakes that step into the monorepo structure: the subtree lives at the path the build expects, so `git clone && make` works with no setup step.

This means MMM-physics is **not** a top-level sibling of MPAS-Model in the layout. To find the WSM6 port, look under `components/MPAS-Model/src/core_atmosphere/physics/physics_mmm/mp_wsm6.F90`.

> **Wrapper distinction**: `physics_wrf/module_mp_wsm6.F` is a 239-line MPAS-specific *wrapper* that calls `mp_wsm6_run` from MMM-physics. It is NOT a vendored copy of `mp_wsm6.F90` (which is 2,568 lines). Two different files, two different purposes — never cross-overwrite.

## The four upstream-sync commands

### Pull NCAR upstream MPAS-Model into your fork, then into the monorepo

```bash
# In ~/Projects/MPAS-Model/ (your fork — kept around as a sync buffer)
git fetch upstream                    # upstream = git@github.com:MPAS-Dev/MPAS-Model.git
git checkout main && git merge upstream/main
git push origin main

# Back in mpas-gpu/
git subtree pull --prefix=components/MPAS-Model \
    git@github.com:GravityDeficient/MPAS-Model.git main --squash
```

**Caveat**: this monorepo removed the `physics_mmm` line from the inner gitignore (`components/MPAS-Model/src/core_atmosphere/physics/.gitignore`) so the nested MMM-physics subtree files stay tracked. An upstream MPAS-Model pull that touches that gitignore will conflict — resolve in favor of the local version (keep the line removed). Other conflict risk is low because NCAR doesn't ship files under `physics_mmm/`.

### Pull NCAR upstream MMM-physics into the monorepo

```bash
# In ~/Projects/MMM-physics/
git fetch upstream                    # upstream = git@github.com:NCAR/MMM-physics.git
git checkout main && git merge upstream/main
git push origin main

# Back in mpas-gpu/
git subtree pull --prefix=components/MPAS-Model/src/core_atmosphere/physics/physics_mmm \
    git@github.com:GravityDeficient/MMM-physics.git main --squash
```

### Push a monorepo branch back to MPAS-Model fork

```bash
# From mpas-gpu/, on a branch that has changes inside components/MPAS-Model/
git subtree push --prefix=components/MPAS-Model \
    git@github.com:GravityDeficient/MPAS-Model.git \
    feature-branch-name
```

### Push a monorepo branch back to MMM-physics fork

```bash
git subtree push --prefix=components/MPAS-Model/src/core_atmosphere/physics/physics_mmm \
    git@github.com:GravityDeficient/MMM-physics.git \
    feature-branch-name
```

The `physics_mmm` prefix is long but consistent — wrap it in a shell function or makefile target if you find yourself typing it often.

## Why subtree, not submodule

Subtree imports the component's history into this repo as a real merge. Editing a file in `components/MPAS-Model/...` is a normal commit — no separate clone, no pointer bump, no two-step push. The tradeoff: a clone of mpas-gpu is bigger (history of all three repos combined), but for a single-developer project that's the right tradeoff.

## Branch strategy in the monorepo

- `main` — clean, public-facing, tracks integration of working components
- Feature branches — match the names you'd want upstream-acceptable: `wsm6-openacc`, `mynn-openacc`, etc. These can be `git subtree push`'d to the relevant fork when ready.
- Experimental branches — anything you don't want to upstream stays in the monorepo only.

## Setup checklist for a fresh clone

```bash
git clone git@github.com:GravityDeficient/mpas-gpu.git
cd mpas-gpu/components/MPAS-Model
make nvhpc CORE=atmosphere PRECISION=single OPENACC=true USE_PIO2=true
```

No setup step — MMM-physics already lives at the path the build expects.
