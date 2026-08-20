#!/bin/bash
#
# fetch_taxprofiler_db.sh - Download a taxprofiler profiling database with provenance.
#
# Author: Daniel Smith
# Date:   August 20th, 2026
#
# One-time cluster setup, run once per database rather than as part of any
# pipeline. Downloads a database, verifies every file against the publisher's own
# checksums, and writes a manifest recording what was fetched and from where.
#
# Everything taxprofiler reads is fetched fresh by this script even when a copy
# already exists elsewhere on the cluster, so that every database a run touches
# has a recorded origin.
#
# Databases are pinned as constants below rather than resolved to "latest". Both
# pins are the newest release compatible with the tool versions nf-core/taxprofiler
# 2.0.1 uses - notably MetaPhlAn, which is pinned there at 4.1.1 and cannot read
# the database its own mpa_latest marker now points at.
#
# Writes into db/<tool>/:
#
#   <release>/                the database, as the pipeline reads it
#   <release>.manifest.json   source URLs, checksums, sizes, and when it was fetched
#
# Usage:     fetch_taxprofiler_db.sh <kraken2|metaphlan>
#
#            Submit it rather than running it on the login node; both downloads
#            are large and slow:
#            sbatch --cpus-per-task=4 --mem=8G --time=24:00:00 \
#                scripts/fetch_taxprofiler_db.sh kraken2
#
# Requires:  curl, jq, md5sum, tar
# Env:       NEXTFLOW_DIR and the log/warn/fail helpers, sourced from .env
#
# Existing output is left alone; remove db/<tool>/<release> to re-fetch.

set -euo pipefail

source /data/prod/nextflow/.env

# Kraken2 + Bracken, from the Langmead lab's prebuilt collection. PlusPF is
# RefSeq archaea, bacteria, viral, plasmid, human, UniVec_Core, protozoa and
# fungi. The archive carries nodes.dmp and names.dmp, which taxpasta reads, and
# Bracken distributions for 50, 75, 100, 150, 200, 250 and 300-mers.
readonly KRAKEN2_RELEASE="20260626"
readonly KRAKEN2_COLLECTION="pluspf"
readonly KRAKEN2_BASE="https://genome-idx.s3.amazonaws.com/kraken"

# MetaPhlAn. Pinned, not read from mpa_latest: that marker names
# mpa_vJan26_CHOCOPhlAnSGB_202605, which needs MetaPhlAn 4.2 and would fail under
# the 4.1.1 taxprofiler 2.0.1 runs. This is the newest 4.1.1 accepts.
readonly METAPHLAN_INDEX="mpa_vJun23_CHOCOPhlAnSGB_202403"
readonly METAPHLAN_BASE="https://cmprod1.cibio.unitn.it/biobakery4/metaphlan_databases"

