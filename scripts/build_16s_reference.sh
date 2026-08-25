#!/bin/bash
#
# build_16s_reference.sh - Build the landmark 16S reference the region detector aligns to.
#
# Author: Daniel Smith
# Date:   August 25th, 2026
#
# One-time cluster setup for ampliseq_detect_region.sh, run once rather than as
# part of any pipeline. Pulls the 16S rRNA gene out of a handful of RefSeq
# genomes, concatenates them into one small FASTA, and records where every base
# of every landmark sits in E. coli numbering.
#
# Reads are aligned to these landmarks rather than to a taxonomy database because
# the detector needs a coordinate, and a coordinate needs a reference whose
# numbering is fixed. E. coli K-12 MG1655 is that reference - variable regions
# and primer names are quoted in its numbering everywhere - so it is always
# included, and every other landmark is mapped onto it.
#
# The landmarks span the phyla a 16S survey returns, because usearch_global has
# to find a hit for a read before that read can vote on the region. One genome
# per phylum is enough: each carries the same coordinates, so any hit will do.
#
# Writes four things into db/16s/:
#
#   landmarks.fasta       the 16S genes, one per genome, named by accession
#   landmarks.sam         each landmark aligned to the E. coli landmark
#   ecoli_positions.tsv   landmark, position in it, and the E. coli position it
#                         is homologous to - one row per base, read from the CIGARs
#   manifest.json         what went in, from where, and how
#
# Usage:     build_16s_reference.sh [accession...]
#            with no arguments, builds from DEFAULT_ACCESSIONS below
#
#            sbatch --cpus-per-task=4 --mem=8G --time=02:00:00 \
#                scripts/build_16s_reference.sh
#
# Requires:  curl, jq, md5sum, apptainer
# Env:       NEXTFLOW_DIR and the log/warn/fail helpers, sourced from .env;
#            VSEARCH_CONTAINER, optionally, to override the pinned image
#
# Existing output is left alone; remove db/16s/ to rebuild.

set -euo pipefail

source /data/prod/nextflow/.env

# The numbering reference. Its 16S is 1542 bp and carries the 515F site at
# position 515; both are checked below, since a landmark whose coordinates have
# shifted would misidentify every region.
readonly ECOLI_ACCESSION="GCF_000005845.2"
readonly ECOLI_16S_LENGTH=1542
readonly ECOLI_515F="GTG[CT]CAGC[AC]GCCGCGGTAA"
readonly ECOLI_515F_POSITION=515

# One genome per phylum a 16S survey is likely to return, plus an archaeon
readonly DEFAULT_ACCESSIONS=(
    "$ECOLI_ACCESSION"  # Escherichia coli K-12 MG1655       Pseudomonadota
    GCF_000006765.1     # Pseudomonas aeruginosa PAO1        Pseudomonadota
    GCF_000009045.1     # Bacillus subtilis 168              Bacillota
    GCF_000013425.1     # Staphylococcus aureus NCTC 8325    Bacillota
    GCF_000025985.1     # Bacteroides fragilis NCTC 9343     Bacteroidota
    GCF_000007525.1     # Bifidobacterium longum NCC2705     Actinomycetota
    GCF_000020225.1     # Akkermansia muciniphila BAA-835    Verrucomicrobiota
    GCF_000016525.1     # Methanobrevibacter smithii 35061   Euryarchaeota
)

readonly VSEARCH_CONTAINER="${VSEARCH_CONTAINER:-docker://quay.io/biocontainers/vsearch:2.31.0--hd2be7a0_0}"

readonly NCBI_GENOMES="https://ftp.ncbi.nlm.nih.gov/genomes/all"

readonly OUT_DIR="$NEXTFLOW_DIR/db/16s"
readonly LANDMARKS="$OUT_DIR/landmarks.fasta"
readonly ALIGNMENT="$OUT_DIR/landmarks.sam"
readonly POSITIONS="$OUT_DIR/ecoli_positions.tsv"
readonly MANIFEST="$OUT_DIR/manifest.json"

