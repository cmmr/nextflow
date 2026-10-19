#!/bin/bash
#SBATCH --job-name=wrike_followup
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --time=00:02:00
#SBATCH --output=/data/prod/nextflow/log/followup_%x_%j.out
#SBATCH --error=/data/prod/nextflow/log/followup_%x_%j.out
#
# wrike_followup.sh - Report the outcome of a pipeline run back to Wrike.
#
# Author: Daniel Smith
# Date:   August 12th, 2026
#
# Submitted with --dependency=afterany on the wrike_job.sh it follows, so it runs
# whether that job succeeded, failed, or was killed by the scheduler. Both jobs
# share --job-name and --chdir, so the run's state is read straight out of
# run_state.json in the working directory:
#
#   .status   the last stage wrike_job.sh reached; "Completed" only on success
#   .message  optional user-facing explanation, left by fail wherever the run
#             went wrong
#   .notes    anything a stage wanted reported whether or not the run failed,
#             such as the 16S region ampliseq_detect_region.sh measured
#
# A run that succeeded has that file published to its S3 prefix here, since it is
# the last thing to read it before the run directory goes. A failed run's is
# published by the progress page this republishes below.
#
# A failed run also gets its results page republished as the failure, since that
# is the link the requester was given and the logs it carries are what they are
# going to be asked about.
#
# A job Slurm stopped - at its time limit, over its memory, cancelled, on a
# failed node, or preempted - is killed before it can explain itself, so this
# asks Slurm how the job recorded as ".slurm.job_id" ended and writes the
# ".message" itself: what stopped it, and the tasks nextflow still had running.
# A job that failed without leaving a message gets its exit status. Any task
# nextflow left queued or running is cancelled, and the message says which.
#
# A successful run has already published to S3, so its run directory is removed.
# A failed one is kept for inspection.
#
# Either way, the run first leaves one line in log/run_history.tsv: its pipeline,
# how it ended, how many samples and gigabytes of FASTQ it was given, and the cpu
# time its jobs held. Read here rather than off the progress page's last clock,
# since this is the one moment every job of the run has finished and been
# accounted for. It is what an estimate of how far along a running job is gets
# fitted to.
#
# --output and --error name the same file, so both streams land in one
# log/followup_<uid>_<jobid>.out.
#
# Usage:     sbatch --chdir=<run_dir> --job-name=<uid> \
#                --dependency=afterany:<job_id> wrike_followup.sh
# Called by: wrike_task_handler.sh
# Runs:      scripts/nextflow_progress.sh, once, for a run that failed
# Requires:  curl and jq (via the Wrike helpers); scontrol, sacct, squeue,
#            scancel and flock, each optional
# Writes:    one line of $NEXTFLOW_DIR/log/run_history.tsv
# Env:       NEXTFLOW_DIR, the Wrike helper functions and the run state helpers,
#            sourced from .env
#
# Exits 1 on a failed pipeline so the Slurm accounting record matches the outcome
# reported to the user.

set -euo pipefail

source /data/prod/nextflow/.env

# The run directory is named after the uid; the Wrike task it came from is
# recorded inside it, and the Wrike helpers all read TASK_ID from the
# environment.
if ! TASK_ID=$(read_wrike_task_id); then
    fail "Cannot tell which Wrike task this run belongs to; its outcome goes unreported."
fi

# Validated because RUN_DIR is deleted recursively below, and an empty uid would
# make that the whole tmp directory.
RUN_ID="${PWD##*/}"
if ! is_valid_uid "$RUN_ID"; then
    fail "Not running in a run directory ($PWD); refusing to clean up."
fi

RUN_DIR="$NEXTFLOW_DIR/tmp/$RUN_ID"

# Everything a stage wanted said, and the explanation whichever stage failed
# left behind, in the order the reply carries them
run_report() {
    local reply="" notes message

    notes=$(state_get_json notes | jq -r '.[]?' 2>/dev/null) || notes=""
    message=$(state_get message)

    [[ -n "$notes" ]]   && reply+=$'\n'"$notes"
    [[ -n "$message" ]] && reply+=$'\n'"$message"

    printf '%s' "$reply"
}

# Where every run that ends leaves one line: when it ended, which run and which
# pipeline version it was, how it ended, how many samples and gigabytes of FASTQ
# it was given, and the cpu hours its jobs held.
RUN_HISTORY="$NEXTFLOW_DIR/log/run_history.tsv"

