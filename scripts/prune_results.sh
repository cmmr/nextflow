#!/bin/bash
#
# prune_results.sh - Delete what a pipeline wrote for itself out of a results folder.
#
# Author: Daniel Smith
# Date:   September 1st, 2026
#
# A finished run publishes about ten times more bytes than anyone reads, nearly
# all of it either a tool's own scratch or a second copy of something already
# published in a form a reader can use. This deletes that, in place, before the
# folder is indexed and uploaded - so the listings, the file index, the zip and
# the bucket all describe the same thing, and none of them describes a file that
# is not there.
#
# What goes is named per pipeline in templates/<pipeline>/prune.conf, read as
#
#     action | path | argument
#
# with the fields trimmed and blank or "#" lines skipped. Two actions:
#
#   remove          delete everything the path matches. A path is relative to
#                   the results folder and may be a glob; one ending in "/"
#                   matches directories only, and is deleted whole.
#   drop-zero-rows  rewrite a merged table, keeping only the rows that carry a
#                   number somewhere. The argument is the first data column,
#                   counting from 1, so the taxon names and ids ahead of it are
#                   not read as data. Nothing else about the file changes.
#
# A path matching nothing is not an error: the conf names what a pipeline can
# produce, and no run produces all of it.
#
# Directories left empty by the deletions are removed too, so a folder a reader
# would open onto nothing is not listed at all.
#
# Usage:     prune_results.sh <results_dir> <prune_conf>
# Called by: ampliseq_upload.sh and taxprofiler_upload.sh, before the folders
#            are indexed
# Requires:  GNU find and awk
# Env:       the log/warn/fail helpers, sourced from .env

set -euo pipefail

source /data/prod/nextflow/.env

RESULTS_DIR="${1:-}"
RESULTS_DIR="${RESULTS_DIR%/}"
PRUNE_CONF="${2:-}"

if [[ ! -d "$RESULTS_DIR" ]]; then
    fail "There is no '$RESULTS_DIR' directory to prune."
fi

if [[ ! -r "$PRUNE_CONF" ]]; then
    fail "There is no prune list at $PRUNE_CONF; nothing would be deleted."
fi

# What has gone, for the line at the end
REMOVED_FILES=0
REMOVED_BYTES=0

trim() {
    local s="$1"

    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}

    printf '%s' "$s"
}

# Everything one path matches, deleted. The glob is expanded unquoted, so a "*"
# in it crosses names the way it does in a shell; a trailing "/" leaves it
# matching directories only, which is how a folder is named without also naming
# the merged file that sits beside it.
remove_matches() {
    local pattern="$1"
    local path bytes

    # Unset, so that the unquoted expansion below globs without also splitting a
    # match on the spaces some tools put in a filename
    local IFS=

    for path in "$RESULTS_DIR"/$pattern; do
        # An unmatched glob comes back as itself
        [[ -e "$path" ]] || continue

        bytes=$(find "$path" -type f -printf '%s\n' 2>/dev/null | awk '{ t += $1 } END { print t + 0 }')
        REMOVED_FILES=$(( REMOVED_FILES + $(find "$path" -type f 2>/dev/null | wc -l) ))
        REMOVED_BYTES=$(( REMOVED_BYTES + bytes ))

        rm -rf "$path" || warn "Could not delete $path from the results."
    done
}

# One merged table with its empty rows taken out. A profile is a row per taxon
# in the whole database and a column per sample, so most of it is a species this
# run never saw reported as zero in every sample - 33,039 of the 34,344 rows on
# the run this was written for. The rows carrying a count are the run; the rest
# is the database.
#
# Written beside the original and moved over it, so a failure part way through
# leaves the table it could not rewrite rather than half of one.
drop_zero_rows() {
    local pattern="$1" first="$2"
    local path before after

    local IFS=

    if [[ ! "$first" =~ ^[0-9]+$ ]] || (( first < 1 )); then
        warn "drop-zero-rows on \"$pattern\" names no first data column; leaving it alone."
        return 0
    fi

    for path in "$RESULTS_DIR"/$pattern; do
        [[ -f "$path" ]] || continue

        before=$(wc -l < "$path")

        if ! LC_ALL=C awk -F'\t' -v first="$first" '
                # Headers, and anything with no data columns in it, are kept as
                # they are
                /^#/ || NF < first { print; next }

                {
                    for (i = first; i <= NF; i++) {
                        if ($i + 0 != 0) { print; next }
                    }
                }
            ' "$path" > "$path.pruned"; then
            warn "Could not drop the empty rows from $path; leaving it as it is."
            rm -f "$path.pruned"
            continue
        fi

        after=$(wc -l < "$path.pruned")

        REMOVED_BYTES=$(( REMOVED_BYTES + $(stat -c %s "$path") - $(stat -c %s "$path.pruned") ))

        mv -f "$path.pruned" "$path" \
            || warn "Could not replace $path with its pruned copy."

        log "Pruned $((before - after)) empty row(s) from ${path#"$RESULTS_DIR/"}."
    done
}

log "Pruning $RESULTS_DIR against $PRUNE_CONF..."

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
    LINE=${LINE//$'\r'/}
    LINE=$(trim "$LINE")

    [[ -z "$LINE" || "$LINE" == \#* ]] && continue

    IFS='|' read -r ACTION PATTERN ARGUMENT <<< "$LINE"

    ACTION=$(trim "$ACTION")
    PATTERN=$(trim "$PATTERN")
    ARGUMENT=$(trim "${ARGUMENT:-}")

    [[ -n "$ACTION" && -n "$PATTERN" ]] || continue

    # A pattern that climbs out of the results folder would delete something
    # this script was never pointed at
    if [[ "$PATTERN" == /* || "$PATTERN" == *..* ]]; then
        warn "Refusing \"$PATTERN\": a prune list names paths inside the results folder."
        continue
    fi

    case "$ACTION" in
        remove)         remove_matches "$PATTERN" ;;
        drop-zero-rows) drop_zero_rows "$PATTERN" "$ARGUMENT" ;;
        *)              warn "Unknown prune action \"$ACTION\"; skipping \"$PATTERN\"." ;;
    esac
done < "$PRUNE_CONF"

# Folders the deletions emptied. Deepest first, so a folder holding nothing but
# emptied folders goes too; the results folder itself is never a candidate.
find "$RESULTS_DIR" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true

log "Pruned $REMOVED_FILES file(s), $(human_size "$REMOVED_BYTES") in all, from $RESULTS_DIR."
