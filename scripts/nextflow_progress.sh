#!/bin/bash
#
# nextflow_progress.sh - Publish a running pipeline's progress as its results page.
#
# Author: Daniel Smith
# Date:   August 12th, 2026
#
# Renders templates/progress.html and uploads it to the key the finished report will
# later occupy, s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/<run_id>/index.html. A reader
# who opens the results link before the run finishes therefore watches it work,
# and is handed the report once ampliseq_upload.sh overwrites this file. The
# progress page refreshes itself every minute; the report does not, so a browser
# stops polling on its own the moment the run lands.
#
# The dial and the table are built from nextflow's console output, which
# wrike_job.sh tees to
# ./nextflow.out. With ANSI output off, as it is in a batch job, nextflow
# reprints its whole table every time something changes:
#
#   executor >  local (41)
#   [f5/de7a5f] NFC…SEQ:FASTQC (McAllister_P3) | 6 of 6 ✔
#   [-        ] NFC…AMPLISEQ:AMPLISEQ:DECONTAM -
#   Plus 19 more processes waiting for tasks…
#
# so the table is the last such block. Nextflow cuts each process name to a
# fixed width, marking the cut with an ellipsis; pretty() recovers the last
# workflow segment of what survives. Parsing console output is not a stable
# interface, so every failure here is soft: a page that cannot be built is
# skipped, never fatal.
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

readonly PROGRESS_TEMPLATE="$NEXTFLOW_DIR/templates/progress.html"

# What wrike_job.sh tees nextflow's console output to
readonly NEXTFLOW_OUT="nextflow.out"

# One line saying what the run is doing, written by report_stage as each stage
# starts. Nextflow's own output only covers the middle of a run.
readonly STAGE_FILE="stage.txt"

readonly DEFAULT_INTERVAL=60

# Shown before nextflow has printed its first process line, which can take a
# couple of minutes while it resolves the pipeline and its containers.
readonly STARTING_MESSAGE="Starting up. The pipeline is being prepared; progress will appear here shortly."

RUN_ID="${PWD##*/}"
if ! is_valid_uid "$RUN_ID"; then
    fail "Not running in a run directory ($PWD); nothing to publish progress for."
fi

readonly S3_INDEX="s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/$RUN_ID/index.html"

# Turn the newest block of nextflow's progress lines into table rows. Each block
# lists every process that has started, so the last one is the current state and
# everything before it is history.
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

        # "NFC…SEQ:FASTQC (McAllister_P3)" -> "FASTQC (McAllister_P3)". The
        # leading ellipsis is the one nextflow printed; it stays wherever the cut
        # reached far enough in to leave the workflow path unrecognisable.
        function pretty(name,   base, tag) {
            sub(/^.*…/, "…", name)

            tag  = ""
            base = name
            if (match(name, / \([^()]*\)$/)) {
                tag  = substr(name, RSTART)
                base = substr(name, 1, RSTART - 1)
            }

            # A stray bracket means the cut landed inside the tag of a task, so
            # what looks like a workflow path is part of that tag.
            if (base !~ /[()]/ && base ~ /:/) sub(/^.*:/, "", base)

            return base tag
        }

        # "[f5/de7a5f] NFC…SEQ:FASTQC (McAllister_P3) | 6 of 6 ✔" once a process
        # has tasks, "[-        ] NFC…AMPLISEQ:AMPLISEQ:DECONTAM -" before that
        /^\[[0-9a-f-][^]]*\] / {
            if (!inblock) { inblock = 1; n = 0; more = "" }

            rest = $0
            sub(/^\[[^]]*\] /, "", rest)

            if (match(rest, / \| [^|]*$/)) {
                name  = substr(rest, 1, RSTART - 1)
                count = substr(rest, RSTART + 3)
            }
            else {
                name  = rest
                count = ""
                sub(/[ \t]+-$/, "", name)
            }

            gsub(/^[ \t]+|[ \t]+$/, "", name)
            gsub(/^[ \t]+|[ \t]+$/, "", count)

            pcent = 0
            if (match(count, /[0-9]+ of [0-9]+/)) {
                split(substr(count, RSTART, RLENGTH), done, / of /)
                if (done[2] + 0 > 0) pcent = int(100 * done[1] / done[2])

                # Every task of the run together, which the dial reports. A
                # process nextflow has not given tasks yet counts for nothing
                # rather than for nought out of nought.
                tasks_done += done[1] + 0
                tasks_total += done[2] + 0
            }

            n++
            label[n] = pretty(name)
            pct[n]   = pcent
            cnt[n]   = count
            state[n] = count == "" ? "waiting" : (pcent >= 100 ? "done" : "active")
            next
        }

        # The line nextflow closes each block with, when it has one
        {
            inblock = 0
            if ($0 ~ /^Plus .* processes waiting/) more = $0
        }

        END {
            if (n == 0) exit 0

            # Read off the first line by the caller, which the dial is drawn from
            printf "TOTALS %d %d\n", tasks_done, tasks_total

            for (i = 1; i <= n; i++) {
                # Done is the institutional navy; work in flight is the growth
                # green, with the stripes the page animates
                fill = ""
                if (state[i] == "done")   fill = "bg-primary-container"
                if (state[i] == "active") fill = "bg-bio-growth stripe"

                printf "<div class=\"flex items-center gap-3 py-1\">"
                printf "<span class=\"font-code-md text-code-md text-on-surface truncate"
                printf " basis-[42%%] shrink-0\" title=\"%s\">%s</span>", esc(label[i]), esc(label[i])
                printf "<span class=\"flex-1 h-1.5 bg-surface-variant rounded-full overflow-hidden\">"

                if (fill != "") {
                    printf "<span class=\"block h-full %s rounded-full\" style=\"width:%s%%\"></span>", \
                        fill, (state[i] == "active" && pct[i] < 3 ? 3 : pct[i])
                }

                printf "</span>"
                printf "<span class=\"font-code-sm text-code-sm text-on-surface-variant w-9"
                printf " text-right shrink-0\">%s%%</span>", pct[i]
                printf "<span class=\"font-body-sm text-body-sm text-on-surface-variant w-24"
                printf " text-right shrink-0 hidden sm:block\">%s</span>", esc(cnt[i])
                printf "</div>\n"
            }

            if (more != "") {
                printf "<p class=\"font-body-sm text-body-sm text-outline mt-3\">%s</p>\n", esc(more)
            }
        }
    ' "$NEXTFLOW_OUT"
}

