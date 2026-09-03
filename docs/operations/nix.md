# Nix

Where the container images this system builds for itself come from, and how to
add another.

Most of what the pipelines run comes from [BioContainers](https://biocontainers.pro)
as `docker://quay.io/biocontainers/...`, pinned by tag. That works for anything
bioconda packages. It does not cover the R toolchain
[`ampliseq_tables.R`](../results/composition.md) needs — rbiom, h5lite and
phyloseq are CRAN and Bioconductor packages, on conda-forge rather than bioconda,
so no BioContainer is built for them.

Nix covers it. Every one of those packages is in nixpkgs, at the versions we
want, and a pinned revision describes the whole closure — R itself, every
transitive C library — in one file in this repository. The distinction that
matters against a build service is **rebuildable rather than re-pullable**: a
tag from a registry can be fetched again for as long as someone keeps hosting
it, but [`nix/rbiom.nix`](../../nix/rbiom.nix) can be rebuilt from scratch on a
machine that has never seen it.

## Nix is not installed on the cluster

It runs out of an apptainer sandbox instead. Nothing is installed system-wide,
nothing needs root, and the sandbox keeps a package cache in its own
`/nix/store` that every later image build draws on.

Set up once:

```bash
export NIX_DIR="$NEXTFLOW_DIR/nix/sandbox"
```

```bash
apptainer build --sandbox "$NIX_DIR" docker://nixos/nix
```

```bash
rm "$NIX_DIR/etc/nix/nix.conf"
echo "sandbox = false" > "$NIX_DIR/etc/nix/nix.conf"
```

**`sandbox = false` is what makes it work at all.** Nix's own build sandbox
wants to create user namespaces, and it is already inside one — apptainer's.
Nesting them fails, so nix is told not to try. It costs the build isolation nix
would otherwise give itself, which does not matter here: the sandbox is a
throwaway directory that only ever builds our own images.

Then make a mount point for the bind the builds use:

```bash
mkdir -p "$NIX_DIR/data"
```

**`--writable` will not create that for you.** Apptainer normally conjures a
missing bind destination in an overlay laid over the image, but `--writable`
turns that layer off — the whole point of it is that writes land in the sandbox
directory itself. So a bind destination has to be a real directory in the
sandbox before it can be mounted over, and without this one the build fails at
startup rather than part way through:

```
WARNING: By using --writable, Apptainer can't create /data destination
         automatically without overlay or underlay
FATAL:   container creation failed: mount hook function failure:
         destination /data doesn't exist in container
```

Since `$NEXTFLOW_DIR` lives under `/data`, this is also what makes the current
working directory resolve inside the container — apptainer binds the CWD by
default, and that bind needs the same destination to exist.

`$NIX_DIR` is a working directory, not a deliverable. It is a few gigabytes
after the first R build and it is excluded from git along with the rest of
`nix/sandbox/`. Delete it and the next build is slow rather than broken.

## Building an image

```bash
cd "$NEXTFLOW_DIR/nix"
```

```bash
apptainer exec -B /data --writable "$NIX_DIR" nix-build rbiom.nix
```

`nix-build` leaves a `./result` symlink behind. **It does not point where it
looks like it points.** The target is a `/nix/store/...` path *inside* the
sandbox, and there is no `/nix/store` on the host — so the path has to be read
against the sandbox root before apptainer can find the file:

```bash
apptainer build rbiom.sif "docker-archive:$NIX_DIR$(readlink -f result)"
```

`readlink -f` resolves the symlink without requiring the target to exist, which
is why this works from the host at all. Prefixing `$NIX_DIR` turns the
in-sandbox path into the host path for the same bytes, so nothing is copied.

Then put it where the pipeline looks and clear up:

```bash
rm -f result
```

```bash
mv rbiom.sif "$NEXTFLOW_DIR/opt/rbiom.sif"
```

Images live in `opt/` beside the other things this system installs for itself —
[the JDK, apptainer and globus-cli](cluster-requirements.md) — rather than in
`db/`, which is data, or in git, which is neither.

Check it before wiring it in:

```bash
apptainer exec -B /data "$NEXTFLOW_DIR/opt/rbiom.sif" Rscript -e 'library(rbiom); packageVersion("rbiom")'
```

The one thing worth checking beyond that it starts is whether `Rscript` is found
on `PATH`. `ampliseq_composition.sh` calls it by bare name; if apptainer's own
`PATH` defaults win over the image's, the fix is `/bin/Rscript` in that script
rather than a change here.

Finally, point [`.env`](../configuration.md) at it:

```bash
export RBIOM_CONTAINER="/data/prod/nextflow/opt/rbiom.sif"
```

## Adding another image

One `.nix` file per image, in [`nix/`](../../nix), named after what it holds.
Copy `rbiom.nix`, change the package list and the name, and build it the same
way. The file is expected to carry its own build and run instructions in
comments at the top, so that a reader who opens it never has to find this page
first.

Three things to keep to:

**Pin nixpkgs by revision, not by channel.** `builtins.fetchTarball` on a commit
URL describes one closure forever. A channel name describes whatever that
channel points at the day you build, which is the problem this was meant to
solve.

**Check what the pin actually carries before moving it.** The R package set is
regenerated per nixpkgs revision, so a revision carries exactly one version of
each package. `rbiom.nix` is pinned to nixos-unstable rather than a release
branch for exactly this reason — `nixos-26.05` carries rbiom 2.2.1, and
`ampliseq_tables.R` is written against the 3.x API. The versions a revision
holds are in its own tree:

```
pkgs/development/r-modules/cran-packages.json
pkgs/development/r-modules/bioc-packages.json
```

**Build the OCI tarball, not a SIF.** nixpkgs has `singularity-tools.buildImage`,
but it runs the build inside a QEMU VM with a disk size given up front, and an R
closure overruns the default. `dockerTools.buildLayeredImage` and then
`apptainer build` is the route with fewer moving parts. Note it takes
`contents`, a plain list of derivations — `copyToRoot` belongs to
`dockerTools.buildImage`, and the layered builder rejects it.

**Being in nixpkgs is not a promise that it builds.** The R sets are generated
from CRAN and Bioconductor metadata rather than from anything that compiled, so
a package needing a patch needs it written into the `.nix` file.
[`rbiom.nix`](../../nix/rbiom.nix) carries one for `hdf5lib`, which copies R's
headers out of the read-only store with their permissions attached and then
cannot clean up after itself.

Where a patched package is a *dependency* of something else in the set — as
`hdf5lib` is of `h5lite` — the override has to go through the set rather than
round it:

```nix
rPkgs = pkgs.rPackages.override { overrides = { hdf5lib = ...; }; };
```

`r-modules/default.nix` merges `overrides` into the set's fixed point, so
everything that depends on the patched package picks it up. Overriding
`pkgs.rPackages.hdf5lib` on its own changes only what *you* reference, and
`h5lite` would go on building against the unpatched one.

## Keeping the cache in hand

The sandbox's store grows with every build and never shrinks on its own. To
reclaim what nothing points at:

```bash
apptainer exec -B /data --writable "$NIX_DIR" nix-collect-garbage -d
```

Anything still needed is re-downloaded from the nixpkgs binary cache next time,
so this is safe to run whenever the directory gets uncomfortable. Deleting
`$NIX_DIR` outright is also safe, and rebuilds from nothing.
