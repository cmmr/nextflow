#!/bin/bash
#
# ampliseq_prune_tree.sh - Cut the reference out of the grafted phylogeny.
#
# Author: Daniel Smith
# Date:   September 2nd, 2026
#
# EPA-NG places this run's ASVs onto the GTDB reference tree, and gappa writes
# the whole thing back out: 54322 reference tips with the run's few dozen ASVs
# among them. That tree is the placement's record, but it is not what anything
# reads. Nothing that computes UniFrac or Faith's PD wants 54322 tips it has no
# counts for, and no reader can open it.
#
# So the reference is cut back out, leaving a tree whose tips are the ASV ids and
# nothing else - the same ids as the ASV table, the sequences and the taxonomy.
# gotree adds the branch lengths of the two branches it merges at each removal,
# so the distance between any two ASVs is the distance the placement gave them,
# and the reference's root is kept.
#
# Which tips are reference is not guessed from their names: the reference tree
# build_pplace_reference.sh installed is passed to gotree, and the tips the two
# trees have in common are the ones that go.
#
# Writes results/pplace/asv_tree.newick. Does nothing when the run produced no
# grafted tree, which is every run that placement was turned off for.
#
# Usage:     ampliseq_prune_tree.sh [results_dir]
# Called by: wrike_job.sh, as a POST_PROCESS_CMDS entry of the ampliseq pipeline,
#            before ampliseq_upload.sh prunes and indexes the results
# Requires:  awk, apptainer
# Reads:     db/pplace/bac16s.newick, from build_pplace_reference.sh
# Env:       NEXTFLOW_DIR and the log/warn/fail helpers, sourced from .env;
#            GOTREE_CONTAINER, optionally, to override the pinned image
# Outputs:   results/pplace/asv_tree.newick

set -euo pipefail

source /data/prod/nextflow/.env

readonly GOTREE_CONTAINER="${GOTREE_CONTAINER:-docker://quay.io/biocontainers/gotree:0.5.2--he881be0_0}"

readonly REFERENCE_TREE="$NEXTFLOW_DIR/db/pplace/bac16s.newick"

RESULTS_DIR="${1:-results}"
RESULTS_DIR="${RESULTS_DIR%/}"
readonly RESULTS_DIR

readonly PPLACE_DIR="$RESULTS_DIR/pplace"
readonly ASV_TREE="$PPLACE_DIR/asv_tree.newick"

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

# gappa names its output after both the prefix it was given and the jplace it
# read, so the grafted tree is matched rather than named. A rerun would otherwise
# match the tree this script wrote last time.
shopt -s nullglob
GRAFTED_TREES=()
for candidate in "$PPLACE_DIR"/*.newick; do
    [[ "$candidate" == "$ASV_TREE" ]] && continue
    GRAFTED_TREES+=("$candidate")
done
shopt -u nullglob

# Placement is off, or this is a rerun of a job that predates it
if [[ ${#GRAFTED_TREES[@]} -eq 0 ]]; then
    log "No grafted phylogeny in $PPLACE_DIR; nothing to prune."
    exit 0
fi

if [[ ${#GRAFTED_TREES[@]} -gt 1 ]]; then
    warn "More than one tree in $PPLACE_DIR; pruning ${GRAFTED_TREES[0]}."
fi

readonly GRAFTED_TREE="${GRAFTED_TREES[0]}"

[[ -r "$REFERENCE_TREE" ]] || fail "The placement reference is missing from the server ($REFERENCE_TREE; run scripts/build_pplace_reference.sh)."

command -v apptainer > /dev/null || fail "Required tool 'apptainer' is not installed."

GRAFTED_TIPS=$(tree_tips "$GRAFTED_TREE" | wc -l)
REFERENCE_TIPS=$(tree_tips "$REFERENCE_TREE" | wc -l)
EXPECTED_TIPS=$((GRAFTED_TIPS - REFERENCE_TIPS))

if [[ "$EXPECTED_TIPS" -le 0 ]]; then
    REASON="The grafted phylogeny has $GRAFTED_TIPS tips and the reference $REFERENCE_TIPS,"
    REASON+=" so no ASV was placed on it. The tree is left as it is."
    warn "$REASON"
    exit 0
fi

log "Pruning $REFERENCE_TIPS reference tips out of $GRAFTED_TIPS, leaving $EXPECTED_TIPS ASVs..."

# -c names the tree to compare against and -r removes what the two have in
# common, so what is left is the tips the grafted tree does not share with the
# reference: this run's ASVs.
GRAFTED_ABS=$(readlink -f "$GRAFTED_TREE")
OUTPUT_ABS=$(readlink -f "$PPLACE_DIR")/asv_tree.newick

if ! apptainer exec -B /data "$GOTREE_CONTAINER" \
        gotree prune -i "$GRAFTED_ABS" -c "$REFERENCE_TREE" -r -o "$OUTPUT_ABS.tmp"; then
    fail "The grafted phylogeny could not be pruned."
fi

PRUNED_TIPS=$(tree_tips "$OUTPUT_ABS.tmp" | wc -l)

if [[ "$PRUNED_TIPS" -ne "$EXPECTED_TIPS" ]]; then
    rm -f "$OUTPUT_ABS.tmp"
    REASON="Pruning the grafted phylogeny left $PRUNED_TIPS tips, not the $EXPECTED_TIPS"
    REASON+=" ASVs it was placed with. The tree is left as it is."
    fail "$REASON"
fi

mv "$OUTPUT_ABS.tmp" "$OUTPUT_ABS"

log "Wrote $ASV_TREE ($PRUNED_TIPS ASVs)."
