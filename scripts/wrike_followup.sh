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
# share --job-name and --chdir, so the run's state is read straight out of the
# working directory:
#
#   status.txt   the last stage wrike_job.sh reached; "Completed" only on success
#   message.out  optional user-facing explanation, left by fail wherever the run
#                went wrong
#   notes.txt    anything a stage wanted reported whether or not the run failed,
#                such as the 16S region ampliseq_detect_region.sh measured
#
# A successful run has already published to S3, so its run directory is removed.
# A failed one is kept for inspection.
#
# --output and --error name the same file, so both streams land in one
# log/followup_<uid>_<jobid>.out.
#
# Usage:     sbatch --chdir=<run_dir> --job-name=<uid> \
#                --dependency=afterany:<job_id> wrike_followup.sh
# Called by: wrike_task_handler.sh
# Requires:  curl and jq (via the Wrike helpers)
# Env:       NEXTFLOW_DIR and the Wrike helper functions, sourced from .env
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

# Missing status.txt means wrike_job.sh died before its first progress update
if [[ -r "status.txt" ]]; then
    STATUS=$(<status.txt)
else
    STATUS="Starting"
fi

if [[ "$STATUS" == "Completed" ]]; then
    update_wrike_pipeline_progress "Completed"

    REPLY="The pipeline completed successfully."
    if [[ -s "notes.txt" ]]; then
        REPLY+=$'\n'"$(<notes.txt)"
    fi
    if [[ -s "message.out" ]]; then
        REPLY+=$'\n'"$(<message.out)"
    fi

    # Results are already in S3; the working files are no longer needed
    cd /
    rm -rf "$RUN_DIR"

    add_wrike_task_comment "$REPLY"
    exit 0
fi

update_wrike_pipeline_progress "Failed"

# ${STATUS,,} lowercases, e.g. "...while the pipeline was pre-processing."
REPLY="An error occurred while the pipeline was ${STATUS,,}."
if [[ -s "notes.txt" ]]; then
    REPLY+=$'\n'"$(<notes.txt)"
fi
if [[ -s "message.out" ]]; then
    REPLY+=$'\n'"$(<message.out)"
fi
REPLY+=$'\n'"See $PWD for details."

add_wrike_task_comment "$REPLY"

# A bare exit rather than fail: the failure is the pipeline's, and fail would
# overwrite message.out with its own text, destroying the explanation kept here
# for inspection.
exit 1
