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
# The pipeline script in pipelines/ sets NEXTFLOW_ARGS, PIPELINE_NAME,
# PARAMS_FILE, the parameter defaults, and the optional PRE_PROCESS_CMDS and
# POST_PROCESS_CMDS. Each versioned pipeline pins its own nextflow arguments as
# well as its parameters.
#
# The params file is written here rather than by the pipeline, and after the
# pre-process stage, so that a step which measures the data - such as
# ampliseq_detect_region.sh - can contribute parameters of its own. Three layers
# are merged, each overwriting only the keys it names:
#
#   the pipeline's defaults - which include whatever it makes of the request
#   form's answers - then detected_params.yaml, then a rerun's recorded parameters
#
# and then anything in PARAMS_LOCKED is put back, since those name files the run
# itself creates.
#
# Given a third argument, this run reproduces an earlier one: rerun_manifest.json
# is that run's own pipeline_manifest.json, and its nextflow arguments and
# parameters replace what the pipeline file would have used.
#
# Two records are written before nextflow starts and copied into the published
# results afterwards:
#
#   nextflow_command.sh     the fully expanded command, which is then executed,
#                           so the record cannot drift from what ran
#   pipeline_manifest.json  the pipeline, its nextflow arguments, and every
#                           parameter - what a later rerun is rebuilt from
#
# Never comments on the Wrike task itself: progress goes to ./status.txt, any
# user-facing explanation to ./message.out (what fail writes to), and anything a
# stage wants reported on success to ./notes.txt - all of which wrike_followup.sh
# reads once this job ends, however it ends.
#
# --output and --error name the same file, so this job's commentary and anything
# nextflow writes to stderr interleave in one log/job_<uid>_<jobid>.out.
#
# Usage:     sbatch --chdir=<run_dir> --job-name=nf-<uid> \
#                wrike_job.sh <PIPELINE_NAME> <WRIKE_ATTACHMENT_ID> [<RERUN_UID>]
# Called by: wrike_task_handler.sh
# Sources:   pipelines/<PIPELINE_NAME>.sh
# Runs:      scripts/nextflow_progress.sh, backgrounded from the first stage to
#            the end of the nextflow one, and once more before post-processing
# Requires:  nextflow (as $NEXTFLOW_DIR/bin/nextflow), curl and jq (via the
#            Wrike helpers)
# Env:       NEXTFLOW_DIR, the Wrike helper functions, the params helpers, and
#            the fail/read_wrike_task_id helpers, all sourced from .env

set -euo pipefail

source /data/prod/nextflow/.env

