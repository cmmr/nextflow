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
# Requires:  curl and jq (via the Wrike helpers); sacct and flock, each optional
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

record_run_history Failed \
    || warn "Could not add run $RUN_ID to $RUN_HISTORY."

# Leave the results page saying so, with the logs on it. wrike_job.sh publishes
# one itself when nextflow is what failed, but every other way a run ends -
# a stage before nextflow, a job the scheduler killed, a job that never started
# - stops its progress watcher without a word, leaving the page frozen mid-run.
# This is the one place that runs whatever happened. Best-effort, as ever: the
# outcome still has to reach Wrike below.
"$NEXTFLOW_DIR/scripts/nextflow_progress.sh" "Failed" || true

# ${STATUS,,} lowercases, e.g. "...while the pipeline was pre-processing."
REPLY="An error occurred while the pipeline was ${STATUS,,}."
REPLY+="$(run_report)"
REPLY+=$'\n'"See $PWD for details."

add_wrike_comment "$REPLY"

# A bare exit rather than fail: the failure is the pipeline's, and fail would
# overwrite the state file's ".message" with its own text, destroying the
# explanation kept here for inspection.
exit 1