# How much of the cluster's running work is this run's, as "mine total basis".
#
# Nextflow submits every task as its own Slurm job from a work directory under
# this one, so a running job belongs to this run when its work directory does.
# A run whose executor is local has none of those, and falls back to every job
# the submitting user has running.
#
# Prints nothing when squeue cannot answer, which is what leaves the dial off
# the page rather than drawing a nought.
cluster_share() {
    local me

    command -v squeue > /dev/null 2>&1 || return 0
    me=$(id -un 2>/dev/null) || return 0

    squeue --states=RUNNING --noheader --format='%u|%Z' 2>/dev/null \
        | LC_ALL=C awk -F'|' -v me="$me" -v here="$PWD" '
            { total++ }

            index($2, here) == 1 { run++ }
            $1 == me             { mine++ }

            END {
                if (total == 0) exit 1

                if (run > 0) printf "%d %d run\n", run, total
                else         printf "%d %d user\n", mine + 0, total
            }
        '
}

# The style of a dial's arc: how much of the ring to draw, and - for a ring with
# nothing to draw - a flat cap, since a round one on an arc of zero length is
# drawn as a dot at twelve o'clock.
dial_arc() {
    local percent="$1" circumference="$2"

    if (( percent <= 0 )); then
        printf 'stroke-dasharray: 0 %s; stroke-linecap: butt' "$circumference"
        return 0
    fi

    LC_ALL=C awk -v p="$percent" -v c="$circumference" \
        'BEGIN { printf "stroke-dasharray: %.1f %s", c * p / 100, c }'
}

# That share as the second dial, or nothing at all when there was no answer
cluster_dial() {
    local mine="$1" total="$2" basis="$3"
    local percent arc caption

    [[ "$total" =~ ^[0-9]+$ ]] && (( total > 0 )) || return 0

    percent=$(( 100 * mine / total ))
    arc=$(dial_arc "$percent" 301.593)

    if [[ "$basis" == "run" ]]; then
        caption="$mine of $total running jobs on the cluster are this run's"
    else
        caption="$mine of $total running jobs on the cluster are yours"
    fi

    printf '<div class="flex flex-col items-center gap-2 pt-5 border-t border-outline-variant w-full"'
    printf ' title="%s">' "$(escape_html "$caption")"
    printf '<div class="relative w-[104px] h-[104px]">'
    printf '<svg class="dial cluster w-full h-full" viewBox="0 0 120 120">'
    printf '<circle class="text-surface-variant" cx="60" cy="60" r="48" stroke="currentColor"></circle>'
    printf '<circle class="text-secondary" cx="60" cy="60" r="48" stroke="currentColor"'
    printf ' style="%s"></circle></svg>' "$arc"
    printf '<div class="absolute inset-0 flex flex-col items-center justify-center">'
    printf '<span class="text-body-md font-bold text-primary leading-none">%s%%</span>' "$percent"
    printf '<span class="font-label-caps text-label-caps text-on-surface-variant mt-1">Cluster</span>'
    printf '</div></div>'
    printf '<p class="font-body-sm text-body-sm text-on-surface-variant text-center">%s of %s jobs</p>' \
        "$mine" "$total"
    printf '</div>'
}

