#!/bin/bash
#
# index_directories.sh - Give every folder of a results tree a browsable listing.
#
# Author: Daniel Smith
# Date:   August 19th, 2026
#
# S3 serves objects, not directories, so a reader who follows one of the folder
# links summary_report.html carries lands on nothing. This walks a finished
# results folder and renders templates/listing.html into every directory of it,
# the results folder included: subfolders first, then files with their sizes,
# every entry linked, and a link back up.
#
# The listings are called directory_listing.html, never index.html. Across a
# published run those two names mean different things and never collide:
#
#   index.html              a page something wrote to be read - the run's
#                           landing page at the top, QIIME 2's barplot under
#                           qiime2/barplot/
#   directory_listing.html  the listing of whatever folder it sits in, written
#                           here
#
# CloudFront maps a folder URL onto the second of those; see
# docs/results/cloudfront.md. Every link written here names the file outright
# rather than relying on that, so an unpacked copy of the download zip browses
# the same way the published run does.
#
# Usage:     index_directories.sh [results_dir] [glob ...]
#            defaults to ./results, the outdir set in the ampliseq params file
#
#            A glob names something the upload was told to leave behind, read
#            relative to the results folder, and is left out of the listings
#            too - so a listing names what a reader will actually find. The
#            upload script passes the same globs to upload_results_tree.
# Called by: ampliseq_upload.sh and taxprofiler_upload.sh, before the upload
# Requires:  GNU find and awk
# Reads:     templates/listing.html, the listing template
# Env:       NEXTFLOW_DIR and the log/warn/fail, escape_html and render_template
#            helpers, sourced from .env

set -euo pipefail

source /data/prod/nextflow/.env

RESULTS_DIR="${1:-results}"
RESULTS_DIR="${RESULTS_DIR%/}"
shift || true

# What the upload leaves behind, as the find predicates that keep it out of a
# listing
SKIP=()
for GLOB in "$@"; do
    SKIP+=(! -path "$RESULTS_DIR/$GLOB")
done

readonly LISTING_NAME="directory_listing.html"

# One listing page, filled in per directory. Every link in it is relative, so it
# only works from the same prefix as the entries it names.
readonly LISTING_TEMPLATE="$NEXTFLOW_DIR/templates/listing.html"

if [[ ! -d "$RESULTS_DIR" ]]; then
    fail "There is no '$RESULTS_DIR' directory to index."
fi

if [[ ! -r "$LISTING_TEMPLATE" ]]; then
    fail "The folder listing template is missing from the server ($LISTING_TEMPLATE)."
fi

# One directory's entries as table rows. find reports type, size and name; the
# sort puts folders ahead of files - d before f - and orders each group by name.
#
# Anything named in the second argument is left out, which is how a listing omits
# itself and how the results folder's listing omits the landing page. So is
# anything matching a glob this script was given, which is what the upload was
# told to leave behind.
#
# Symlinks are followed, because publishDir may link a published file rather
# than copy it and because the upload follows them too: what the row reports is
# what S3 will hold.
render_rows() {
    local dir="$1" omit="${2:-}"

    find -L "$dir" -mindepth 1 -maxdepth 1 ${SKIP[@]+"${SKIP[@]}"} \
            -printf '%y\t%s\t%f\n' \
        | LC_ALL=C sort -t$'\t' -k1,1 -k3,3 \
        | LC_ALL=C awk -F'\t' -v omit="$omit" -v listing="$LISTING_NAME" '
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
                split(omit, hidden, " ")
                for (i in hidden) skip[hidden[i]] = 1
            }

            $1 == "f" && ($3 in skip) { next }

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
                        printf "<tr><td class=\"name\"><a class=\"dir\" href=\"%s/%s\">%s/</a></td>" \
                               "<td class=\"size\"></td></tr>\n", enc(name[i]), listing, esc(name[i])
                    else
                        printf "<tr><td class=\"name\"><a href=\"%s\">%s</a></td>" \
                               "<td class=\"size\">%s</td></tr>\n", enc(name[i]), esc(name[i]), human(size[i])
                }
                print "</tbody></table>"
            }
        '
}

# One listing page, written where its caller says. A listing that cannot be
# built is not worth failing a run over, and whatever rows did come out are
# kept: the folder gets a page either way, so the link that led here resolves.
#
# Rows are never escaped - render_rows emits the markup itself, having escaped
# and encoded every name it read off the disk.
write_listing() {
    local dir="$1" title="$2" up_link="$3" omit="${4:-}"
    local rows=""

    if ! rows=$(render_rows "$dir" "$omit"); then
        warn "The contents of $dir could not be listed in full."
    fi

    if [[ -z "$rows" ]]; then
        rows="<p class=\"empty\">This folder is empty.</p>"
    fi

    render_template "$LISTING_TEMPLATE" \
        DIR_PATH "$(escape_html "$title")" \
        UP_LINK  "$up_link" \
        ROWS     "$rows" > "$dir/$LISTING_NAME"
}

log "Indexing the folders under $RESULTS_DIR..."

INDEXED=0

# Real directories only: a listing written through a symlink would land in
# nextflow's work directory rather than in the results.
while IFS= read -r DIR; do
    # Named the way a reader arrives at it - from the run's prefix, not from
    # this machine
    REL_PATH="${DIR#"$RESULTS_DIR"/}"

    write_listing "$DIR" "$REL_PATH" \
        "<a href=\"../$LISTING_NAME\">&uarr; Up one folder</a>" "$LISTING_NAME"

    INDEXED=$((INDEXED + 1))
done < <(find "$RESULTS_DIR" -mindepth 1 -type d)

# The results folder itself, which is where every "up one folder" ends - so it
# is the page that leaves the frame. The landing page reads these listings
# inside itself, and loading it into its own frame would open a second copy of
# the dashboard in the first.
#
# The landing page is left out of the listing as well as being what the link at
# the top goes to. It is never on disk here - the upload script pipes it
# straight to S3 - but a rerun over an unpacked copy would otherwise list it.
write_listing "$RESULTS_DIR" "All output files" \
    "<a href=\"index.html\" target=\"_top\">&uarr; Results dashboard</a>" \
    "$LISTING_NAME index.html"

log "Indexed $INDEXED folders, plus the results folder itself."