if [[ $# -lt 2 || $# -gt 3 ]]; then
    fail "Usage: $0 <PIPELINE_NAME> <WRIKE_ATTACHMENT_ID> [<RERUN_UID>]"
fi

PIPELINE_UPPER="$1"
ATTACHMENT_ID="$2"

# Read by ampliseq_detect_region.sh, which stands down when a rerun has already
# fixed the parameters it would otherwise measure
export PIPELINE_RERUN_UID="${3:-}"

readonly RERUN_MANIFEST="rerun_manifest.json"
readonly RUN_MANIFEST="pipeline_manifest.json"
readonly DETECTED_PARAMS="detected_params.yaml"
readonly RERUN_PARAMS="rerun_params.yaml"

# The run directory is named after the uid, which says nothing about which Wrike
# task it came from - that is recorded in the directory instead. The Wrike
# helpers all read TASK_ID from the environment.
if ! TASK_ID=$(read_wrike_task_id); then
    fail "Cannot tell which Wrike task this run belongs to."
fi

update_wrike_pipeline_progress "Initializing"
report_stage "Getting your run ready."

# Publish a progress page for the length of the run, from here rather than from
# the nextflow stage: staging a few hundred FASTQ files takes long enough that a
# reader opening the link deserves to be told that is what is happening.
# Backgrounded and cosmetic; the loop reports its own trouble and keeps going.
"$NEXTFLOW_DIR/scripts/nextflow_progress.sh" --watch &
PROGRESS_PID=$!

# Stop it however this script ends - including when Slurm cancels the job - so
# no orphan keeps publishing over a finished run's report.
trap 'kill "$PROGRESS_PID" 2>/dev/null || true' EXIT

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

# Declared before sourcing so a pipeline that forgets to set one is reported
# below rather than tripping set -u
NEXTFLOW_ARGS=()
PRE_PROCESS_CMDS=()
POST_PROCESS_CMDS=()
PARAMS_LOCKED=()
PARAMS_FILE=""
params_reset

source "$PIPELINE_SCRIPT"

# The versioned script the pipeline resolved to, e.g. "AMPLISEQ_01" for a request
# that asked for "AMPLISEQ". A rerun sources this rather than the shortcut, so it
# reproduces the version that ran rather than whatever is current.
PIPELINE_VERSION=${PIPELINE_NAME:-$PIPELINE_UPPER}
PIPELINE_VERSION=${PIPELINE_VERSION^^}

if [[ ! -f "$NEXTFLOW_DIR/pipelines/$PIPELINE_VERSION.sh" ]]; then
    PIPELINE_VERSION="$PIPELINE_UPPER"
fi

update_wrike_custom_field "$WRIKE_PIPELINE_NAME_CFID" "$PIPELINE_VERSION" \
    || warn "Could not set the pipeline name on task $TASK_ID."

# 3. A rerun takes its command line and its params file from the run it
#    reproduces; only the samples are this run's own.
if [[ -n "$PIPELINE_RERUN_UID" ]]; then
    [[ -r "$RERUN_MANIFEST" ]] \
        || fail "Run $PIPELINE_RERUN_UID cannot be reproduced: its record was not downloaded."

    if ! RECORDED_ARGS=$(jq -er '.nextflow_args[]' "$RERUN_MANIFEST"); then
        fail "Run $PIPELINE_RERUN_UID cannot be reproduced: its record has no nextflow arguments."
    fi

    mapfile -t NEXTFLOW_ARGS <<< "$RECORDED_ARGS"

    PARAMS_FILE=$(jq -r '.params_file // empty' "$RERUN_MANIFEST")

    # Written as a layer rather than applied directly, so it lands in the same
    # order as every other override and is published with the rest of the run
    jq -r '.params // {} | to_entries[] | "\(.key): \(.value | tostring | @json)"' \
        "$RERUN_MANIFEST" > "$RERUN_PARAMS"

    log "Reproducing run $PIPELINE_RERUN_UID with $PIPELINE_VERSION."
fi

# 4. Pre-process, e.g. converting the samplesheet to the format nextflow expects
#    and measuring what was sequenced. Unquoted: a pipeline may set a command
#    plus its arguments. They name it by absolute path, so nothing here depends
#    on PATH.
if [[ ${#PRE_PROCESS_CMDS[@]} -gt 0 ]]; then
    update_wrike_pipeline_progress "Pre-Processing"
    report_stage "Preparing your sequencing files."

    for stage_command in "${PRE_PROCESS_CMDS[@]}"; do
        $stage_command
    done
fi

# 5. Build the params file, if this pipeline has one. Each layer overwrites only
#    the keys it names.
if [[ -n "$PARAMS_FILE" ]]; then
    declare -A LOCKED_VALUES=()
    for key in ${PARAMS_LOCKED[@]+"${PARAMS_LOCKED[@]}"}; do
        LOCKED_VALUES["$key"]=$(params_get "$key")
    done

    for layer in "$DETECTED_PARAMS" "$RERUN_PARAMS"; do
        [[ -r "$layer" ]] || continue

        log "Applying the parameters in $layer..."
        params_load "$layer"
    done

    for key in "${!LOCKED_VALUES[@]}"; do
        if [[ "$(params_get "$key")" != "${LOCKED_VALUES[$key]}" ]]; then
            warn "\"$key\" is set by the pipeline and cannot be overridden;" \
                 "restoring \"${LOCKED_VALUES[$key]}\"."
            params_set "$key" "${LOCKED_VALUES[$key]}"
        fi
    done

    params_write "$PARAMS_FILE"
fi

# 6. Run nextflow. NEXTFLOW_ARGS is a bash array, so the arguments arrive already
#    split and need no parsing here.
if [[ ${#NEXTFLOW_ARGS[@]} -eq 0 ]]; then
    fail "Pipeline $PIPELINE_UPPER did not define NEXTFLOW_ARGS."
fi

# Everything needed to run this again: the pipeline version, its command line,
# and every parameter as resolved. wrike_task_handler.sh reads this back off S3
# when a later request asks to reproduce this run.
#
# The sample count rides along because this file outlives the results:
# wrike_expiration.sh reads it for the page it leaves where an expired dashboard
# was, long after sample_count.txt went with the run directory.
jq -n \
    --argjson schema 1 \
    --arg run_id "${PWD##*/}" \
    --arg wrike_task_id "$TASK_ID" \
    --arg recorded_utc "$(date -u "+%Y-%m-%dT%H:%M:%SZ")" \
    --arg pipeline "$PIPELINE_VERSION" \
    --arg pipeline_name "${PIPELINE_NAME:-$PIPELINE_UPPER}" \
    --arg params_file "$PARAMS_FILE" \
    --arg rerun_of "$PIPELINE_RERUN_UID" \
    --arg region "$([[ -r region.txt ]] && head -1 region.txt || true)" \
    --arg retention "$(form_answer retention)" \
    --arg sample_count "$([[ -r sample_count.txt ]] && head -1 sample_count.txt || true)" \
    --argjson nextflow_args "$(printf '%s\n' "${NEXTFLOW_ARGS[@]}" \
        | jq -R -s 'split("\n") | map(select(length > 0))')" \
    --argjson params "$(params_json)" \
    '{schema: $schema, run_id: $run_id, wrike_task_id: $wrike_task_id,
      recorded_utc: $recorded_utc, pipeline: $pipeline, pipeline_name: $pipeline_name,
      params_file: $params_file, nextflow_args: $nextflow_args, params: $params}
     | if $region       != "" then . + {region: $region}             else . end
     | if $retention    != "" then . + {retention: $retention}       else . end
     | if $rerun_of != "" then . + {rerun_of: $rerun_of} else . end
     | if ($sample_count | test("^[0-9]+$"))
       then . + {sample_count: ($sample_count | tonumber)} else . end' \
    > "$RUN_MANIFEST"

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
report_stage "Running the analysis."

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

# Ship the records alongside the results, since the run directory is deleted once
# the run succeeds. pipeline_manifest.json in particular has to reach S3: it is
# the only thing a later rerun of this run can be rebuilt from. Best-effort - a
# pipeline that publishes somewhere other than results/ keeps its records in the
# run directory.
if [[ -d results ]]; then
    cp nextflow_command.sh "$RUN_MANIFEST" results/ 2>/dev/null || true
    cp ./*.yaml region_detection.txt results/ 2>/dev/null || true
fi

# 7. Post-process, e.g. uploading results to S3. Unquoted for the same reason as above.
if [[ ${#POST_PROCESS_CMDS[@]} -gt 0 ]]; then
    update_wrike_pipeline_progress "Post-Processing"
    report_stage "Packaging and publishing your results."

    # One last page, by hand: the watcher was stopped above because the upload
    # below lands the finished dashboard on the same key, and a loop still
    # running would publish over it.
    "$NEXTFLOW_DIR/scripts/nextflow_progress.sh" "Post-Processing" || true

    for stage_command in "${POST_PROCESS_CMDS[@]}"; do
        $stage_command
    done
fi

# The success signal wrike_followup.sh checks, reached only when every stage above
# succeeded. Any earlier exit leaves status.txt on the stage that failed.
echo "Completed" > status.txt
exit 0
