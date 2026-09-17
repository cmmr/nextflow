#!/bin/bash
#
# fetch_taxprofiler_db.sh - Download a taxprofiler profiling database with provenance.
#
# Author: Daniel Smith
# Date:   August 20th, 2026
#
# One-time cluster setup, run once per database rather than as part of any
# pipeline. Downloads a database, verifies every file against a checksum, and
# writes a manifest recording what was fetched and from where.
#
# Two publishers list no checksum. The MetaPhlAn phylogeny is pinned below by
# the md5 of the file as fetched. The three HUMAnN archives have their md5
# computed here and recorded in the manifest rather than checked against a
# published value; what verifies those is their contents - the same two checks
# HUMAnN itself makes on a ChocoPhlAn directory, and the presence of every other
# file a run goes on to read.
#
# Everything taxprofiler reads is fetched fresh by this script even when a copy
# already exists elsewhere on the cluster, so that every database a run touches
# has a recorded origin.
#
# Databases are pinned as constants below rather than resolved to "latest". Every
# pin is the newest release compatible with the tool versions nf-core/taxprofiler
# 2.0.1 uses - notably MetaPhlAn, which is pinned there at 4.1.1 and cannot read
# the database its own mpa_latest marker now points at, and mOTUs, which is
# pinned there at 3.1.0 and rejects the v4 catalogues outright. EsViritu and
# Marker-MAGu, which only the biobakery workflow runs, are pinned to the newest
# release each reads.
#
# Writes into db/<tool>/:
#
#   <release>/                the database, as the pipeline reads it
#   <release>.manifest.json   source URLs, checksums, sizes, and when it was fetched
#
# "sewage" is the one argument that fetches no database: it is five runs of
# sewage reads, into db/test-fastq/, for a run that should find viruses.
#
# Usage:     fetch_taxprofiler_db.sh <kraken2|metaphlan|motus|humann|esviritu|markermagu|sewage>
#
#            Submit it rather than running it on the login node; the downloads
#            are large and slow:
#            sbatch --cpus-per-task=4 --mem=8G --time=24:00:00 \
#                scripts/fetch_taxprofiler_db.sh kraken2
#
# Requires:  curl, jq, md5sum, sha256sum, tar
# Env:       NEXTFLOW_DIR and the log/warn/fail helpers, sourced from .env
#
# Existing output is left alone; remove db/<tool>/<release> to re-fetch. The one
# exception is the MetaPhlAn phylogeny: a database installed before this script
# fetched one gets the tree on its own rather than a 26 GB re-download.

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

# The maximum-likelihood phylogeny of this release's SGBs, 36,273 tips labelled
# with the bare SGB number that the t__SGB rows of a MetaPhlAn profile carry.
# scripts/R/taxprofiler_tables.R reads it into the BIOM the run publishes, which
# is what makes UniFrac and Faith's PD computable over that profile.
#
# The publisher lists no checksum for it, so this md5 is the file as fetched on
# 2026-09-04 rather than one they gave; a mismatch means the release moved under
# its own name and the tree wants re-checking against the database beside it.
readonly METAPHLAN_TREE_MD5="b141b49693f541ae491605d2f1cfc981"

# mOTUs. The database is version-locked to the tool: taxprofiler 2.0.1 runs
# MOTUS_PROFILE in the motus 3.1.0 container, and mOTUs checks the version file
# inside the database against its own before it profiles anything. The URL and
# the checksum below are the ones "motus downloadDB" itself uses for 3.1.0, so
# what lands here is what that command would have installed.
#
# The v4 catalogues published at sunagawalab.ethz.ch are not an upgrade path
# from here: they are raw gene catalogues for mOTUs 4, which is a different tool
# with a different database layout, and taxprofiler 2.0.1 cannot run it.
readonly MOTUS_VERSION="3.1.0"
readonly MOTUS_RELEASE="db_mOTU_v$MOTUS_VERSION"
readonly MOTUS_URL="https://zenodo.org/record/7778108/files/db_mOTU_v3.1.0.tar.gz"
readonly MOTUS_MD5="f841c36150025af837f7a9a358c9a3c3"

