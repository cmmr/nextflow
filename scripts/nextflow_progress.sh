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
# progress page refreshes itself every ten seconds; the report does not, so a
# browser stops polling on its own the moment the run lands.
#
# A run that has failed carries its logs on the page as well: nextflow's error
# block, the debug log beside it, and the command that was run, so a requester
# has something to quote without anyone reading the cluster for them.
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
# Requires:  aws, awk; squeue and sacct for the cluster counts and the clocks,
#            each optional
# Env:       NEXTFLOW_DIR, AWS_S3_BUCKET, S3_RUN_PREFIX, and the log/warn helpers
#            and is_valid_uid, all sourced from .env
#
# Run from inside the run directory, whose name is the run ID.

set -euo pipefail

source /data/prod/nextflow/.env

readonly PROGRESS_TEMPLATE="$NEXTFLOW_DIR/templates/progress.html"

# What wrike_job.sh tees nextflow's console output to, and the command it wrote
# out and then ran - both read only when a run has failed
readonly NEXTFLOW_OUT="nextflow.out"
readonly NEXTFLOW_CMD="nextflow_command.sh"

# One line saying what the run is doing, written by report_stage as each stage
# starts. Nextflow's own output only covers the middle of a run.
readonly STAGE_FILE="stage.txt"

readonly DEFAULT_INTERVAL=10

# How much of a log a failed run's page carries. Enough for nextflow's error
# block, which runs to a few dozen lines, without pasting a whole run's output
# into an object a browser reloads.
readonly LOG_TAIL_LINES=200

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

# The Slurm jobs this run has on the cluster, as "running pending elapsed".
#
# Nextflow submits every task as its own Slurm job from a work directory under
# this one, and the job driving the run is chdir'd here, so a job belongs to this
# run when its work directory is this one or below it. The follow-up job that
# reports the outcome is chdir'd here too, and is left out of both counts: it is
# held on a dependency for the whole run, and by the time it is running the run
# it reports is over.
#
# elapsed is how long the longest-running of them has been going, which is the
# job driving the run.
#
# Prints nothing when squeue cannot answer or this run has nothing on the
# cluster, which is what leaves the widgets off the page rather than drawing
# noughts.
cluster_counts() {
    local me

    command -v squeue > /dev/null 2>&1 || return 0
    me=$(id -un 2>/dev/null) || return 0

    squeue --user="$me" --states=RUNNING,PENDING --noheader --format='%T|%r|%M|%Z|%o' 2>/dev/null \
        | LC_ALL=C awk -F'|' -v here="$PWD" '
            # Slurm elapsed times: "1-02:03:04", "02:03:04", "3:04" or "4"
            function secs(t,   days, part, n, i, s) {
                days = 0
                if (match(t, /^[0-9]+-/)) {
                    days = substr(t, 1, RLENGTH - 1) + 0
                    t = substr(t, RLENGTH + 1)
                }

                s = 0
                n = split(t, part, ":")
                for (i = 1; i <= n; i++) s = s * 60 + (part[i] + 0)

                return days * 86400 + s
            }

            # squeue pads some of its columns, and every field here is compared
            # or added up
            {
                for (i = 1; i <= NF; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i)
            }

            # The follow-up, by the script it runs and by the dependency it
            # waits on, either of which is enough on its own
            /wrike_followup\.sh/                  { next }
            $1 == "PENDING" && $2 ~ /^Dependency/ { next }

            index($4, here) != 1 { next }

            $1 == "RUNNING" {
                running++
                if (secs($3) > elapsed) elapsed = secs($3)
                next
            }

            $1 == "PENDING" { pending++ }

            END {
                if (running + pending == 0) exit 1
                printf "%d %d %d\n", running, pending, elapsed
            }
        '
}

