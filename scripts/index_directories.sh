#!/bin/bash
#
# index_directories.sh - Give every folder of a results tree a browsable listing.
#
# Author: Daniel Smith
# Date:   August 19th, 2026
#
# S3 serves objects, not directories, so a reader who follows one of the folder
# links summary_report.html carries lands on nothing. This walks a finished
# results folder and renders templates/listing.html into each subdirectory
# below it: subfolders first, then files with their sizes, every entry linked,
# and a link back up.
#
# A directory that already holds an index.html keeps it, so pages the pipeline
# published itself are left alone. That also makes a second run over the same
# results folder a no-op.
#
# Whether a link here opens in the browser or downloads is settled by the content
# type the upload gives each object, not by the page: see TEXT_EXTENSIONS in
# publish_dashboard.sh.
#
# The results folder itself is skipped. Its index.html is the run's landing
# page, which ampliseq_upload.sh renders and uploads after everything else.
#
# Usage:     index_directories.sh [results_dir]
#            defaults to ./results, the outdir set in the ampliseq params file
# Called by: ampliseq_upload.sh, just before it copies the folder to S3
# Requires:  GNU find and awk
# Reads:     templates/listing.html, the listing template
# Env:       NEXTFLOW_DIR and the log/warn/fail, escape_html and render_template
#            helpers, sourced from .env

set -euo pipefail

source /data/prod/nextflow/.env

RESULTS_DIR="${1:-results}"
RESULTS_DIR="${RESULTS_DIR%/}"

readonly INDEX_NAME="index.html"

# One listing page, filled in per directory. Every link in it is relative, so it
# only works from the same prefix as the entries it names.
readonly INDEX_TEMPLATE="$NEXTFLOW_DIR/templates/listing.html"

if [[ ! -d "$RESULTS_DIR" ]]; then
    fail "There is no '$RESULTS_DIR' directory to index."
fi

if [[ ! -r "$INDEX_TEMPLATE" ]]; then
    fail "The folder listing template is missing from the server ($INDEX_TEMPLATE)."
fi

# One directory's entries as table rows. find reports type, size and name; the
# sort puts folders ahead of files - d before f - and orders each group by name.
#
# Symlinks are followed, because publishDir may link a published file rather
# than copy it and because the upload follows them too: what the row reports is
# what S3 will hold.
render_rows() {
    local dir="$1"

    find -L "$dir" -mindepth 1 -maxdepth 1 -printf '%y\t%s\t%f\n' \
        | LC_ALL=C sort -t$'\t' -k1,1 -k3,3 \
        | LC_ALL=C awk -F'\t' '
            # HTML-escape, a character at a time
            function esc(s,   out, i, c) {
                out = ""
                for (i = 1; i <= length(s); i++) {
                    c = substr(s, i, 1)
                    if      (c == "&") out = out "&amp;"
                    else if (c == "<") out = out "&lt;"
                    else if (c == ">") out = out "&gt;"
                    else               out = out c
                }
                return out
            }

            # Percent-encode a name for the href beside it. A filename is bytes
            # and is encoded as bytes, which is what the C locale makes this
            # loop walk - a name with an accent in it comes out as the two
            # bytes UTF-8 spells it with, the encoding a browser expects.
            function enc(s,   out, i, c) {
                out = ""
                for (i = 1; i <= length(s); i++) {
                    c = substr(s, i, 1)
                    if (c ~ /[A-Za-z0-9._~-]/) out = out c
                    else                       out = out sprintf("%%%02X", ord[c])
                }
                return out
            }

            # Bytes, in the units a download is read in
            function human(bytes,   i) {
                i = 1
                while (bytes >= 1024 && i < 6) { bytes /= 1024; i++ }
                if (i == 1) return sprintf("%d %s", bytes, unit[i])
                return sprintf("%.1f %s", bytes, unit[i])
            }

            BEGIN {
                for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
                split("B KB MB GB TB PB", unit, " ")
            }

            {
                n++
                type[n] = $1
                size[n] = $2
                name[n] = $3
            }

            END {
                if (n == 0) exit 0

                print "<table><tbody>"
                for (i = 1; i <= n; i++) {
                    # A folder is addressed by its own listing page, since the
                    # bucket has no directory to serve
                    if (type[i] == "d")
                        printf "<tr><td class=\"name\"><a class=\"dir\" href=\"%s/index.html\">%s/</a></td>" \
                               "<td class=\"size\"></td></tr>\n", enc(name[i]), esc(name[i])
                    else
                        printf "<tr><td class=\"name\"><a href=\"%s\">%s</a></td>" \
                               "<td class=\"size\">%s</td></tr>\n", enc(name[i]), esc(name[i]), human(size[i])
                }
                print "</tbody></table>"
            }
        '
}

log "Indexing the folders under $RESULTS_DIR..."

INDEXED=0

# Real directories only: an index.html written through a symlink would land in
# nextflow's work directory rather than in the results.
while IFS= read -r DIR; do
    [[ -e "$DIR/$INDEX_NAME" ]] && continue

    # Named the way a reader arrives at it - from the run's prefix, not from
    # this machine
    REL_PATH="${DIR#"$RESULTS_DIR"/}"

    # A listing that cannot be built is not worth failing a run over, and
    # whatever rows did come out are kept: the folder gets a page either way, so
    # the link that led here resolves.
    if ! ROWS=$(render_rows "$DIR"); then
        warn "The contents of $DIR could not be listed in full."
    fi

    if [[ -z "$ROWS" ]]; then
        ROWS="<p class=\"empty\">This folder is empty.</p>"
    fi

    # Rows are never escaped - render_rows emits the markup itself, having
    # escaped and encoded every name it read off the disk.
    render_template "$INDEX_TEMPLATE" \
        DIR_PATH "$(escape_html "$REL_PATH")" \
        ROWS     "$ROWS" > "$DIR/$INDEX_NAME"

    INDEXED=$((INDEXED + 1))
done < <(find "$RESULTS_DIR" -mindepth 1 -type d)

log "Indexed $INDEXED folders."