# The note in the corner of the bar. A run that has failed says so in red; every
# other status is one the run is still in, and pulses.
status_pill() {
    local status="$1"
    local tone="text-secondary-fixed bg-secondary-fixed/10 border-secondary-fixed/20"
    local dot="bg-secondary-fixed"
    local pulse=1

    case "${status,,}" in
        failed)    tone="text-error-red bg-error-red/10 border-error-red/20"
                   dot="bg-error-red"
                   pulse=0 ;;
        completed) tone="text-bio-growth bg-bio-growth/10 border-bio-growth/20"
                   dot="bg-bio-growth"
                   pulse=0 ;;
    esac

    printf '<span class="flex items-center gap-2 px-3 py-1.5 rounded-full border %s' "$tone"
    printf ' font-label-caps text-label-caps font-bold">'
    printf '<span class="relative flex h-2 w-2">'

    (( pulse )) && printf '<span class="animate-ping absolute inline-flex h-full w-full rounded-full %s opacity-75"></span>' "$dot"

    printf '<span class="relative inline-flex rounded-full h-2 w-2 %s"></span></span>' "$dot"
    printf '%s</span>' "$(escape_html "$status")"
}

publish_once() {
    local status="${1:-}"
    local page rows task_name totals tasks_done tasks_total percent arc tasks
    local stage share mine total basis cluster

    if [[ ! -r "$PROGRESS_TEMPLATE" ]]; then
        warn "No progress template at $PROGRESS_TEMPLATE; skipping."
        return 1
    fi

    # Status from the run's own message bus unless the caller named one
    if [[ -z "$status" && -r "status.txt" ]]; then
        read -r status < status.txt || true
    fi
    : "${status:=Running}"

    task_name="Pipeline run"
    if [[ -r "$WRIKE_TASK_NAME_FILE" ]]; then
        read -r task_name < "$WRIKE_TASK_NAME_FILE" || true
    fi

    # What the run is doing right now, which wrike_job.sh writes as it moves
    # from one stage to the next. Nextflow is only one of them, and the ones
    # before it are why this page exists before there is a task to count.
    #
    # The pages published before the job starts have no stage file to read, so
    # the status stands in for one.
    stage=""
    if [[ -r "$STAGE_FILE" ]]; then
        read -r stage < "$STAGE_FILE" || true
    fi

    if [[ -z "$stage" ]]; then
        case "${status,,}" in
            validating) stage="Checking your request." ;;
            queued)     stage="Waiting for a slot on the cluster." ;;
            failed)     stage="This run did not finish." ;;
            *)          stage="Your analysis is running." ;;
        esac
    fi

    rows=""
    if [[ -r "$NEXTFLOW_OUT" ]]; then
        rows=$(render_rows) || rows=""
    fi

    # The first line render_rows writes is the run's task totals, which the dial
    # is drawn from rather than listed with
    tasks_done=0
    tasks_total=0

    if [[ "$rows" == TOTALS\ * ]]; then
        totals=${rows%%$'\n'*}
        rows=${rows#*$'\n'}

        read -r _ tasks_done tasks_total <<< "$totals"
    fi

    if [[ -z "$rows" ]]; then
        rows="<p class=\"font-body-sm text-body-sm text-on-surface-variant\">$STARTING_MESSAGE</p>"
    fi

    # Percent of every task the run has started, and the arc of the dial that
    # says so - the circle it is drawn on is 339.292 long.
    percent=0
    tasks="Waiting for the first task"

    if (( tasks_total > 0 )); then
        percent=$(( 100 * tasks_done / tasks_total ))
        tasks="$tasks_done of $tasks_total tasks"
    fi

    arc=$(dial_arc "$percent" 339.292)

    # How busy the cluster is with everyone else, which is the other thing a
    # reader waiting on a queue wants to know
    cluster=""
    if share=$(cluster_share) && [[ -n "$share" ]]; then
        read -r mine total basis <<< "$share"
        cluster=$(cluster_dial "$mine" "$total" "$basis")
    fi

    # Rows are never escaped - render_rows emits the markup itself, having
    # escaped everything that came out of the log.
    page=$(render_template "$PROGRESS_TEMPLATE" \
        TASK_NAME   "$(escape_html "$task_name")" \
        RUN_ID      "$RUN_ID" \
        STATUS_PILL "$(status_pill "$status")" \
        STAGE       "$(escape_html "$stage")" \
        PERCENT     "$percent" \
        ARC         "$arc" \
        TASKS       "$(escape_html "$tasks")" \
        CLUSTER     "$cluster" \
        UPDATED     "$(date '+%B %-d, %Y at %-I:%M %p %Z')" \
        ROWS        "$rows") || return 1

    # --content-type because reading the body from stdin leaves aws nothing to
    # guess from, and a page served as binary downloads instead of rendering.
    printf '%s\n' "$page" \
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