# Cpu-seconds every Slurm job of this run has held between them, read out of the
# accounting database, which is the only place the tasks that have already
# finished are still counted. The window is the run's own age, with a few
# minutes' slack for the driver job that was submitted before it.
#
# Prints nothing when sacct cannot answer, which leaves the cpu clock off the
# widget without taking the wall clock with it.
run_cpu_seconds() {
    local elapsed="$1"

    command -v sacct > /dev/null 2>&1 || return 0

    sacct --allocations --noheader --parsable2 --starttime="now-$(( elapsed + 300 ))seconds" \
        --format=CPUTimeRAW,WorkDir 2>/dev/null \
        | LC_ALL=C awk -F'|' -v here="$PWD" '
            index($2, here) == 1 { total += $1 }
            END { if (total == 0) exit 1; print total }
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

# Seconds as hours and minutes, with the hours left to run past 24
clock() {
    local t="$1"

    printf '%dh %02dm' "$(( t / 3600 ))" "$(( t / 60 % 60 ))"
}

# What this run has on the cluster, as the two counts under the dial
cluster_stats() {
    local running="$1" pending="$2"
    local caption="$running of this run's jobs are running, $pending waiting for a slot"

    printf '<div class="flex items-center justify-center gap-7 pt-5 border-t border-outline-variant w-full"'
    printf ' title="%s">' "$(escape_html "$caption")"

    printf '<div class="flex flex-col items-center">'
    printf '<span class="font-headline-lg text-headline-lg font-bold text-primary leading-none">%s</span>' "$running"
    printf '<span class="font-label-caps text-label-caps text-on-surface-variant mt-1">Running</span>'
    printf '</div>'

    printf '<div class="flex flex-col items-center">'
    printf '<span class="font-headline-lg text-headline-lg font-bold text-primary leading-none">%s</span>' "$pending"
    printf '<span class="font-label-caps text-label-caps text-on-surface-variant mt-1">Queued</span>'
    printf '</div>'

    printf '</div>'
}

# The run's clocks, at the foot of the column: how long it has been going, and -
# when the accounting database can be asked - how much cpu time it has held.
#
# Read at the moment the page is rendered rather than counted up in the browser,
# so they step forward with each refresh; the minute they are given to is finer
# than anything a reader waiting on a run needs.
timers_widget() {
    local elapsed="$1"
    local cpu

    (( elapsed > 0 )) || return 0

    cpu=$(run_cpu_seconds "$elapsed") || cpu=""

    printf '<div class="flex flex-col gap-1 pt-5 border-t border-outline-variant w-full">'

    printf '<div class="flex items-baseline justify-between gap-2">'
    printf '<span class="font-body-sm text-body-sm text-on-surface-variant">Elapsed</span>'
    printf '<span class="font-body-sm text-body-sm text-on-surface">%s</span>' "$(clock "$elapsed")"
    printf '</div>'

    if [[ -n "$cpu" ]]; then
        printf '<div class="flex items-baseline justify-between gap-2"'
        printf ' title="Cpu time held across every job of this run, finished ones included">'
        printf '<span class="font-body-sm text-body-sm text-on-surface-variant">CPU time</span>'
        printf '<span class="font-body-sm text-body-sm text-on-surface">%s</span>' "$(clock "$cpu")"
        printf '</div>'
    fi

    printf '</div>'
}

# The last of a file, for a page to show. Nothing when it is not there or is
# empty, which is what leaves its block off the report.
file_tail() {
    local file="$1"

    [[ -s "$file" ]] || return 1

    tail -n "$LOG_TAIL_LINES" "$file"
}

# Nextflow's account of what went wrong: everything from the last "ERROR ~" line
# to the end of its output, which is the block naming the process that failed,
# its exit status, what it printed, and the work directory it left behind.
#
# A run killed by the scheduler, or one that died before nextflow said anything,
# has no such block; the tail of the output stands in for it.
nextflow_error() {
    [[ -s "$NEXTFLOW_OUT" ]] || return 1

    LC_ALL=C awk -v tail="$LOG_TAIL_LINES" '
        { line[NR] = $0 }
        /^ERROR ~/ { start = NR }

        END {
            if (NR == 0) exit 1

            first = start ? start : NR - tail + 1
            if (NR - first + 1 > tail) first = NR - tail + 1
            if (first < 1) first = 1

            for (i = first; i <= NR; i++) print line[i]
        }
    ' "$NEXTFLOW_OUT"
}

# One log under a heading, as a block the page scrolls rather than grows with.
# Given a third argument it starts open, which the one log a reader came for is.
log_panel() {
    local title="$1" body="$2"

    printf '<details class="border border-outline-variant rounded-lg"%s>' \
        "${3:+ open}"
    printf '<summary class="font-label-caps text-label-caps text-on-surface-variant'
    printf ' px-3 py-2 cursor-pointer">%s</summary>' "$(escape_html "$title")"
    printf '<pre class="font-code-sm text-code-sm text-on-surface bg-surface-container'
    printf ' px-3 py-2 max-h-96 overflow-auto">%s</pre>' "$(escape_html "$body")"
    printf '</details>'
}

# What went wrong, for a run that did not finish - the panel that is the whole
# reason a failed run's page is worth opening.
#
# message.out is the explanation whichever stage failed left behind, and the
# three logs under it are the run's own record: what nextflow printed as it
# died, its debug log, and the command it was given. A run that failed before
# nextflow started has none of those, and the panel is left off.
failure_report() {
    local message="" error="" log="" command=""

    [[ -s "message.out" ]] && message=$(<message.out)

    error=$(nextflow_error)               || error=""
    log=$(file_tail ".nextflow.log")      || log=""
    command=$(file_tail "$NEXTFLOW_CMD")  || command=""

    [[ -n "$message$error$log$command" ]] || return 0

    printf '<div class="bg-surface-container-lowest border border-error-red/40 rounded-xl'
    printf ' shadow-sm p-padding-card flex flex-col gap-3">'
    printf '<h2 class="font-headline-lg text-headline-lg font-bold text-error-red">'
    printf 'What went wrong</h2>'

    if [[ -n "$message" ]]; then
        printf '<p class="font-body-md text-body-md text-on-surface">%s</p>' \
            "$(escape_html "$message")"
    fi

    [[ -n "$error" ]]   && log_panel "Nextflow output" "$error" open
    [[ -n "$log" ]]     && log_panel "Nextflow log (.nextflow.log)" "$log"
    [[ -n "$command" ]] && log_panel "The command that was run" "$command"

    printf '<p class="font-body-sm text-body-sm text-on-surface-variant">'
    printf 'Run %s, kept for inspection at %s.</p>' \
        "$(escape_html "$RUN_ID")" "$(escape_html "$PWD")"
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
    local stage counts running pending elapsed clusters timers failure

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

    # What this run holds on the cluster, and how long it has been holding it,
    # which is the other thing a reader waiting on a queue wants to know
    clusters=""
    timers=""
    if counts=$(cluster_counts) && [[ -n "$counts" ]]; then
        read -r running pending elapsed <<< "$counts"

        clusters=$(cluster_stats "$running" "$pending")
        timers=$(timers_widget "$elapsed")
    fi

    # A run that did not finish gets its logs on the page, since this page is
    # where its requester is going to look for them
    failure=""
    if [[ "${status,,}" == "failed" ]]; then
        failure=$(failure_report) || failure=""
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
        CLUSTER     "$clusters" \
        TIMERS      "$timers" \
        FAILURE     "$failure" \
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
