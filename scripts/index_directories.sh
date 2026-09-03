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
#                           landing page at the top, a tool's own page under
#                           its folder
#   directory_listing.html  the listing of whatever folder it sits in, written
#                           here
#
# CloudFront maps a folder URL onto the second of those; see
# docs/results/cloudfront.md. Every link written here names the file outright
# rather than relying on that, so an unpacked copy of the download zip browses
# the same way the published run does.
#
# The reads a run was given get a listing of their own, written into the results
# as raw-sequences/directory_listing.html. Those files are not published beside
# it: they are only in the zip this run publishes to Globus, which holds
# raw-sequences/ beside results/. So the rows name every file and its size but
# their links are held back - grey, and not clickable - and the note above them
# says where the files actually are. The same page read out of an unpacked copy
# of that zip has the files two levels above it, which is what its links point
# at and what listing.html turns them back on for.
#
# Usage:     index_directories.sh [results_dir] [staged_reads_dir]
#            results_dir defaults to ./results, the outdir set in the ampliseq
#            params file; the reads directory is left out by a pipeline that
#            stages none
# Called by: ampliseq_upload.sh and taxprofiler_upload.sh, after prune_results.sh
#            and before the upload
# Requires:  GNU find and awk
# Reads:     templates/listing.html, the listing template
# Env:       NEXTFLOW_DIR and the log/warn/fail, escape_html and render_template
#            helpers, sourced from .env

set -euo pipefail

source /data/prod/nextflow/.env

RESULTS_DIR="${1:-results}"
RESULTS_DIR="${RESULTS_DIR%/}"

# The reads the run was given, as they were staged. Listed inside the results
# rather than copied into them - see the note at the top of this file.
STAGED_DIR="${2:-}"
STAGED_DIR="${STAGED_DIR%/}"

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
# itself and how the results folder's listing omits the landing page.
#
# The prefix after that is written in front of every href, for a listing that
# sits somewhere other than beside the files it names, and "held" marks its rows
# as links that do not resolve where the page is published. Both are for the
# staged reads, and are empty for every folder of the results.
#
# Symlinks are followed, because publishDir may link a published file rather
# than copy it and because the upload follows them too: what the row reports is
# what S3 will hold.
render_rows() {
    local dir="$1" omit="${2:-}" prefix="${3:-}" held="${4:-}"

    find -L "$dir" -mindepth 1 -maxdepth 1 -printf '%y\t%s\t%f\n' \
        | LC_ALL=C sort -t$'\t' -k1,1 -k3,3 \
        | LC_ALL=C awk -F'\t' -v omit="$omit" -v listing="$LISTING_NAME" \
              -v prefix="$prefix" -v held="$held" '
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

                row = held ? "<tr class=\"held\">" : "<tr>"

                print "<table><tbody>"
                for (i = 1; i <= n; i++) {
                    # A folder is addressed by its own listing page, since the
                    # bucket has no directory to serve
                    if (type[i] == "d")
                        printf "%s<td class=\"name\"><a class=\"dir\" href=\"%s%s/%s\">%s/</a></td>" \
                               "<td class=\"size\"></td></tr>\n", row, prefix, enc(name[i]), \
                               listing, esc(name[i])
                    else
                        printf "%s<td class=\"name\"><a href=\"%s%s\">%s</a></td>" \
                               "<td class=\"size\">%s</td></tr>\n", row, prefix, enc(name[i]), \
                               esc(name[i]), human(size[i])
                }
                print "</tbody></table>"
            }
        '
}

# One listing page, written where its caller says. A listing that cannot be
# built is not worth failing a run over, and whatever rows did come out are
# kept: the folder gets a page either way, so the link that led here resolves.
#
# The last three arguments are for the one listing that sits somewhere other
# than the folder it lists - the staged reads: where the page goes, the way back
# from there to the files it names, and the note saying why it had to be written
# that way. Naming a page directory is also what holds its rows back, since a
# listing written away from its files is one whose files are not published.
#
# Rows are never escaped - render_rows emits the markup itself, having escaped
# and encoded every name it read off the disk.
write_listing() {
    local dir="$1" title="$2" up_link="$3" omit="${4:-}"
    local page="${5:-$dir}" prefix="${6:-}" note="${7:-}"
    local rows=""

    if ! rows=$(render_rows "$dir" "$omit" "$prefix" "${5:-}"); then
        warn "The contents of $dir could not be listed in full."
    fi

    if [[ -z "$rows" ]]; then
        rows="<p class=\"empty\">This folder is empty.</p>"
    fi

    render_template "$LISTING_TEMPLATE" \
        DIR_PATH "$(escape_html "$title")" \
        UP_LINK  "$up_link" \
        NOTE     "$note" \
        ROWS     "$rows" > "$page/$LISTING_NAME"
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

# The reads the run was given, listed inside the results under their own name.
# Written after the walk above and before the results folder's own listing, so
# the walk does not overwrite it and the listing above it names it.
#
# The files themselves are two levels above this page in the zip this run
# publishes and nowhere at all beside the copy it publishes to the bucket, which
# is what the rows point at and what listing.html holds back until the page is
# read off disk.
if [[ -n "$STAGED_DIR" && -d "$STAGED_DIR" ]]; then
    STAGED_NAME="${STAGED_DIR##*/}"

    STAGED_NOTE='<p class="note">These are the sequencing files this analysis was'
    STAGED_NOTE+=" run on. They are not published beside these results: take them with"
    STAGED_NOTE+=" the <strong>Download everything</strong> button on the Overview, and"
    STAGED_NOTE+=" the names below become live links in the copy that comes down with"
    STAGED_NOTE+=" it.</p>"

    mkdir -p "$RESULTS_DIR/$STAGED_NAME"

    write_listing "$STAGED_DIR" "$STAGED_NAME" \
        "<a href=\"../$LISTING_NAME\">&uarr; Up one folder</a>" "" \
        "$RESULTS_DIR/$STAGED_NAME" "../../$STAGED_NAME/" "$STAGED_NOTE"

    log "Listed the staged reads in $STAGED_DIR."
fi

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