if [[ $# -ne 1 ]]; then
    fail "Usage: $0 <kraken2|metaphlan>"
fi

TOOL="$1"

for tool in curl jq md5sum tar; do
    command -v "$tool" > /dev/null || fail "Required tool '$tool' is not installed."
done

WORK_DIR=$(mktemp -d) || fail "Could not create a temporary working directory."
trap 'rm -rf "$WORK_DIR"' EXIT

# Refuse to start a download that cannot land. Both of these need room for the
# archive and the unpacked copy at once.
require_free_space() {
    local dir="$1"
    local needed_gb="$2"
    local available_gb

    available_gb=$(df -BG --output=avail "$dir" | tail -1 | tr -d 'G ')
    if [[ "$available_gb" -lt "$needed_gb" ]]; then
        fail "$dir has ${available_gb}G free; this needs about ${needed_gb}G."
    fi
}

# Download one file and check it against an expected md5
download_verified() {
    local url="$1"
    local dest="$2"
    local expected_md5="$3"

    log "Downloading ${url##*/}..."
    if ! curl -sS --fail --retry 3 -o "$dest" "$url"; then
        fail "Could not download $url"
    fi

    local actual_md5
    actual_md5=$(md5sum "$dest" | cut -d" " -f1)
    if [[ "$actual_md5" != "$expected_md5" ]]; then
        fail "Checksum mismatch on ${url##*/}: expected $expected_md5, got $actual_md5."
    fi
}

# One manifest entry per downloaded archive
SOURCES_JSON="[]"

record_source() {
    SOURCES_JSON=$(printf '%s' "$SOURCES_JSON" | jq \
        --arg url "$1" \
        --arg md5 "$2" \
        --arg bytes "$3" \
        '. + [{url: $url, md5: $md5, bytes: ($bytes | tonumber)}]')
}

write_manifest() {
    local name="$1"
    local path="$2"
    local manifest="$3"
    local notes="$4"

    jq -n \
        --arg name "$name" \
        --arg tool "$TOOL" \
        --arg path "$path" \
        --arg fetched_utc "$(date -u "+%Y-%m-%dT%H:%M:%SZ")" \
        --arg fetched_by "$(whoami)" \
        --arg notes "$notes" \
        --argjson sources "$SOURCES_JSON" \
        '{name: $name, tool: $tool, path: $path, sources: $sources,
          fetched_utc: $fetched_utc, fetched_by: $fetched_by, notes: $notes}' \
        > "$manifest"
}

fetch_kraken2() {
    local release="${KRAKEN2_COLLECTION}_${KRAKEN2_RELEASE}"

    local out_dir="$NEXTFLOW_DIR/db/kraken2/$release"
    local manifest="$NEXTFLOW_DIR/db/kraken2/$release.manifest.json"

    [[ -e "$out_dir" ]] && fail "$out_dir already exists; remove it to re-fetch."

    mkdir -p "$NEXTFLOW_DIR/db/kraken2"
    require_free_space "$NEXTFLOW_DIR/db/kraken2" 200

    local archive_name="k2_${KRAKEN2_COLLECTION}_${KRAKEN2_RELEASE}.tar.gz"
    local archive_url="$KRAKEN2_BASE/$archive_name"
    local checksum_url="$KRAKEN2_BASE/$release/$KRAKEN2_COLLECTION.md5"

    # One md5 per file in the archive, plus one for the archive itself
    log "Fetching checksums from $checksum_url..."
    local checksums="$WORK_DIR/$KRAKEN2_COLLECTION.md5"
    curl -sS --fail --retry 3 -o "$checksums" "$checksum_url" \
        || fail "Could not download the Kraken2 checksum list."

    local expected_md5
    expected_md5=$(awk -v f="$archive_name" '$2 == f {print $1}' "$checksums")
    [[ -n "$expected_md5" ]] || fail "No checksum listed for $archive_name."

    local archive="$WORK_DIR/$archive_name"
    download_verified "$archive_url" "$archive" "$expected_md5"
    record_source "$archive_url" "$expected_md5" "$(stat -c%s "$archive")"

    log "Extracting $archive_name; this takes a while..."
    mkdir -p "$out_dir"
    if ! tar -xzf "$archive" -C "$out_dir"; then
        rm -rf "$out_dir"
        fail "Could not extract $archive_name."
    fi

    # The archive is deleted here rather than on exit, so the extracted copy has
    # room on filesystems that only just fit both
    rm -f "$archive"

    # Every file the publisher listed, checked against its own checksum
    log "Verifying extracted files..."
    local checked=0
    while read -r md5 filename; do
        [[ -z "$filename" || "$filename" == "$archive_name" ]] && continue
        [[ -f "$out_dir/$filename" ]] || fail "Extracted database is missing $filename."

        local actual
        actual=$(md5sum "$out_dir/$filename" | cut -d" " -f1)
        [[ "$actual" == "$md5" ]] || fail "Checksum mismatch on extracted $filename."
        checked=$((checked + 1))
    done < "$checksums"

    log "Verified $checked files."

    cp "$checksums" "$out_dir/"

    write_manifest "$release" "$out_dir" "$manifest" \
        "Kraken2 + Bracken $KRAKEN2_COLLECTION. Includes nodes.dmp and names.dmp for taxpasta, and Bracken distributions for 50, 75, 100, 150, 200, 250 and 300-mers."

    log "Fetched $release:"
    log "  db_path:               $out_dir"
    log "  taxpasta_taxonomy_dir: $out_dir"
    log "  bracken read lengths:  $(cd "$out_dir" && ls database*mers.kmer_distrib 2>/dev/null | tr '\n' ' ')"
    log "  manifest:              $manifest"
}

fetch_metaphlan() {
    local out_dir="$NEXTFLOW_DIR/db/metaphlan/$METAPHLAN_INDEX"
    local manifest="$NEXTFLOW_DIR/db/metaphlan/$METAPHLAN_INDEX.manifest.json"

    [[ -e "$out_dir" ]] && fail "$out_dir already exists; remove it to re-fetch."

    mkdir -p "$NEXTFLOW_DIR/db/metaphlan"
    require_free_space "$NEXTFLOW_DIR/db/metaphlan" 60

    mkdir -p "$out_dir"

    # The marker file metaphlan writes itself; recorded so a mismatch between the
    # pinned index and what is on disk is visible
    printf '%s\n' "$METAPHLAN_INDEX" > "$out_dir/mpa_latest"

    # The bowtie2 index and the pickled marker metadata ship as separate tars
    local part
    for part in "bowtie2_indexes/${METAPHLAN_INDEX}_bt2" "$METAPHLAN_INDEX"; do
        local tar_url="$METAPHLAN_BASE/$part.tar"
        local md5_url="$METAPHLAN_BASE/$part.md5"
        local tar_file="$WORK_DIR/${part##*/}.tar"

        local expected_md5
        expected_md5=$(curl -sS --fail --retry 3 "$md5_url" | awk '{print $1}') \
            || fail "Could not download $md5_url"
        [[ -n "$expected_md5" ]] || fail "Empty checksum at $md5_url"

        download_verified "$tar_url" "$tar_file" "$expected_md5"
        record_source "$tar_url" "$expected_md5" "$(stat -c%s "$tar_file")"

        log "Extracting ${part##*/}.tar..."
        if ! tar -xf "$tar_file" -C "$out_dir"; then
            rm -rf "$out_dir"
            fail "Could not extract ${part##*/}.tar"
        fi

        rm -f "$tar_file"
    done

    # MetaPhlAn ships the bowtie2 index bz2-compressed inside the tar
    if compgen -G "$out_dir/*.bz2" > /dev/null; then
        log "Decompressing bundled files..."
        bunzip2 -f "$out_dir"/*.bz2 || fail "Could not decompress the MetaPhlAn database files."
    fi

    compgen -G "$out_dir/*.pkl" > /dev/null \
        || fail "The MetaPhlAn database has no .pkl file; the download is incomplete."
    compgen -G "$out_dir/*.bt2l" > /dev/null || compgen -G "$out_dir/*.bt2" > /dev/null \
        || fail "The MetaPhlAn database has no bowtie2 index; the download is incomplete."

    write_manifest "$METAPHLAN_INDEX" "$out_dir" "$manifest" \
        "Newest database MetaPhlAn 4.1.1 accepts, which is the version nf-core/taxprofiler 2.0.1 pins. mpa_latest currently names a newer database requiring MetaPhlAn 4.2."

    log "Fetched $METAPHLAN_INDEX:"
    log "  db_path:  $out_dir"
    log "  manifest: $manifest"
}

case "$TOOL" in
    kraken2)   fetch_kraken2 ;;
    metaphlan) fetch_metaphlan ;;
    *)         fail "Unknown database '$TOOL'. Use kraken2 or metaphlan." ;;
esac
