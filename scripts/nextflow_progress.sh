#!/bin/bash
#
# nextflow_progress.sh - Publish a running pipeline's progress as its results page.
#
# Author: Daniel Smith
# Date:   August 12th, 2026
#
# Renders config/progress.html and uploads it to the key the finished report will
# later occupy, s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/<run_id>/index.html. A reader
# who opens the results link before the run finishes therefore watches it work,
# and is handed the report once ampliseq_upload.sh overwrites this file. The
# progress page refreshes itself every minute; the report does not, so a browser
# stops polling on its own the moment the run lands.
#
# The table is built from nextflow's console output, which wrike_job.sh tees to
# ./nextflow.out - one line per change when ANSI output is off, as it is in a
# batch job:
#
#   [31/52c31e] process > SPLITLETTERS (1) [100%] 1 of 1, cached: 1 ✔
#
# so the table is those lines, last one per process winning. Parsing console
# output is not a stable interface, so every failure here is soft: a page that
# cannot be built is skipped, never fatal.
#
# Usage:     nextflow_progress.sh                 # publish once, status from status.txt
#            nextflow_progress.sh <status>        # publish once, status forced
#            nextflow_progress.sh --watch [secs]  # publish repeatedly until killed
# Called by: wrike_task_handler.sh, once per change of status while a request is
#            being handled - the first of those calls creates the run's S3 prefix
#            - and wrike_job.sh, backgrounded for the length of the nextflow stage
# Requires:  aws, awk
# Env:       NEXTFLOW_DIR, AWS_S3_BUCKET, S3_RUN_PREFIX, and the log/warn helpers
#            and is_valid_uid, all sourced from .env
#
# Run from inside the run directory, whose name is the run ID.

set -euo pipefail

source /data/prod/nextflow/.env

readonly PROGRESS_TEMPLATE="$NEXTFLOW_DIR/config/progress.html"

# What wrike_job.sh tees nextflow's console output to
readonly NEXTFLOW_OUT="nextflow.out"

readonly DEFAULT_INTERVAL=60

# Shown before nextflow has printed its first process line, which can take a
# couple of minutes while it resolves the pipeline and its containers.
readonly STARTING_MESSAGE="Starting up. The pipeline is being prepared; progress will appear here shortly."

RUN_ID="${PWD##*/}"
if ! is_valid_uid "$RUN_ID"; then
    fail "Not running in a run directory ($PWD); nothing to publish progress for."
fi

readonly S3_INDEX="s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/$RUN_ID/index.html"

# Turn nextflow's progress lines into table rows, keeping only the newest line
# per process. The name carries the current task's tag - "FASTQC (sample3)" -
# which changes constantly, so rows are keyed on the name without it and display
# the latest one, exactly as the interactive table does.
render_rows() {
    awk '
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

        # "[hash] process > NAME (tag) [ 50%] 6 of 12, cached: 1 ✔"
        /process > / {
            rest = substr($0, index($0, "process > ") + 10)

            # The percentage in brackets is what separates name from counts
            if (match(rest, /\[[ ]*[0-9]+%\]/) == 0) next

            name  = substr(rest, 1, RSTART - 1)
            pcent = substr(rest, RSTART, RLENGTH)
            count = substr(rest, RSTART + RLENGTH)

            gsub(/^[ \t]+|[ \t]+$/, "", name)
            gsub(/^[ \t]+|[ \t]+$/, "", count)
            gsub(/[^0-9]/, "", pcent)

            key = name
            sub(/[ \t]*\([^)]*\)[ \t]*$/, "", key)

            if (!(key in seen)) { seen[key] = ++n; order[n] = key }
            label[key] = name
            pct[key]   = pcent
            cnt[key]   = count
        }

        END {
            if (n == 0) exit 0

            print "<table>"
            print "<thead><tr><th>Process</th><th></th><th></th><th>Tasks</th></tr></thead>"
            print "<tbody>"
            for (i = 1; i <= n; i++) {
                k = order[i]
                printf "<tr><td class=\"proc\">%s</td>", esc(label[k])
                printf "<td class=\"bar\"><span><i style=\"width:%s%%\"></i></span></td>", pct[k]
                printf "<td class=\"pct\">%s%%</td>", pct[k]
                printf "<td class=\"cnt\">%s</td></tr>\n", esc(cnt[k])
            }
            print "</tbody></table>"
        }
    ' "$NEXTFLOW_OUT"
}

publish_once() {
    local status="${1:-}"
    local template rows task_name

    if [[ ! -r "$PROGRESS_TEMPLATE" ]]; then
        warn "No progress template at $PROGRESS_TEMPLATE; skipping."
        return 1
    fi
    template=$(<"$PROGRESS_TEMPLATE")

    # Status from the run's own message bus unless the caller named one
    if [[ -z "$status" && -r "status.txt" ]]; then
        read -r status < status.txt || true
    fi
    : "${status:=Running}"

    task_name="Pipeline run"
    if [[ -r "$WRIKE_TASK_NAME_FILE" ]]; then
        read -r task_name < "$WRIKE_TASK_NAME_FILE" || true
    fi

    rows=""
    if [[ -r "$NEXTFLOW_OUT" ]]; then
        rows=$(render_rows) || rows=""
    fi
    if [[ -z "$rows" ]]; then
        rows="<p class=\"empty\">$STARTING_MESSAGE</p>"
    fi

    # Replacements are variable expansions rather than literal text, so bash
    # inserts them as-is - no second pass over backslashes, which a task name is
    # free to contain.
    template=${template//__TASK_NAME__/$(escape_html "$task_name")}
    template=${template//__RUN_ID__/$RUN_ID}
    template=${template//__STATUS__/$(escape_html "$status")}
    template=${template//__UPDATED__/$(date '+%B %-d, %Y at %-I:%M %p %Z')}

    # Rows last, and never escaped - render_rows emits the markup itself, having
    # escaped everything that came out of the log.
    template=${template//__ROWS__/$rows}

    # --content-type because reading the body from stdin leaves aws nothing to
    # guess from, and a page served as binary downloads instead of rendering.
    printf '%s\n' "$template" \
        | aws s3 cp - "$S3_INDEX" --content-type "text/html" > /dev/null
}

if [[ "${1:-}" == "--watch" ]]; then
    INTERVAL="${2:-$DEFAULT_INTERVAL}"

    # Ends when wrike_job.sh kills it, which is the only way out
    while true; do
        publish_once || warn "Could not publish the progress page; will try again."
        sleep "$INTERVAL"
    done
fi

publish_once "${1:-}" || warn "Could not publish the progress page."
