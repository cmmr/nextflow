# rbiom.nix - R with rbiom, for the tables an ampliseq run publishes.
#
# Author: Daniel Smith
# Date:   September 3rd, 2026
#
# Builds the image scripts/R/ampliseq_tables.R runs in: R, rbiom, h5lite and
# phyloseq, with everything under them pinned by one nixpkgs revision.
#
# ecodive is not named here. rbiom Imports it, so it comes in as a dependency
# whether or not it is asked for. h5lite is a different case - rbiom only
# Suggests it, so nothing pulls it in on its own, and without it write_biom()
# cannot produce the HDF5 feature table.
#
#
# BUILDING IT
#
# nix is not installed on the cluster. It runs out of an apptainer sandbox
# instead, which also gives the build a package cache that survives between
# images - see docs/operations/nix.md for the whole of it. Once that sandbox
# exists:
#
#     cd "$NEXTFLOW_DIR/nix"
#     apptainer exec -B /data --writable "$NIX_DIR" nix-build rbiom.nix
#
# nix-build leaves a ./result symlink pointing at the image tarball. That path
# is a /nix/store path *inside* the sandbox, so it has to be read against the
# sandbox root to name a file the host can see:
#
#     apptainer build rbiom.sif "docker-archive:$NIX_DIR$(readlink -f result)"
#     rm -f result
#
# Then move the image where the pipeline looks for it and point .env at it:
#
#     mv rbiom.sif "$NEXTFLOW_DIR/opt/rbiom.sif"
#     export RBIOM_CONTAINER="$NEXTFLOW_DIR/opt/rbiom.sif"
#
#
# RUNNING IT
#
#     apptainer exec -B /data "$NEXTFLOW_DIR/opt/rbiom.sif" \
#         Rscript -e 'packageVersion("rbiom")'
#
# which is the same shape ampliseq_composition.sh invokes it in.
#
#
# CHANGING WHAT IS IN IT
#
# Add package names to `packages` below and rebuild. Names are nixpkgs'
# rPackages attribute names, which are the CRAN and Bioconductor names with
# dots turned into underscores. Search them at https://search.nixos.org, or
# read them out of the pinned revision:
#
#     pkgs/development/r-modules/cran-packages.json
#     pkgs/development/r-modules/bioc-packages.json
#
# Bumping the pin below is what moves every version at once. The R package set
# is regenerated per nixpkgs revision, so a revision carries exactly one version
# of each package - which is the point, and also the thing to check before
# moving it.

let

  # Pinned by revision rather than by channel, so this file describes one
  # closure rather than whatever a channel points at today. This is
  # nixos-unstable as of 2026-09-02.
  #
  # It is unstable rather than a release branch because nixos-26.05 carries
  # rbiom 2.2.1, and ampliseq_tables.R is written against the 3.x API -
  # as_rbiom(), adiv_matrix(), and the R6 accessors.
  #
  # Revision                                 rbiom    ecodive  h5lite    phyloseq
  # 3ed67ec0a4d3c7ab4ae1f04f8ee8df07bfa506a2 3.1.0    2.2.6    2.1.1.1   1.56.0
  #
  # The revision fixes the content on its own. Adding the sha256 lets nix skip
  # the download when the tarball is already in the store, and refuses one that
  # does not match. To fill it in, run this inside the sandbox and paste what it
  # prints:
  #
  #     nix-prefetch-url --unpack \
  #       https://github.com/NixOS/nixpkgs/archive/<rev>.tar.gz
  #
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/3ed67ec0a4d3c7ab4ae1f04f8ee8df07bfa506a2.tar.gz";
    # sha256 = "";
  };

  pkgs = import nixpkgs { system = "x86_64-linux"; };

  # rWrapper wraps every binary in R/bin - Rscript among them - with
  # R_LIBS_SITE pointing at these packages, so nothing has to be installed at
  # run time and nothing reads a user library.
  rEnv = pkgs.rWrapper.override {
    packages = with pkgs.rPackages; [
      rbiom
      h5lite
      phyloseq
    ];
  };

in

# A layered OCI image rather than a .sif directly. nixpkgs can build a SIF with
# singularity-tools, but it does that inside a QEMU VM with a disk size given up
# front, which an R closure overruns. apptainer converts the tarball itself.
pkgs.dockerTools.buildLayeredImage {
  name = "rbiom";
  tag = "latest";

  copyToRoot = pkgs.buildEnv {
    name = "image-root";
    paths = [
      rEnv
      pkgs.bashInteractive
      pkgs.coreutils
    ];
    pathsToLink = [
      "/bin"
      "/lib"
      "/share"
    ];
  };

  config = {
    Env = [
      "PATH=/bin"
      "LC_ALL=C.UTF-8"
    ];
  };
}