if [[ $# -gt 0 ]]; then
    ACCESSIONS=("$@")

    # The map is built against it, so it belongs in the set whatever was asked for
    if [[ " ${ACCESSIONS[*]} " != *" $ECOLI_ACCESSION "* ]]; then
        ACCESSIONS=("$ECOLI_ACCESSION" "${ACCESSIONS[@]}")
    fi
else
    ACCESSIONS=("${DEFAULT_ACCESSIONS[@]}")
fi

for accession in "${ACCESSIONS[@]}"; do
    if [[ ! "$accession" =~ ^GCF_[0-9]{9}\.[0-9]+$ ]]; then
        fail "Not an NCBI RefSeq assembly accession: $accession"
    fi
done

for tool in curl jq md5sum apptainer; do
    command -v "$tool" > /dev/null || fail "Required tool '$tool' is not installed."
done

if [[ -e "$LANDMARKS" ]]; then
    fail "$OUT_DIR already holds a landmark set; remove the directory to rebuild."
fi

log "Checking $VSEARCH_CONTAINER..."
apptainer exec "$VSEARCH_CONTAINER" vsearch --version > /dev/null 2>&1 \
    || fail "Could not pull the container '$VSEARCH_CONTAINER'."

mkdir -p "$OUT_DIR"

WORK_DIR=$(mktemp -d) || fail "Could not create a temporary working directory."
trap 'rm -rf "$WORK_DIR"' EXIT

# The FTP directory for an accession, e.g. GCF_000005845.2 resolves to
# .../GCF/000/005/845/GCF_000005845.2_ASM584v2. Read from the listing because the
# trailing assembly name is not derivable from the accession.
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

# Append the longest [product=16S ribosomal RNA] record of an
# _rna_from_genomic.fna to the landmark FASTA, and put that gene's own header and
# length in info_file for the manifest. Longest rather than first, so a copy
# truncated at a contig edge cannot become the landmark.
extract_16s() {
    local rna_file="$1"
    local id="$2"
    local info_file="$3"

    gunzip -c "$rna_file" | awk -v id="$id" -v info="$info_file" '
        /^>/ {
            keep = ($0 ~ /\[product=16S ribosomal RNA\]/)
            if (keep) { n++; header[n] = substr($0, 2); seq[n] = "" }
            next
        }
        keep { seq[n] = seq[n] $0 }
        END {
            best = 0
            for (i = 1; i <= n; i++) {
                if (length(seq[i]) > length(seq[best])) best = i
            }
            if (best == 0) exit 1

            printf ">%s\n%s\n", id, toupper(seq[best])
            printf "%s\t%d\n", header[best], length(seq[best]) > info
        }'
}

SOURCES_JSON="[]"

# 1. Download each genome's RNA genes and take its 16S.
log "Building a 16S landmark set from ${#ACCESSIONS[@]} genomes..."

for accession in "${ACCESSIONS[@]}"; do
    log "Resolving $accession..."

    if ! ASSEMBLY_URL=$(resolve_assembly_dir "$accession"); then
        fail "Could not find assembly $accession on NCBI."
    fi

    ASSEMBLY_NAME=${ASSEMBLY_URL##*/}
    RNA_NAME="${ASSEMBLY_NAME}_rna_from_genomic.fna.gz"
    RNA_GZ="$WORK_DIR/$RNA_NAME"

    log "Downloading $ASSEMBLY_NAME..."
    if ! curl -sS --fail --retry 3 -o "$RNA_GZ" "$ASSEMBLY_URL/$RNA_NAME"; then
        fail "Could not download $RNA_NAME from NCBI; $accession may be unannotated."
    fi

    if ! CHECKSUMS=$(curl -sS --fail --retry 3 "$ASSEMBLY_URL/md5checksums.txt"); then
        fail "Could not download md5checksums.txt for $accession."
    fi

    EXPECTED_MD5=$(printf '%s\n' "$CHECKSUMS" | awk -v f="./$RNA_NAME" '$2 == f {print $1}')
    [[ -n "$EXPECTED_MD5" ]] || fail "NCBI lists no checksum for $RNA_NAME."

    ACTUAL_MD5=$(md5sum "$RNA_GZ" | cut -d" " -f1)
    if [[ "$ACTUAL_MD5" != "$EXPECTED_MD5" ]]; then
        fail "Checksum mismatch on $RNA_NAME: expected $EXPECTED_MD5, got $ACTUAL_MD5."
    fi

    if ! extract_16s "$RNA_GZ" "$accession" "$WORK_DIR/gene_info.tsv" \
            >> "$WORK_DIR/landmarks.fasta"; then
        fail "No 16S ribosomal RNA gene is annotated in $accession."
    fi

    IFS=$'\t' read -r GENE_HEADER GENE_LENGTH < "$WORK_DIR/gene_info.tsv"

    log "  $accession: $GENE_LENGTH bp"

    SOURCES_JSON=$(printf '%s' "$SOURCES_JSON" | jq \
        --arg accession "$accession" \
        --arg assembly "$ASSEMBLY_NAME" \
        --arg url "$ASSEMBLY_URL/$RNA_NAME" \
        --arg md5 "$ACTUAL_MD5" \
        --arg gene "$GENE_HEADER" \
        --argjson length "$GENE_LENGTH" \
        '. + [{accession: $accession, assembly: $assembly, url: $url, md5: $md5,
               gene: $gene, length: $length}]')
done

# 2. Check the numbering before anything is built on top of it.
awk -v want="$ECOLI_ACCESSION" '
    /^>/ { keep = (substr($0, 2) == want); next }
    keep { printf "%s", $0 }
    END { print "" }' "$WORK_DIR/landmarks.fasta" > "$WORK_DIR/ecoli.txt"

read -r ECOLI_SEQUENCE < "$WORK_DIR/ecoli.txt"

if [[ ${#ECOLI_SEQUENCE} -ne $ECOLI_16S_LENGTH ]]; then
    REASON="The $ECOLI_ACCESSION 16S gene is ${#ECOLI_SEQUENCE} bp, not the expected $ECOLI_16S_LENGTH."
    REASON+=$'\n'"E. coli numbering can no longer be assumed; nothing was built."
    fail "$REASON"
fi

FOUND_515F=$(awk -v s="$ECOLI_SEQUENCE" -v p="$ECOLI_515F" 'BEGIN { print match(s, p) }')

if [[ "$FOUND_515F" -ne $ECOLI_515F_POSITION ]]; then
    REASON="The 515F site is at position $FOUND_515F of the $ECOLI_ACCESSION 16S gene,"
    REASON+=" not $ECOLI_515F_POSITION."
    REASON+=$'\n'"E. coli numbering can no longer be assumed; nothing was built."
    fail "$REASON"
fi

printf '>%s\n%s\n' "$ECOLI_ACCESSION" "$ECOLI_SEQUENCE" > "$WORK_DIR/ecoli.fasta"

# 3. Align every landmark to the E. coli one. --strand plus, because
#    _rna_from_genomic gives each gene in its transcribed orientation already.
VSEARCH_COMMAND="vsearch --usearch_global $WORK_DIR/landmarks.fasta"
VSEARCH_COMMAND+=" --db $WORK_DIR/ecoli.fasta --id 0.5 --strand plus"
VSEARCH_COMMAND+=" --maxaccepts 1 --maxrejects 0 --samout $WORK_DIR/landmarks.sam --quiet"

log "Aligning the landmarks to $ECOLI_ACCESSION..."
if ! apptainer exec -B /data "$VSEARCH_CONTAINER" $VSEARCH_COMMAND; then
    fail "vsearch could not align the landmarks to $ECOLI_ACCESSION."
fi

# 4. Walk each CIGAR for one row per base. M/=/X consume both sequences, I and S
#    only the landmark, D and N only E. coli. The flag bits are tested
#    arithmetically rather than with and(), which is a gawk extension.
awk -v OFS='\t' '
    /^@/ { next }
    {
        landmark = $1; flag = $2; pos = $4; cigar = $6

        if (int(flag / 4) % 2) next
        if (int(flag / 16) % 2) {
            printf "%s aligned on the minus strand.\n", landmark > "/dev/stderr"
            exit 1
        }

        qpos = 1
        tpos = pos
        while (match(cigar, /^[0-9]+[MIDNSHP=X]/)) {
            block = substr(cigar, RSTART, RLENGTH)
            cigar = substr(cigar, RSTART + RLENGTH)
            len = substr(block, 1, length(block) - 1) + 0
            op  = substr(block, length(block))

            if (op == "M" || op == "=" || op == "X") {
                for (i = 0; i < len; i++) print landmark, qpos + i, tpos + i
                qpos += len
                tpos += len
            } else if (op == "I" || op == "S") {
                qpos += len
            } else if (op == "D" || op == "N") {
                tpos += len
            }
        }
    }
' "$WORK_DIR/landmarks.sam" > "$WORK_DIR/ecoli_positions.tsv" \
    || fail "Could not map the landmarks onto E. coli numbering."

# A landmark with no rows would silently stop contributing reads to a call
cut -f1 "$WORK_DIR/ecoli_positions.tsv" | sort -u > "$WORK_DIR/aligned.txt"

for accession in "${ACCESSIONS[@]}"; do
    grep -qx -- "$accession" "$WORK_DIR/aligned.txt" \
        || fail "$accession did not align to $ECOLI_ACCESSION; it does not belong in the landmark set."
done

mv "$WORK_DIR/landmarks.fasta" "$LANDMARKS"
mv "$WORK_DIR/landmarks.sam" "$ALIGNMENT"
mv "$WORK_DIR/ecoli_positions.tsv" "$POSITIONS"

# 5. Record what was built.
VSEARCH_VERSION=$(apptainer exec "$VSEARCH_CONTAINER" vsearch --version 2>&1 | head -1) \
    || VSEARCH_VERSION="unknown"

jq -n \
    --arg landmarks "$LANDMARKS" \
    --arg landmarks_md5 "$(md5sum "$LANDMARKS" | cut -d" " -f1)" \
    --arg alignment "$ALIGNMENT" \
    --arg positions "$POSITIONS" \
    --arg numbering "$ECOLI_ACCESSION" \
    --argjson numbering_length "$ECOLI_16S_LENGTH" \
    --arg container "$VSEARCH_CONTAINER" \
    --arg tool_version "$VSEARCH_VERSION" \
    --arg command "$VSEARCH_COMMAND" \
    --arg built_utc "$(date -u "+%Y-%m-%dT%H:%M:%SZ")" \
    --arg built_by "$(whoami)" \
    --argjson sources "$SOURCES_JSON" \
    '{landmarks: $landmarks, landmarks_md5: $landmarks_md5, alignment: $alignment,
      positions: $positions, numbering: {accession: $numbering, length: $numbering_length},
      sources: $sources, built_utc: $built_utc, built_by: $built_by,
      vsearch: {container: $container, tool_version: $tool_version, command: $command}}' \
    > "$MANIFEST"

log "Built the 16S landmark set:"
log "  landmarks: $LANDMARKS ($(grep -c '^>' "$LANDMARKS") genomes)"
log "  positions: $POSITIONS ($(wc -l < "$POSITIONS") rows)"
log "  manifest:  $MANIFEST"
