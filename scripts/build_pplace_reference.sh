#!/bin/bash
#
# build_pplace_reference.sh - Build the reference tree ASVs are grafted onto.
#
# Author: Daniel Smith
# Date:   September 1st, 2026
#
# One-time cluster setup for the ampliseq pipeline, run once rather than as part
# of any pipeline. Downloads SBDI's GTDB bacterial 16S reference - one 16S
# sequence per GTDB species representative, aligned, plus the maximum-likelihood
# tree built from that alignment - and checks the two against each other before
# either is put in place.
#
# EPA-NG aligns a run's ASVs to this alignment and grafts them onto this tree,
# and that grafted tree is what UniFrac and Faith's PD are computed over. Its
# branch lengths and its root come from the reference rather than from the run,
# so two runs produce the same tree with different tips added.
#
# ampliseq also carries these files, under --run_pplace, but that route feeds
# them to taxonomy assignment and never puts the tree into the diversity
# calculation. They are fetched here so --pplace_tree and --pplace_aln can name
# them as local paths, which is the route that does.
#
# The two figshare file ids below are the ones ampliseq pins for 'sbdi-gtdb' at
# the revision AMPLISEQ_01.sh runs. Bumping AMPLISEQ_REVISION means checking that
# conf/ref_databases.config still names these.
#
# Writes into db/pplace/:
#
#   bac16s.alnfna    the reference alignment, one row per species representative
#   bac16s.newick    the tree built from it, one tip for each of those
#   manifest.json    what went in, from where, and how
#
# Usage:     build_pplace_reference.sh
#
#            sbatch --cpus-per-task=2 --mem=8G --time=01:00:00 \
#                scripts/build_pplace_reference.sh
#
# Requires:  curl, jq, md5sum, awk, sort, comm
# Env:       NEXTFLOW_DIR and the log/warn/fail helpers, sourced from .env
#
# Existing output is left alone; remove db/pplace/ to rebuild.

set -euo pipefail

source /data/prod/nextflow/.env

readonly FIGSHARE="https://ndownloader.figshare.com/files"
readonly RELEASE="sbdi-gtdb-sativa R11-RS232-1 bac120"
readonly ALIGNMENT_FILE_ID=64711224
readonly TREE_FILE_ID=64711197

# The substitution model the reference tree was fitted under, which EPA-NG has to
# be given to place onto it. AMPLISEQ_01.sh passes the same string as
# --pplace_model; it is recorded in the manifest so the two can be compared.
readonly TREE_MODEL="GTR+F+I+G4"

# A reference smaller than this is a truncated download rather than a smaller
# release: R11-RS232-1 carries 54322 representatives.
readonly MIN_REFERENCE_TIPS=10000

readonly OUT_DIR="$NEXTFLOW_DIR/db/pplace"
readonly ALIGNMENT="$OUT_DIR/bac16s.alnfna"
readonly TREE="$OUT_DIR/bac16s.newick"
readonly MANIFEST="$OUT_DIR/manifest.json"

for tool in curl jq md5sum awk sort comm; do
    command -v "$tool" > /dev/null || fail "Required tool '$tool' is not installed."
done

if [[ -e "$ALIGNMENT" ]]; then
    fail "$OUT_DIR already holds a placement reference; remove the directory to rebuild."
fi

WORK_DIR=$(mktemp -d) || fail "Could not create a temporary working directory."
trap 'rm -rf "$WORK_DIR"' EXIT

# Download one figshare file, reporting the name figshare says it is sending so
# the manifest names the release rather than the id.
fetch() {
    local file_id="$1"
    local destination="$2"
    local headers="$WORK_DIR/headers.txt"

    curl -sS --fail --retry 3 -L -D "$headers" -o "$destination" "$FIGSHARE/$file_id" \
        || fail "Could not download figshare file $file_id."

    [[ -s "$destination" ]] || fail "figshare file $file_id came back empty."

    local name
    name=$(awk -F'filename=' 'tolower($0) ~ /content-disposition/ { gsub(/[\r"]/, "", $2); print $2 }' \
        "$headers" | tail -1)

    printf '%s' "${name:-file-$file_id}"
}

# The tip labels of a newick tree, one per line. Records start after "(" or ",",
# so a leaf reads "NAME:length" while a closing branch reads ")support:length"
# and is dropped by trimming from its ")".
tree_tips() {
    awk 'BEGIN { RS = "[(,]" }
        {
            sub(/\).*/, "")
            sub(/:.*/, "")
            gsub(/^[ \t'"'"']+|[ \t'"'"'\r\n]+$/, "")
            if ($0 != "") print
        }' "$1"
}

log "Downloading the $RELEASE placement reference..."

ALIGNMENT_NAME=$(fetch "$ALIGNMENT_FILE_ID" "$WORK_DIR/bac16s.alnfna")
log "  $ALIGNMENT_NAME"

TREE_NAME=$(fetch "$TREE_FILE_ID" "$WORK_DIR/bac16s.newick")
log "  $TREE_NAME"

