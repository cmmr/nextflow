#!/bin/bash
#SBATCH --job-name=wrike_job
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=48:00:00
#SBATCH --output=/data/prod/nextflow/log/job_%x_%j.out
#SBATCH --error=/data/prod/nextflow/log/job_%x_%j.out
#
# wrike_job.sh - Run one requested pipeline end to end on the cluster.
#
# Author: Daniel Smith
# Date:   August 12th, 2026
#
# Submitted by wrike_task_handler.sh with --job-name set to the run's uid and
# --chdir set to that run's directory. Downloads the samplesheet, sources the
# requested pipeline definition, and runs its pre-process / nextflow /
# post-process stages, reporting progress to Wrike as it goes.
#
# The pipeline script in pipelines/ writes its params file and sets NEXTFLOW_ARGS,
# PIPELINE_NAME, and the optional PRE_PROCESS_CMD and POST_PROCESS_CMD. Each
# versioned pipeline pins its own nextflow arguments as well as its params.
#
# The assembled command is written to ./nextflow_command.sh and then executed, so
# running the pipeline also leaves an exact, re-runnable record of it. Its console
# output is teed to ./nextflow.out, which nextflow_progress.sh reads to publish a
# live progress page for as long as the run lasts.
#
# Never comments on the Wrike task itself: progress goes to ./status.txt and any
# user-facing explanation to ./message.out (what fail writes to), both of which
# wrike_followup.sh reads once this job ends, however it ends.
#
# --output and --error name the same file, so this job's commentary and anything
# nextflow writes to stderr interleave in one log/job_<uid>_<jobid>.out.
#
# Usage:     sbatch --chdir=<run_dir> --job-name=nf-<uid> --nodelist=<node> \
#                wrike_job.sh <PIPELINE_NAME> <WRIKE_ATTACHMENT_ID>
# Called by: wrike_task_handler.sh
# Sources:   pipelines/<PIPELINE_NAME>.sh
# Runs:      scripts/nextflow_progress.sh, backgrounded during the nextflow stage
# Requires:  nextflow (as $NEXTFLOW_DIR/bin/nextflow), curl and jq (via the
#            Wrike helpers)
# Env:       NEXTFLOW_DIR, WRIKE_PIPELINE_NAME_CFID, the Wrike helper functions
#            and the fail/read_wrike_task_id helpers, all sourced from .env

set -euo pipefail

source /data/prod/nextflow/.env

if [[ $# -ne 2 ]]; then
    fail "Usage: $0 <PIPELINE_NAME> <WRIKE_ATTACHMENT_ID>"
fi

PIPELINE_UPPER="$1"
ATTACHMENT_ID="$2"

# The run directory is named after the uid, which says nothing about which Wrike
# task it came from - that is recorded in the directory instead. The Wrike
# helpers all read TASK_ID from the environment.
if ! TASK_ID=$(read_wrike_task_id); then
    fail "Cannot tell which Wrike task this run belongs to."
fi

update_wrike_pipeline_progress "Initializing"

# 1. Fetch the samplesheet attached to the requesting task.
#    -L follows Wrike's redirect to the actual storage backend.
call_wrike_api GET "attachments/$ATTACHMENT_ID/download" -L -o "original_samplesheet.tsv"

if [[ ! -s "original_samplesheet.tsv" ]]; then
    fail "The downloaded samplesheet is empty."
fi

# 2. Load the pipeline definition. The name was validated at submission, so a
#    miss here means the pipeline was removed since.
PIPELINE_SCRIPT="$NEXTFLOW_DIR/pipelines/$PIPELINE_UPPER.sh"
if [[ ! -f "$PIPELINE_SCRIPT" ]]; then
    fail "Pipeline script not found: $PIPELINE_SCRIPT"
fi

# Declared before sourcing so a pipeline that forgets to set it is reported
# below rather than tripping set -u
NEXTFLOW_ARGS=()
source "$PIPELINE_SCRIPT"

# Record the exact pipeline version that ran, e.g. "16Sv4_01" rather than "16SV4"
update_wrike_custom_field "$WRIKE_PIPELINE_NAME_CFID" "${PIPELINE_NAME:-$PIPELINE_UPPER}"

# 3. Pre-process, e.g. converting the samplesheet to the format nextflow expects.
#    Unquoted: pipelines may set a command plus its arguments. They name it by
#    absolute path, so nothing here depends on PATH.
if [[ -n "${PRE_PROCESS_CMD:-}" ]]; then
    update_wrike_pipeline_progress "Pre-Processing"
    $PRE_PROCESS_CMD
fi

# 4. Run nextflow. NEXTFLOW_ARGS is a bash array, so the arguments arrive already
#    split and need no parsing here.
if [[ ${#NEXTFLOW_ARGS[@]} -eq 0 ]]; then
    fail "Pipeline $PIPELINE_UPPER did not define NEXTFLOW_ARGS."
fi

# Write the resolved command to a script and execute that, rather than running
# nextflow directly, so the record can never drift from what was actually run.
# %q quotes only what needs it, keeping the file readable. nextflow by absolute
# path, so the record names the exact executable that produced the results.
{
    printf '#!/bin/bash\n'
    printf '# %s, Wrike task %s, recorded %s\n' "${PIPELINE_NAME:-$PIPELINE_UPPER}" "$TASK_ID" "$(date)"
    printf '%q' "$NEXTFLOW_DIR/bin/nextflow"
    printf ' %q' "${NEXTFLOW_ARGS[@]}"
    printf '\n'
} > nextflow_command.sh
chmod +x nextflow_command.sh

update_wrike_pipeline_progress "Running"

# Publish a progress page for the length of the run. Backgrounded and cosmetic;
# the loop reports its own trouble and keeps going.
"$NEXTFLOW_DIR/scripts/nextflow_progress.sh" --watch &
PROGRESS_PID=$!

# Stop it however this script ends - including when Slurm cancels the job - so
# no orphan keeps publishing over a finished run's report.
trap 'kill "$PROGRESS_PID" 2>/dev/null || true' EXIT

# Teed because nextflow's console output is the only live account it gives of its
# own progress, and nextflow_progress.sh reads it from nextflow.out. It still
# reaches the Slurm log. Under pipefail the pipeline's status is nextflow's own.
if ! ./nextflow_command.sh 2>&1 | tee nextflow.out; then
    # Leave a page saying so, rather than one frozen mid-run
    kill "$PROGRESS_PID" 2>/dev/null || true
    "$NEXTFLOW_DIR/scripts/nextflow_progress.sh" "Failed" || true

    fail "The Nextflow pipeline failed during execution."
fi

kill "$PROGRESS_PID" 2>/dev/null || true
trap - EXIT

# Ship the record and any params files alongside the results, since the run
# directory is deleted once the run succeeds. Best-effort: a pipeline that
# publishes somewhere other than results/ keeps its record in the run directory.
cp nextflow_command.sh *.yaml results/ 2>/dev/null || true

# 5. Post-process, e.g. uploading results to S3. Unquoted for the same reason as above.
if [[ -n "${POST_PROCESS_CMD:-}" ]]; then
    update_wrike_pipeline_progress "Post-Processing"
    $POST_PROCESS_CMD
fi

# The success signal wrike_followup.sh checks, reached only when every stage above
# succeeded. Any earlier exit leaves status.txt on the stage that failed.
echo "Completed" > status.txt
exit 0