# This run's line, appended under a lock since two runs can end at once, with
# the header written first by whichever run finds the file empty.
#
# The FASTQ is measured as the run staged it in raw-sequences/ - through the
# links to the requester's own copies, and after any recompression to gzip - in
# decimal gigabytes. The cpu time is every job whose work directory is this
# run's, from when the run directory was made, in allocated core-hours. Either
# is left empty when it cannot be read.
record_run_history() {
    local outcome="$1" pipeline samples started since cpu gb="" cpu_hours=""

    pipeline=$(state_get manifest.pipeline)
    samples=$(state_get samples.count)

    if [[ -d raw-sequences ]]; then
        gb=$(find -L raw-sequences -type f -printf '%s\n' 2>/dev/null \
            | awk '{ total += $1 } END { printf "%.3f", total / 1e9 }')
    fi

    # sacct reads its window in local time; the run recorded when it began in UTC
    started=$(state_get created_utc)
    if [[ -z "$started" ]] || ! since=$(date -d "$started" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null); then
        since="now-7days"
    fi

    if cpu=$(run_cpu_seconds "$since") && [[ "$cpu" =~ ^[0-9]+$ ]]; then
        cpu_hours=$(awk -v s="$cpu" 'BEGIN { printf "%.2f", s / 3600 }')
    fi

    {
        if command -v flock > /dev/null 2>&1; then
            flock 9 || true
        fi

        if [[ ! -s "$RUN_HISTORY" ]]; then
            printf 'finished_utc\trun_id\tpipeline\toutcome\tsamples\tfastq_gb\tcpu_hours\n' >&9
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            "$RUN_ID" "$pipeline" "$outcome" "$samples" "$gb" "$cpu_hours" >&9
    } 9>>"$RUN_HISTORY"
}