# 1. The alignment has to be aligned: EPA-NG reads it as a matrix, and one row of
#    a different width is a truncated or concatenated download rather than a gap.
log "Checking the alignment..."

read -r SEQUENCE_COUNT ALIGNMENT_WIDTH RAGGED_ID < <(awk '
    /^>/ {
        if (n > 0 && length(seq) != width) { ragged = id; exit }
        n++
        id = substr($1, 2)
        if (n == 1) width = 0
        seq = ""
        next
    }
    {
        gsub(/[\r\n]/, "")
        seq = seq $0
        if (n == 1) width = length(seq)
    }
    END {
        if (!ragged && n > 0 && length(seq) != width) ragged = id
        printf "%d %d %s\n", n, width, (ragged ? ragged : "-")
    }' "$WORK_DIR/bac16s.alnfna")

if [[ "$RAGGED_ID" != "-" ]]; then
    REASON="The reference alignment is ragged: $RAGGED_ID is not $ALIGNMENT_WIDTH columns wide."
    REASON+=$'\n'"The download is incomplete; nothing was built."
    fail "$REASON"
fi

if [[ "$SEQUENCE_COUNT" -lt "$MIN_REFERENCE_TIPS" ]]; then
    REASON="The reference alignment holds $SEQUENCE_COUNT sequences, fewer than the"
    REASON+=" $MIN_REFERENCE_TIPS a GTDB release carries. The download is incomplete;"
    REASON+=" nothing was built."
    fail "$REASON"
fi

# 2. Every sequence in the alignment needs a tip of the same name in the tree, and
#    the other way round. EPA-NG refuses the pair otherwise, and it refuses after
#    the run has already paid for cutadapt and DADA2.
log "Checking the tree against it..."

tree_tips "$WORK_DIR/bac16s.newick" | sort > "$WORK_DIR/tips.txt"
awk '/^>/ { print substr($1, 2) }' "$WORK_DIR/bac16s.alnfna" | sort > "$WORK_DIR/sequences.txt"

TIP_COUNT=$(wc -l < "$WORK_DIR/tips.txt")

TREE_ONLY=$(comm -23 "$WORK_DIR/tips.txt" "$WORK_DIR/sequences.txt" | head -3)
ALIGNMENT_ONLY=$(comm -13 "$WORK_DIR/tips.txt" "$WORK_DIR/sequences.txt" | head -3)

if [[ -n "$TREE_ONLY" || -n "$ALIGNMENT_ONLY" ]]; then
    REASON="The reference tree and alignment do not describe the same sequences:"
    REASON+=" $TIP_COUNT tips against $SEQUENCE_COUNT sequences."

    [[ -n "$TREE_ONLY" ]] && REASON+=$'\n'"In the tree only: $(printf '%s' "$TREE_ONLY" | tr '\n' ' ')"
    [[ -n "$ALIGNMENT_ONLY" ]] && REASON+=$'\n'"In the alignment only: $(printf '%s' "$ALIGNMENT_ONLY" | tr '\n' ' ')"

    REASON+=$'\n'"Nothing was built."
    fail "$REASON"
fi

mkdir -p "$OUT_DIR"

mv "$WORK_DIR/bac16s.alnfna" "$ALIGNMENT"
mv "$WORK_DIR/bac16s.newick" "$TREE"

# 3. Record what was built.
jq -n \
    --arg release "$RELEASE" \
    --arg alignment "$ALIGNMENT" \
    --arg alignment_name "$ALIGNMENT_NAME" \
    --arg alignment_url "$FIGSHARE/$ALIGNMENT_FILE_ID" \
    --arg alignment_md5 "$(md5sum "$ALIGNMENT" | cut -d" " -f1)" \
    --arg tree "$TREE" \
    --arg tree_name "$TREE_NAME" \
    --arg tree_url "$FIGSHARE/$TREE_FILE_ID" \
    --arg tree_md5 "$(md5sum "$TREE" | cut -d" " -f1)" \
    --arg model "$TREE_MODEL" \
    --argjson sequences "$SEQUENCE_COUNT" \
    --argjson width "$ALIGNMENT_WIDTH" \
    --arg built_utc "$(date -u "+%Y-%m-%dT%H:%M:%SZ")" \
    --arg built_by "$(whoami)" \
    '{release: $release, model: $model, sequences: $sequences, alignment_width: $width,
      alignment: {path: $alignment, name: $alignment_name, url: $alignment_url, md5: $alignment_md5},
      tree: {path: $tree, name: $tree_name, url: $tree_url, md5: $tree_md5},
      built_utc: $built_utc, built_by: $built_by}' \
    > "$MANIFEST"

log "Built the placement reference:"
log "  alignment: $ALIGNMENT ($SEQUENCE_COUNT sequences, $ALIGNMENT_WIDTH columns)"
log "  tree:      $TREE ($TIP_COUNT tips, $TREE_MODEL)"
log "  manifest:  $MANIFEST"
