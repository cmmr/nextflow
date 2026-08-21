#!/bin/bash
#
# build_host_reference.sh - Download genomes from NCBI and build one bowtie2 index.
#
# Author: Daniel Smith
# Date:   August 20th, 2026
#
# One-time cluster setup for the taxprofiler pipelines' host-depletion step, run
# once per reference rather than as part of any pipeline. Takes a name and one or
# more NCBI assembly accessions, concatenates their genomes into a single FASTA,
# and builds a bowtie2 index over it.
#
# Multiple accessions become one reference because that is all taxprofiler
# accepts: it takes a single FASTA and a single index, so a host plus PhiX is one
# concatenated reference rather than two databases.
#
# Writes four things into db/hostremoval/:
#
#   <name>.fa             the concatenated reference, named by hostremoval_reference
#   <name>/               the bowtie2 index, named by shortread_hostremoval_index
#   <name>.mmi            the minimap2 index, named by longread_hostremoval_index
#   <name>.manifest.json  what went in, from where, and how
#
# Both indexes are built because instrument_platform decides which one a sample
# uses, and that is read from the data rather than from the pipeline. The
# minimap2 index is built with -x map-ont to match what taxprofiler's
# MINIMAP2_INDEX would have produced.
#
# The manifest is the point. A reference whose provenance is not recorded cannot
# be reproduced or audited later.
#
# Accessions are resolved against NCBI's directory listing rather than assembled
# by hand, since the FTP path carries the assembly name as well as the accession.
# Each download is checked against NCBI's own md5checksums.txt.
#
# Usage:     build_host_reference.sh <name> <accession> [accession...]
#            e.g. build_host_reference.sh chm13v2phix GCF_009914755.1 GCF_000819615.1
#
#            Submit it rather than running it on the login node:
#            sbatch --cpus-per-task=32 --mem=64G --time=12:00:00 \
#                scripts/build_host_reference.sh <name> <accession>...
#
# Requires:  curl, jq, md5sum, apptainer
# Env:       NEXTFLOW_DIR and the log/warn/fail helpers, sourced from .env
#
# Existing output is left alone; remove <name>.fa and <name>/ to rebuild.

set -euo pipefail

source /data/prod/nextflow/.env

# The builds taxprofiler 2.0.1's BOWTIE2_BUILD and MINIMAP2_INDEX use, so an
# index built here matches the aligner that reads it
readonly BOWTIE2_CONTAINER="docker://community.wave.seqera.io/library/bowtie2_htslib_samtools_pigz:edeb13799090a2a6"
# quay.io, not the bare biocontainers/... the nf-core module names: that string
# is a Docker Hub reference, and Docker Hub does not carry the conda build tags.
readonly MINIMAP2_CONTAINER="docker://quay.io/biocontainers/minimap2:2.29--h577a1d6_0"

# taxprofiler's MINIMAP2_INDEX sets this; an .mmi is only valid for the preset it
# was built with
readonly MINIMAP2_PRESET="-x map-ont"

readonly NCBI_GENOMES="https://ftp.ncbi.nlm.nih.gov/genomes/all"

readonly OUT_DIR="$NEXTFLOW_DIR/db/hostremoval"