# The archive unpacks to a directory of this name, and it keeps it: mOTUs
# resolves its own files relative to a folder called db_mOTU, so the release
# directory holds it rather than being it.
readonly MOTUS_DB_DIR="db_mOTU"

# HUMAnN 3.9's three databases, which it reads as three separate directories and
# which are fetched together as one release: the ChocoPhlAn pangenomes its
# nucleotide search maps against, the UniRef90 DIAMOND index its translated
# search falls back to, and the mapping files humann_regroup_table needs to put
# gene families on EC and KO.
#
# v201901_v31 is not a stale pin. HUMAnN 3.9 refuses a ChocoPhlAn directory
# holding any file whose name does not carry that string, and the _v31 suffix is
# the bioBakery 3.1 pangenome catalogue rather than the 2019 the number reads as.
# There is no newer release for HUMAnN 3.9, and 3.9 is its newest stable version.
readonly HUMANN_RELEASE="v201901b"
readonly HUMANN_BASE="http://huttenhower.sph.harvard.edu/humann_data"
readonly HUMANN_CHOCOPHLAN_URL="$HUMANN_BASE/chocophlan/full_chocophlan.v201901_v31.tar.gz"
readonly HUMANN_UNIREF_URL="$HUMANN_BASE/uniprot/uniref_annotated/uniref90_annotated_v201901b_full.tar.gz"
readonly HUMANN_MAPPING_URL="$HUMANN_BASE/full_mapping_v201901b.tar.gz"

# The string HUMAnN checks every ChocoPhlAn filename for before it will run
readonly HUMANN_CHOCOPHLAN_VERSION="v201901_v31"

# The three directory names workflows/humann/main.nf is pointed at
readonly HUMANN_CHOCOPHLAN_DIR="chocophlan"
readonly HUMANN_UNIREF_DIR="uniref90"
readonly HUMANN_MAPPING_DIR="utility_mapping"

# EsViritu. The database is versioned apart from the tool: EsViritu 1.0.0 and
# later read v3.1.0 or later. The archive unpacks to a directory named for the
# release, holding the virus genomes, their minimap2 index and the metadata
# table EsViritu takes taxonomy from.
readonly ESVIRITU_RELEASE="v3.2.4"
readonly ESVIRITU_URL="https://zenodo.org/records/17716199/files/esviritu_db_$ESVIRITU_RELEASE.tar.gz"
readonly ESVIRITU_MD5="24d85c1ec3cbffff12e921d2f39c91b2"

# Marker-MAGu. v1.1 is the newest release on Zenodo, and the only one the 0.4.0
# container is worth running: it is the database that paper built. The archive
# unpacks to a directory named for the release, holding one 10.5 GB multi-FASTA
# of marker genes. minimap2 indexes it at run time, in chunks.
readonly MARKERMAGU_RELEASE="v1.1"
readonly MARKERMAGU_URL="https://zenodo.org/records/8342581/files/Marker-MAGu_markerDB_$MARKERMAGU_RELEASE.tar.gz"
readonly MARKERMAGU_MD5="e0947cb1d4a3df09829e98627021e0dd"

# Sewage reads, not a database: five runs of ENA PRJEB87273, the Global Sewage
# Surveillance project's urban virome, for a run that should find viruses. The
# nf-core test reads in db/test-fastq are all one ancient paleofeces sample and
# find none.
#
# One run per country, the largest of each that is still small - 1.4 to 1.8
# million pairs, about 1 GB in all - sequenced at random off a virus-enriched
# extract, so MetaPhlAn and HUMAnN have something to profile too.
readonly SEWAGE_PROJECT="PRJEB87273"
readonly SEWAGE_BASE="https://ftp.sra.ebi.ac.uk/vol1/fastq"