# One KEY=value out of a record scontrol -o prints, or nothing
slurm_field() {
    local pattern=" $2=([^ ]*) "

    if [[ " $1 " =~ $pattern ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# How the job that ran the pipeline ended, as Slurm recorded it. HEAD_JOB_STATE
# is COMPLETED, FAILED, TIMEOUT, CANCELLED, OUT_OF_MEMORY, NODE_FAIL, PREEMPTED
# or the like, and HEAD_JOB_BY who cancelled it. HEAD_JOB_LIMIT, HEAD_JOB_END,
# HEAD_JOB_EXIT ("<code>:<signal>"), HEAD_JOB_MEMORY and HEAD_JOB_NODE are its
# time limit, when it ended, its exit status, the memory it was given and the
# node it ran on, as Slurm prints them.
#
# The accounting database is asked first, since only it records who cancelled
# a job, then slurmctld, which keeps a job for a few minutes after it ends, for
# when the database has not caught up. Returns 1 when neither can say.
HEAD_JOB_STATE="" HEAD_JOB_BY="" HEAD_JOB_LIMIT="" HEAD_JOB_END=""
HEAD_JOB_EXIT="" HEAD_JOB_MEMORY="" HEAD_JOB_NODE=""

read_head_job() {
    local job_id record uid

    job_id=$(state_get slurm.job_id)
    [[ "$job_id" =~ ^[0-9]+$ ]] || return 1

    if command -v sacct > /dev/null 2>&1; then
        IFS='|' read -r HEAD_JOB_STATE HEAD_JOB_LIMIT HEAD_JOB_END HEAD_JOB_EXIT \
                HEAD_JOB_MEMORY HEAD_JOB_NODE \
            < <(sacct -j "$job_id" --allocations --noheader --parsable2 \
                --format=State,Timelimit,End,ExitCode,ReqMem,NodeList 2>/dev/null) || true

        if [[ "$HEAD_JOB_STATE" =~ ^CANCELLED\ by\ ([0-9]+)$ ]]; then
            uid=${BASH_REMATCH[1]}
            HEAD_JOB_STATE="CANCELLED"
            HEAD_JOB_BY=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1) || HEAD_JOB_BY=""
            : "${HEAD_JOB_BY:=user $uid}"
        fi
    fi

    if [[ -z "$HEAD_JOB_STATE" || "$HEAD_JOB_STATE" =~ ^(PENDING|RUNNING|REQUEUED|SUSPENDED|COMPLETING)$ ]]; then
        record=$(scontrol show job -o "$job_id" 2>/dev/null) || record=""

        HEAD_JOB_STATE=$(slurm_field "$record" JobState)
        HEAD_JOB_LIMIT=$(slurm_field "$record" TimeLimit)
        HEAD_JOB_END=$(slurm_field "$record" EndTime)
        HEAD_JOB_EXIT=$(slurm_field "$record" ExitCode)
        HEAD_JOB_NODE=$(slurm_field "$record" BatchHost)
        HEAD_JOB_MEMORY=$(slurm_field "$record" ReqTRES)
        HEAD_JOB_BY=""

        # cpu=2,mem=8G,node=1
        if [[ "$HEAD_JOB_MEMORY" =~ (^|,)mem=([^,]+) ]]; then
            HEAD_JOB_MEMORY=${BASH_REMATCH[2]}
        else
            HEAD_JOB_MEMORY=""
        fi
    fi

    [[ -n "$HEAD_JOB_STATE" ]]
}

# Memory as Slurm prints it - "8G", or "8Gn" per node from an older sacct - as
# "8 GB". Prints nothing for anything else.
slurm_memory() {
    if [[ "$1" =~ ^([0-9.]+)([KMGTP])[nc]?$ ]]; then
        printf '%s %sB' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
}

# A Slurm duration - [days-]hours:minutes:seconds - in hours, to one decimal
# place where it is not whole. Prints nothing for one such as UNLIMITED.
slurm_hours() {
    LC_ALL=C awk -v t="$1" 'BEGIN {
        days = 0

        if (i = index(t, "-")) {
            days = substr(t, 1, i - 1)
            t = substr(t, i + 1)
        }

        if (split(t, part, ":") != 3) exit 1

        hours = days * 24 + part[1] + part[2] / 60 + part[3] / 3600
        format = (hours == int(hours)) ? "%d" : "%.1f"

        printf format, hours
    }'
}

# What nextflow had running when the job ended, from the list of submitted tasks
# it logs every five minutes while there are any: each running task as "<name>,
# for <duration>", measured to the end given in epoch seconds, then how many
# more were waiting to start, joined by "; ". A task logged as finished after the
# last list is left out.
tasks_left_running() {
    local end="$1"

    [[ -r nextflow.log ]] || return 0

    LC_ALL=C awk -v end="$end" '
        function field(line, key,    value) {
            value = line

            if (!sub(".*[; ]" key ": ", "", value)) return ""
            sub(/;.*/, "", value)

            return value
        }

        /tasks to be completed:/ {
            running = 0
            waiting = 0
            split("", finished)
            next
        }

        /^~> TaskHandler\[/ {
            status = field($0, "status")

            if (status == "RUNNING") {
                running++
                name[running] = field($0, "name")
                started[running] = field($0, "started")
            } else if (status == "SUBMITTED") {
                waiting++
            }

            next
        }

        /Task completed > TaskHandler\[/ { finished[field($0, "name")] = 1 }

        END {
            listed = 0

            for (i = 1; i <= running; i++) {
                if (name[i] in finished) continue

                text = name[i]

                if (started[i] ~ /^[0-9]+$/) {
                    minutes = int((end - started[i] / 1000) / 60 + 0.5)

                    if (minutes >= 90)
                        text = text sprintf(", for %d hours", int(minutes / 60 + 0.5))
                    else if (minutes >= 0)
                        text = text sprintf(", for %d minutes", minutes)
                }

                out = out (listed++ ? "; " : "") text
            }

            if (waiting) {
                out = out (listed ? "; " waiting " more" : waiting) \
                      (waiting == 1 ? " task" : " tasks") " waiting to start"
            }

            printf "%s", out
        }
    ' nextflow.log
}

# The account of a run whose job Slurm ended, from how it ended, as its
# ".message" and the line under its name on the page: what stopped it, how far
# the run had got, and what nextflow still had running if that is where it was.
# Sets OUTCOME and the first line of REPLY to match.
#
# A job that failed on its own explains itself through fail; one that left no
# message gets its exit status instead. A job that ended any other way is left
# as the error REPLY already calls it.
explain_job_end() {
    local hours memory end tasks="" message stage

    case "$HEAD_JOB_STATE" in
        TIMEOUT)
            hours=$(slurm_hours "$HEAD_JOB_LIMIT") || hours=""

            OUTCOME="Timeout"
            REPLY="This run ran out of time."
            message="The cluster stopped this run when it reached its${hours:+ $hours-hour} time limit"
            stage="Stopped at the cluster's${hours:+ $hours-hour} time limit."
            ;;
        OUT_OF_MEMORY)
            memory=$(slurm_memory "$HEAD_JOB_MEMORY")

            OUTCOME="OutOfMemory"
            REPLY="This run ran out of memory."
            message="The cluster stopped this run when the job coordinating it went over its${memory:+ $memory of} memory"
            stage="Stopped for running out of memory."
            ;;
        CANCELLED)
            OUTCOME="Cancelled"
            REPLY="This run was cancelled."
            message="This run was cancelled on the cluster${HEAD_JOB_BY:+ by $HEAD_JOB_BY}"
            stage="Cancelled on the cluster."
            ;;
        NODE_FAIL|BOOT_FAIL)
            OUTCOME="NodeFail"
            REPLY="This run was stopped by a failure on the cluster."
            message="The cluster node running this run${HEAD_JOB_NODE:+ ($HEAD_JOB_NODE)} failed"
            stage="Stopped by a cluster node failure."
            ;;
        PREEMPTED)
            OUTCOME="Preempted"
            REPLY="This run was stopped to make room for other work on the cluster."
            message="The cluster stopped this run to make room for higher-priority work"
            stage="Preempted on the cluster."
            ;;
        FAILED)
            if [[ -z "$(state_get message)" && "$HEAD_JOB_EXIT" =~ ^([0-9]+):([0-9]+)$ ]]; then
                if (( BASH_REMATCH[2] > 0 )); then
                    message="The job running the pipeline was killed by signal ${BASH_REMATCH[2]}"
                else
                    message="The job running the pipeline exited with status ${BASH_REMATCH[1]}"
                fi

                state_set message "$message without explaining why." || true
            fi

            return 0
            ;;
        *)
            return 0
            ;;
    esac

    if [[ -z "$HEAD_JOB_END" ]] || ! end=$(date -d "$HEAD_JOB_END" +%s 2>/dev/null); then
        end=$(date +%s)
    fi

    if [[ "$STATUS" == "Running" ]]; then
        tasks=$(tasks_left_running "$end") || tasks=""
    fi

    message+=", while the pipeline was ${STATUS,,}."

    if [[ -n "$tasks" ]]; then
        message+=" Still running at the time: $tasks."
    fi

    state_set message "$message" || true
    set_run_stage "$stage"
}