if [[ $# -lt 2 ]]; then
    fail "Usage: $0 <name> <accession> [accession...]"
fi

NAME="$1"
shift
ACCESSIONS=("$@")

# The name becomes a directory, a filename, and part of a params path
if [[ ! "$NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail "Reference name may only contain letters, digits, dots, dashes and underscores: $NAME"
fi

for accession in "${ACCESSIONS[@]}"; do
    if [[ ! "$accession" =~ ^GC[AF]_[0-9]{9}\.[0-9]+$ ]]; then
        fail "Not an NCBI assembly accession: $accession"
    fi
done

for tool in curl jq md5sum apptainer; do
    command -v "$tool" > /dev/null || fail "Required tool '$tool' is not installed."
done

# Resolve both containers before doing any work. The minimap2 index is built
# last, so without this an unreachable image is only discovered after the
# bowtie2 build has already spent an hour or two.
for container in "$BOWTIE2_CONTAINER" "$MINIMAP2_CONTAINER"; do
    log "Checking $container..."
    apptainer exec "$container" true > /dev/null 2>&1 \
        || fail "Could not pull the container '$container'."
done

REFERENCE="$OUT_DIR/$NAME.fa"
INDEX_DIR="$OUT_DIR/$NAME"
MINIMAP2_INDEX="$OUT_DIR/$NAME.mmi"
MANIFEST="$OUT_DIR/$NAME.manifest.json"

if [[ -e "$REFERENCE" || -e "$INDEX_DIR" || -e "$MINIMAP2_INDEX" ]]; then
    fail "$NAME already exists in $OUT_DIR; remove $NAME.fa, $NAME/ and $NAME.mmi to rebuild."
fi

mkdir -p "$OUT_DIR"

THREADS="${SLURM_CPUS_PER_TASK:-${SLURM_CPUS_ON_NODE:-1}}"

WORK_DIR=$(mktemp -d) || fail "Could not create a temporary working directory."
trap 'rm -rf "$WORK_DIR"' EXIT

# The FTP directory for an accession, e.g. GCF_009914755.1 resolves to
# .../GCF/009/914/755/GCF_009914755.1_T2T-CHM13v2.0. Read from the listing
# because the trailing assembly name is not derivable from the accession.
resolve_assembly_dir() {
    local accession="$1"
    local prefix=${accession%%_*}
    local digits=${accession#*_}
    digits=${digits%%.*}

    local base="$NCBI_GENOMES/$prefix/${digits:0:3}/${digits:3:3}/${digits:6:3}"

    local listing
    listing=$(curl -sS --fail --retry 3 "$base/") || return 1

    local dir
    dir=$(printf '%s' "$listing" | grep -o "href=\"${accession}_[^\"]*/\"" | head -1)
    dir=${dir#href=\"}
    dir=${dir%/\"}

    [[ -n "$dir" ]] || return 1

    printf '%s/%s' "$base" "$dir"
}

# Accumulated for the manifest, one entry per accession
SOURCES_JSON="[]"

# 1. Download each assembly and concatenate it into one reference.
log "Building host reference '$NAME' from ${#ACCESSIONS[@]} assemblies..."

for accession in "${ACCESSIONS[@]}"; do
    log "Resolving $accession..."

    if ! ASSEMBLY_URL=$(resolve_assembly_dir "$accession"); then
        fail "Could not find assembly $accession on NCBI."
    fi

    ASSEMBLY_NAME=${ASSEMBLY_URL##*/}
    FASTA_NAME="${ASSEMBLY_NAME}_genomic.fna.gz"
    FASTA_GZ="$WORK_DIR/$FASTA_NAME"

    log "Downloading $ASSEMBLY_NAME..."
    if ! curl -sS --fail --retry 3 -o "$FASTA_GZ" "$ASSEMBLY_URL/$FASTA_NAME"; then
        fail "Could not download $FASTA_NAME from NCBI."
    fi

    # NCBI publishes a checksum per file; a truncated genome would otherwise
    # build into a silently incomplete index
    if ! CHECKSUMS=$(curl -sS --fail --retry 3 "$ASSEMBLY_URL/md5checksums.txt"); then
        fail "Could not download md5checksums.txt for $accession."
    fi

    EXPECTED_MD5=$(printf '%s\n' "$CHECKSUMS" | awk -v f="./$FASTA_NAME" '$2 == f {print $1}')
    [[ -n "$EXPECTED_MD5" ]] || fail "NCBI lists no checksum for $FASTA_NAME."

    ACTUAL_MD5=$(md5sum "$FASTA_GZ" | cut -d" " -f1)
    if [[ "$ACTUAL_MD5" != "$EXPECTED_MD5" ]]; then
        fail "Checksum mismatch on $FASTA_NAME: expected $EXPECTED_MD5, got $ACTUAL_MD5."
    fi

    log "Appending $ASSEMBLY_NAME to the reference..."
    gunzip -c "$FASTA_GZ" >> "$WORK_DIR/$NAME.fa"

    SOURCES_JSON=$(printf '%s' "$SOURCES_JSON" | jq \
        --arg accession "$accession" \
        --arg assembly "$ASSEMBLY_NAME" \
        --arg url "$ASSEMBLY_URL/$FASTA_NAME" \
        --arg md5 "$ACTUAL_MD5" \
        '. + [{accession: $accession, assembly: $assembly, url: $url, md5: $md5}]')
done

mv "$WORK_DIR/$NAME.fa" "$REFERENCE"

# 2. Build the index. BOWTIE2_ALIGN finds the basename by globbing the directory
#    for *.rev.1.bt2, so the index only has to be alone in one.
mkdir -p "$INDEX_DIR"

BUILD_COMMAND="bowtie2-build --threads $THREADS $REFERENCE $INDEX_DIR/$NAME"

log "Building the bowtie2 index with $THREADS threads; this takes a while..."
if ! apptainer exec -B /data "$BOWTIE2_CONTAINER" $BUILD_COMMAND; then
    rm -rf "$INDEX_DIR"
    fail "bowtie2-build failed for $NAME."
fi

# An index missing this is one BOWTIE2_ALIGN refuses to use
if ! compgen -G "$INDEX_DIR/*.rev.1.bt2*" > /dev/null; then
    fail "bowtie2-build reported success but wrote no .rev.1.bt2 file."
fi

# 3. Build the minimap2 index for the long-read path. Named as a file rather than
#    a directory, which is what longread_hostremoval_index expects.
MINIMAP2_COMMAND="minimap2 -t $THREADS -d $MINIMAP2_INDEX $MINIMAP2_PRESET $REFERENCE"

log "Building the minimap2 index..."
if ! apptainer exec -B /data "$MINIMAP2_CONTAINER" $MINIMAP2_COMMAND; then
    rm -f "$MINIMAP2_INDEX"
    fail "minimap2 indexing failed for $NAME."
fi

[[ -s "$MINIMAP2_INDEX" ]] || fail "minimap2 reported success but wrote no .mmi file."

# 4. Record what was built, so the reference can be audited or reproduced.
BOWTIE2_VERSION=$(apptainer exec "$BOWTIE2_CONTAINER" bowtie2-build --version 2>/dev/null | head -1) \
    || BOWTIE2_VERSION="unknown"
MINIMAP2_VERSION=$(apptainer exec "$MINIMAP2_CONTAINER" minimap2 --version 2>/dev/null | head -1) \
    || MINIMAP2_VERSION="unknown"

jq -n \
    --arg name "$NAME" \
    --arg reference "$REFERENCE" \
    --arg reference_md5 "$(md5sum "$REFERENCE" | cut -d" " -f1)" \
    --arg bowtie2_index "$INDEX_DIR" \
    --arg bowtie2_container "$BOWTIE2_CONTAINER" \
    --arg bowtie2_version "$BOWTIE2_VERSION" \
    --arg bowtie2_command "$BUILD_COMMAND" \
    --arg minimap2_index "$MINIMAP2_INDEX" \
    --arg minimap2_container "$MINIMAP2_CONTAINER" \
    --arg minimap2_version "$MINIMAP2_VERSION" \
    --arg minimap2_command "$MINIMAP2_COMMAND" \
    --arg built_utc "$(date -u "+%Y-%m-%dT%H:%M:%SZ")" \
    --arg built_by "$(whoami)" \
    --argjson sources "$SOURCES_JSON" \
    '{name: $name, reference: $reference, reference_md5: $reference_md5,
      sources: $sources, built_utc: $built_utc, built_by: $built_by,
      bowtie2: {index: $bowtie2_index, container: $bowtie2_container,
                tool_version: $bowtie2_version, command: $bowtie2_command},
      minimap2: {index: $minimap2_index, container: $minimap2_container,
                 tool_version: $minimap2_version, command: $minimap2_command}}' \
    > "$MANIFEST"

log "Built $NAME:"
log "  hostremoval_reference:       $REFERENCE"
log "  shortread_hostremoval_index: $INDEX_DIR"
log "  longread_hostremoval_index:  $MINIMAP2_INDEX"
log "  manifest:                    $MANIFEST"