# run|ENA subdirectory|country|collected|md5 of _1|md5 of _2. ENA derives that
# subdirectory from the accession by a rule that changes with its length, so it
# is pinned here rather than worked out. The checksums are ENA's own.
readonly SEWAGE_RUNS=(
    "ERR14789436|036|Slovakia|2017-06-22|cbe17c1edd9b6bb56492571f27bea69f|0f460134cac05ca72f2b3f841708d0c4"
    "ERR14789487|087|Togo|2017-11-27|341f26dddf5685ebc904337ca273427b|001d15c0eeef0cf5b69e1854b8a58741"
    "ERR14789258|058|Austria|2018-11-08|1c312232609a07ada81a72d04165a72f|f1ce355a8f5cdbbbb5f76214b4e8cc43"
    "ERR14788854|054|France|2017-11-20|9fb1cbe47795e64805bedfcce2671964|ff9cbcd8f691c1765534d5149414fdeb"
    "ERR14788949|049|Cameroon|2017-08-18|b6aac2849108909c75603b5f9f0a0e3b|789954a918c15724c8f76681c813c1a3"
)


if [[ $# -ne 1 ]]; then
    fail "Usage: $0 <kraken2|metaphlan|motus|humann|esviritu|markermagu|sewage>"
fi

TOOL="$1"

for tool in curl jq md5sum sha256sum tar; do
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

    # Redirects are followed: Zenodo answers a record URL with a redirect to
    # wherever the file is actually stored, and a checksum is what makes that
    # safe to accept
    log "Downloading ${url##*/}..."
    if ! curl -sSL --fail --retry 3 -o "$dest" "$url"; then
        fail "Could not download $url"
    fi

    local actual_md5
    actual_md5=$(md5sum "$dest" | cut -d" " -f1)
    if [[ "$actual_md5" != "$expected_md5" ]]; then
        fail "Checksum mismatch on ${url##*/}: expected $expected_md5, got $actual_md5."
    fi
}

# Download one file and record what arrived, for a publisher that lists no
# checksum. The md5 goes into the manifest as a description of this copy rather
# than as a check on it; what verifies these downloads is the content checks
# each fetch function makes after extracting.
download_recorded() {
    local url="$1"
    local dest="$2"

    log "Downloading ${url##*/}; the publisher lists no checksum for it..."
    if ! curl -sSL --fail --retry 3 -o "$dest" "$url"; then
        fail "Could not download $url"
    fi

    md5sum "$dest" | cut -d" " -f1
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

# The tip labels of a newick tree, one per line. Records start after "(" or ",",
# so a leaf reads "NAME:length" while a closing branch reads ")support:length"
# and is dropped by trimming from its ")".
tree_tips() {
    awk 'BEGIN { RS = "[(,]" }
        {
            sub(/\).*/, "")
            sub(/:.*/, "")
            gsub(/[ \t\r\n;]/, "")
            if ($0 != "") print
        }' "$1"
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

# The SGB phylogeny for a release, into that release's directory, checked for a
# plausible tip count before it is called done. Sets METAPHLAN_TREE and
# METAPHLAN_TREE_TIPS rather than printing them: record_source has to reach the
# manifest, which a subshell would swallow.
METAPHLAN_TREE=""
METAPHLAN_TREE_TIPS=0

fetch_metaphlan_tree() {
    local out_dir="$1"
    local tree_url="$METAPHLAN_BASE/$METAPHLAN_INDEX.nwk"

    METAPHLAN_TREE="$out_dir/$METAPHLAN_INDEX.nwk"

    download_verified "$tree_url" "$METAPHLAN_TREE" "$METAPHLAN_TREE_MD5"
    record_source "$tree_url" "$METAPHLAN_TREE_MD5" "$(stat -c%s "$METAPHLAN_TREE")"

    METAPHLAN_TREE_TIPS=$(tree_tips "$METAPHLAN_TREE" | sort -u | wc -l)

    if (( METAPHLAN_TREE_TIPS <= 10000 )); then
        rm -f "$METAPHLAN_TREE"
        fail "The MetaPhlAn phylogeny has only $METAPHLAN_TREE_TIPS tips; the download is incomplete."
    fi
}

fetch_metaphlan() {
    local out_dir="$NEXTFLOW_DIR/db/metaphlan/$METAPHLAN_INDEX"
    local manifest="$NEXTFLOW_DIR/db/metaphlan/$METAPHLAN_INDEX.manifest.json"

    # A database installed before the phylogeny was part of this script gets the
    # phylogeny on its own rather than a 26 GB re-download
    if [[ -d "$out_dir" && ! -e "$out_dir/$METAPHLAN_INDEX.nwk" ]]; then
        log "$METAPHLAN_INDEX is already installed; fetching only its phylogeny..."

        fetch_metaphlan_tree "$out_dir"

        log "Fetched the MetaPhlAn phylogeny: $METAPHLAN_TREE ($METAPHLAN_TREE_TIPS tips)."
        log "  Its source and checksum are not in $manifest; that manifest describes"
        log "  the database as it was fetched. Remove the directory and re-run to rebuild both."
        return 0
    fi

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

    # The SGB phylogeny, published beside the database rather than inside it
    fetch_metaphlan_tree "$out_dir"

    write_manifest "$METAPHLAN_INDEX" "$out_dir" "$manifest" \
        "Newest database MetaPhlAn 4.1.1 accepts, which is the version nf-core/taxprofiler 2.0.1 pins. mpa_latest currently names a newer database requiring MetaPhlAn 4.2. $METAPHLAN_INDEX.nwk is the SGB phylogeny for this release, $METAPHLAN_TREE_TIPS tips; its md5 is recorded from the file as fetched, the publisher lists none."

    log "Fetched $METAPHLAN_INDEX:"
    log "  db_path:  $out_dir"
    log "  phylogeny: $METAPHLAN_TREE ($METAPHLAN_TREE_TIPS tips)"
    log "  manifest: $manifest"
}

fetch_motus() {
    local release_dir="$NEXTFLOW_DIR/db/motus/$MOTUS_RELEASE"
    local out_dir="$release_dir/$MOTUS_DB_DIR"
    local manifest="$NEXTFLOW_DIR/db/motus/$MOTUS_RELEASE.manifest.json"

    [[ -e "$release_dir" ]] && fail "$release_dir already exists; remove it to re-fetch."

    mkdir -p "$NEXTFLOW_DIR/db/motus"
    require_free_space "$NEXTFLOW_DIR/db/motus" 20

    local archive="$WORK_DIR/$MOTUS_RELEASE.tar.gz"

    download_verified "$MOTUS_URL" "$archive" "$MOTUS_MD5"
    record_source "$MOTUS_URL" "$MOTUS_MD5" "$(stat -c%s "$archive")"

    log "Extracting $MOTUS_RELEASE.tar.gz..."
    mkdir -p "$release_dir"
    if ! tar -xzf "$archive" -C "$release_dir"; then
        rm -rf "$release_dir"
        fail "Could not extract $MOTUS_RELEASE.tar.gz."
    fi

    rm -f "$archive"

    [[ -d "$out_dir" ]] \
        || fail "The archive did not unpack to a '$MOTUS_DB_DIR' directory; mOTUs will not read it."

    # The version file mOTUs checks itself against. The archive does not carry a
    # usable one - "motus downloadDB" writes it after unpacking, and this is the
    # same file it writes - so without this every profiling call refuses to run.
    log "Writing the version file for mOTUs $MOTUS_VERSION..."
    {
        printf 'motus\t%s\n' "$MOTUS_VERSION"
        printf '#\tdatabase\n'
        printf 'nr\t%s\ncen\t%s\n' "$MOTUS_VERSION" "$MOTUS_VERSION"
        printf '#\tscripts\n'
        printf 'append\t%s\n' "$MOTUS_VERSION"
        printf 'map_genes_to_mOTUs\t%s\n' "$MOTUS_VERSION"
        printf 'map_mOTUs_to_LGs\t%s\n' "$MOTUS_VERSION"
        printf 'runBWA\t%s\n' "$MOTUS_VERSION"
        printf '#\ttaxonomy\n'
        printf 'specI_tax\t%s\n' "$MOTUS_VERSION"
        printf 'mOTULG_tax\t%s\n' "$MOTUS_VERSION"
    } > "$out_dir/db_mOTU_versions" || fail "Could not write the mOTUs version file."

    # Every file mOTUs opens on the profiling path: the marker gene catalogue it
    # maps against, the header it writes its BAM with, and the two tables that
    # turn a mapped gene into a named cluster
    local required
    for required in db_mOTU_DB_NR.fasta db_mOTU_bam_header_NR \
                    db_mOTU_MAP_MGCs_to_mOTUs.tsv db_mOTU_taxonomy_ref-mOTUs.tsv; do
        [[ -r "$out_dir/$required" ]] \
            || fail "The mOTUs database is missing $required; the download is incomplete."
    done

    write_manifest "$MOTUS_RELEASE" "$out_dir" "$manifest" \
        "The database motus downloadDB installs for mOTUs $MOTUS_VERSION, which is the version nf-core/taxprofiler 2.0.1 pins. db_mOTU_versions is written here rather than shipped in the archive, exactly as that command writes it. The v4 catalogues are for a different tool and cannot be read by this one."

    log "Fetched $MOTUS_RELEASE:"
    log "  db_path:  $out_dir"
    log "  manifest: $manifest"
}

# One HUMAnN archive into its own directory under the release, and the archive
# deleted straight after: all three unpack alongside each other and the disk
# only just holds them.
fetch_humann_part() {
    local url="$1" out_dir="$2"
    local archive="$WORK_DIR/${url##*/}"
    local md5

    md5=$(download_recorded "$url" "$archive")
    record_source "$url" "$md5" "$(stat -c%s "$archive")"

    log "Extracting ${url##*/}; this takes a while..."
    mkdir -p "$out_dir"

    if ! tar -xzf "$archive" -C "$out_dir"; then
        rm -f "$archive"
        fail "Could not extract ${url##*/}."
    fi

    rm -f "$archive"
}

fetch_humann() {
    local release_dir="$NEXTFLOW_DIR/db/humann/$HUMANN_RELEASE"
    local manifest="$NEXTFLOW_DIR/db/humann/$HUMANN_RELEASE.manifest.json"
    local chocophlan="$release_dir/$HUMANN_CHOCOPHLAN_DIR"
    local uniref="$release_dir/$HUMANN_UNIREF_DIR"
    local mapping="$release_dir/$HUMANN_MAPPING_DIR"

    [[ -e "$release_dir" ]] && fail "$release_dir already exists; remove it to re-fetch."

    mkdir -p "$NEXTFLOW_DIR/db/humann"
    require_free_space "$NEXTFLOW_DIR/db/humann" 130

    fetch_humann_part "$HUMANN_CHOCOPHLAN_URL" "$chocophlan"
    fetch_humann_part "$HUMANN_UNIREF_URL"     "$uniref"
    fetch_humann_part "$HUMANN_MAPPING_URL"    "$mapping"

    # HUMAnN's own two checks on a ChocoPhlAn directory, made here so a bad
    # download fails at setup rather than on the first sample of a run. The
    # version check is why nothing else may be written into this directory - a
    # README beside the pangenomes is enough to make every HUMAnN call exit.
    local pangenomes=0 path

    for path in "$chocophlan"/*; do
        [[ -e "$path" ]] || fail "The ChocoPhlAn download is empty."

        [[ "${path##*/}" == *"$HUMANN_CHOCOPHLAN_VERSION"* ]] \
            || fail "ChocoPhlAn holds ${path##*/}, which is not $HUMANN_CHOCOPHLAN_VERSION; HUMAnN would refuse it."

        [[ "${path##*/}" == g__*s__* ]] && pangenomes=$((pangenomes + 1))
    done

    (( pangenomes > 0 )) \
        || fail "The ChocoPhlAn download carries no g__*s__* pangenome; it is incomplete."

    compgen -G "$uniref"/*.dmnd > /dev/null \
        || fail "The UniRef90 download carries no DIAMOND index; it is incomplete."

    # Every mapping file the run reads: the two humann_regroup_table is called
    # with, and the UniRef90 names humann_rename_table would want
    local required
    for required in map_level4ec_uniref90.txt.gz map_ko_uniref90.txt.gz \
                    map_uniref90_name.txt.bz2; do
        [[ -r "$mapping/$required" ]] \
            || fail "The utility mapping download is missing $required; it is incomplete."
    done

    write_manifest "$HUMANN_RELEASE" "$release_dir" "$manifest" \
        "The three databases HUMAnN 3.9 reads: ChocoPhlAn $HUMANN_CHOCOPHLAN_VERSION pangenomes ($pangenomes species), the annotated UniRef90 DIAMOND index, and the full utility mapping. The publisher lists no checksums; the md5 recorded for each archive is the copy fetched here. HUMAnN 3.9 refuses a ChocoPhlAn directory holding any file whose name does not carry $HUMANN_CHOCOPHLAN_VERSION, so nothing else may be written into $HUMANN_CHOCOPHLAN_DIR."

    log "Fetched HUMAnN $HUMANN_RELEASE:"
    log "  chocophlan:      $chocophlan ($pangenomes pangenomes)"
    log "  uniref90:        $uniref"
    log "  utility_mapping: $mapping"
    log "  manifest:        $manifest"
}

fetch_esviritu() {
    local out_dir="$NEXTFLOW_DIR/db/esviritu/$ESVIRITU_RELEASE"
    local manifest="$NEXTFLOW_DIR/db/esviritu/$ESVIRITU_RELEASE.manifest.json"

    [[ -e "$out_dir" ]] && fail "$out_dir already exists; remove it to re-fetch."

    mkdir -p "$NEXTFLOW_DIR/db/esviritu"
    require_free_space "$NEXTFLOW_DIR/db/esviritu" 2

    local archive="$WORK_DIR/${ESVIRITU_URL##*/}"

    download_verified "$ESVIRITU_URL" "$archive" "$ESVIRITU_MD5"
    record_source "$ESVIRITU_URL" "$ESVIRITU_MD5" "$(stat -c%s "$archive")"

    log "Extracting ${ESVIRITU_URL##*/}..."
    if ! tar -xzf "$archive" -C "$NEXTFLOW_DIR/db/esviritu"; then
        rm -rf "$out_dir"
        fail "Could not extract ${ESVIRITU_URL##*/}."
    fi

    rm -f "$archive"

    [[ -d "$out_dir" ]] \
        || fail "The archive did not unpack to a '$ESVIRITU_RELEASE' directory."

    # Every file EsViritu opens: the genomes, the index it maps short reads
    # against, and the metadata it names each genome by
    local required
    for required in virus_pathogen_database.fna virus_pathogen_database.mmi \
                    virus_pathogen_database.all_metadata.tsv; do
        [[ -s "$out_dir/$required" ]] \
            || fail "The EsViritu database is missing $required; the download is incomplete."
    done

    local genomes
    genomes=$(grep -c '^>' "$out_dir/virus_pathogen_database.fna")

    write_manifest "$ESVIRITU_RELEASE" "$out_dir" "$manifest" \
        "The EsViritu virus pathogen database $ESVIRITU_RELEASE ($genomes sequences), which EsViritu 1.0.0 and later read. The md5 is the one the EsViritu README and the Zenodo record list."

    log "Fetched EsViritu $ESVIRITU_RELEASE:"
    log "  db_path:  $out_dir ($genomes sequences)"
    log "  manifest: $manifest"
}

fetch_markermagu() {
    local out_dir="$NEXTFLOW_DIR/db/markermagu/$MARKERMAGU_RELEASE"
    local manifest="$NEXTFLOW_DIR/db/markermagu/$MARKERMAGU_RELEASE.manifest.json"

    [[ -e "$out_dir" ]] && fail "$out_dir already exists; remove it to re-fetch."

    mkdir -p "$NEXTFLOW_DIR/db/markermagu"
    require_free_space "$NEXTFLOW_DIR/db/markermagu" 16

    local archive="$WORK_DIR/${MARKERMAGU_URL##*/}"

    download_verified "$MARKERMAGU_URL" "$archive" "$MARKERMAGU_MD5"
    record_source "$MARKERMAGU_URL" "$MARKERMAGU_MD5" "$(stat -c%s "$archive")"

    log "Extracting ${MARKERMAGU_URL##*/}..."
    if ! tar -xzf "$archive" -C "$NEXTFLOW_DIR/db/markermagu"; then
        rm -rf "$out_dir"
        fail "Could not extract ${MARKERMAGU_URL##*/}."
    fi

    rm -f "$archive"

    [[ -d "$out_dir" ]] \
        || fail "The archive did not unpack to a '$MARKERMAGU_RELEASE' directory."

    # The one file Marker-MAGu opens, and the only one the archive holds
    [[ -s "$out_dir/Marker-MAGu_markerDB.fna" ]] \
        || fail "The Marker-MAGu database is missing Marker-MAGu_markerDB.fna; the download is incomplete."

    local genes
    genes=$(grep -c '^>' "$out_dir/Marker-MAGu_markerDB.fna")

    write_manifest "$MARKERMAGU_RELEASE" "$out_dir" "$manifest" \
        "The Marker-MAGu marker gene database $MARKERMAGU_RELEASE ($genes marker genes): MetaPhlAn 4's vOct22 markers with the Trove of Gut Virus Genomes v1.1 phage markers added. The md5 is the one the Marker-MAGu README and the Zenodo record list."

    log "Fetched Marker-MAGu $MARKERMAGU_RELEASE:"
    log "  db_path:  $out_dir ($genes marker genes)"
    log "  manifest: $manifest"
}

# The sewage reads, and a samplesheet naming them. Downloads land beside the
# release rather than in it, so a run that stops partway leaves nothing that
# reads as a complete set.
fetch_sewage() {
    local out_dir="$NEXTFLOW_DIR/db/test-fastq/$SEWAGE_PROJECT"
    local partial="$out_dir.partial"
    local manifest="$NEXTFLOW_DIR/db/test-fastq/$SEWAGE_PROJECT.manifest.json"

    [[ -e "$out_dir" ]] && fail "$out_dir already exists; remove it to re-fetch."

    mkdir -p "$NEXTFLOW_DIR/db/test-fastq"
    require_free_space "$NEXTFLOW_DIR/db/test-fastq" 3

    rm -rf "$partial"
    mkdir -p "$partial"

    local entry run dir country collected md5 mate url file
    local -a md5s=()

    # A samplesheet in the columns workflows/biobakery reads, each sample named
    # after the city's country, since no two of these runs share one
    printf 'sample,run_accession,instrument_platform,fastq_1,fastq_2\n' > "$partial/samplesheet.csv"

    for entry in "${SEWAGE_RUNS[@]}"; do
        IFS='|' read -r run dir country collected md5s[1] md5s[2] <<< "$entry"

        log "Fetching $run, $country $collected..."

        for mate in 1 2; do
            url="$SEWAGE_BASE/${run:0:6}/$dir/$run/${run}_$mate.fastq.gz"
            file="$partial/${run}_$mate.fastq.gz"
            md5="${md5s[$mate]}"

            download_verified "$url" "$file" "$md5"
            record_source "$url" "$md5" "$(stat -c%s "$file")"
        done

        printf '%s,%s,ILLUMINA,%s,%s\n' "$country" "$run" \
            "$out_dir/${run}_1.fastq.gz" "$out_dir/${run}_2.fastq.gz" >> "$partial/samplesheet.csv"
    done

    mv "$partial" "$out_dir" || fail "Could not move the reads into $out_dir."

    write_manifest "$SEWAGE_PROJECT" "$out_dir" "$manifest" \
        "Five paired-end runs of ENA $SEWAGE_PROJECT, the Global Sewage Surveillance project's urban virome, one per country, for a positive-control run: untreated sewage sequenced at random off a virus-enriched extract. Not a database; nothing in the repository reads them. The md5 of each file is ENA's own. samplesheet.csv names them in the columns workflows/biobakery reads."

    log "Fetched $SEWAGE_PROJECT:"
    log "  reads:       $out_dir (${#SEWAGE_RUNS[@]} runs, $(du -sh "$out_dir" | cut -f1))"
    log "  samplesheet: $out_dir/samplesheet.csv"
    log "  manifest:    $manifest"
}

case "$TOOL" in
    kraken2)    fetch_kraken2 ;;
    metaphlan)  fetch_metaphlan ;;
    motus)      fetch_motus ;;
    humann)     fetch_humann ;;
    esviritu)   fetch_esviritu ;;
    markermagu) fetch_markermagu ;;
    sewage)     fetch_sewage ;;
    *)          fail "Unknown database '$TOOL'. Use kraken2, metaphlan, motus, humann, esviritu, markermagu or sewage." ;;
esac