# No recorded status means wrike_job.sh died before its first progress update
STATUS=$(get_run_status)
: "${STATUS:=Starting}"

if [[ "$STATUS" == "Completed" ]]; then
    set_wrike_status "Completed"

    RESULTS_URL=$(run_results_url "$RUN_ID")
    
    add_wrike_comment "Complete: $RESULTS_URL"

    # The last word on the run, published beside its results before the working
    # copy goes with the directory. Every earlier state reached S3 through
    # nextflow_progress.sh, but nothing publishes a page after a run succeeds -
    # the dashboard has already replaced it.
    publish_run_state "$RUN_ID" \
        || warn "Could not publish the final $RUN_STATE_FILE for run $RUN_ID."

    # Before the directory goes, since the FASTQ it measures is staged in it
    record_run_history Completed \
        || warn "Could not add run $RUN_ID to $RUN_HISTORY."

    # Results are already in S3; the working files are no longer needed
    cd /
    rm -rf "$RUN_DIR"

    exit 0
fi

set_run_status "Failed" || true
set_wrike_status "Failed"

# ${STATUS,,} lowercases, e.g. "...while the pipeline was pre-processing."
OUTCOME="Failed"
REPLY="An error occurred while the pipeline was ${STATUS,,}."

# Before the page below is published, which shows the message and the stage
if read_head_job; then
    explain_job_end
fi

# Tasks a killed nextflow left queued or running, which would otherwise hold
# their nodes until their own time limits
ORPHANS=$(cancel_run_tasks "$PWD") || ORPHANS=""

if [[ -n "$ORPHANS" ]]; then
    log "Cancelled the jobs run $RUN_ID left behind:"$'\n'"$ORPHANS"

    # "nf-HUMANN_PROFILE_(4271)" back to "HUMANN_PROFILE (4271)"
    MESSAGE=$(state_get message)
    MESSAGE+="${MESSAGE:+ }$(printf '%s\n' "$ORPHANS" | LC_ALL=C awk -F'\t' '
        {
            sub(/^nf-/, "", $2)
            sub(/_\(/, " (", $2)
            names = names (NR > 1 ? ", " : "") $2
        }
        END {
            if (NR == 1) printf "The task this run left on the cluster was cancelled: %s.", names
            else printf "The %d tasks this run left on the cluster were cancelled: %s.", NR, names
        }')"

    state_set message "$MESSAGE" || true
fi

record_run_history "$OUTCOME" \
    || warn "Could not add run $RUN_ID to $RUN_HISTORY."

# Leave the results page saying so, with the logs on it. wrike_job.sh publishes
# one itself when nextflow is what failed, but every other way a run ends -
# a stage before nextflow, a job the scheduler killed, a job that never started
# - stops its progress watcher without a word, leaving the page frozen mid-run.
# This is the one place that runs whatever happened. Best-effort, as ever: the
# outcome still has to reach Wrike below.
"$NEXTFLOW_DIR/scripts/nextflow_progress.sh" "Failed" || true

REPLY+="$(run_report)"
REPLY+=$'\n'"See $PWD for details."

add_wrike_comment "$REPLY"

# A bare exit rather than fail: the failure is the pipeline's, and fail would
# overwrite the state file's ".message" with its own text, destroying the
# explanation kept here for inspection.
exit 1
