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
# Given a third argument, this run reproduces an earlier one:
# wrike_task_handler.sh has put the manifest that run published under
# "rerun.manifest" in the state file, and its nextflow arguments and parameters
# replace what the pipeline file would have used.
#
# Two records are made before nextflow starts:
#
#   nextflow_command.sh  the fully expanded command, which is then executed, so
#                        the record cannot drift from what ran. Copied into the
#                        published results.
#   the state file's     the pipeline, its nextflow arguments, and every
#   ".manifest"          parameter - what a later rerun is rebuilt from.
#                        nextflow_progress.sh publishes the whole state file to
#                        the run's S3 prefix, which is where a later request
#                        naming this run reads it back from.
#
# Never comments on the Wrike task itself: progress goes to the state file's
# ".status", any user-facing explanation to its ".message" (what fail writes to),
# and anything a stage wants reported on success to its ".notes" - all of which
# wrike_followup.sh reads once this job ends, however it ends.
#
# --output and --error name the same file, so this job's commentary and anything
# nextflow writes to stderr interleave in one log/job_<uid>_<jobid>.out.
#
# Usage:     sbatch --chdir=<run_dir> --job-name=nf-<uid> \
#                wrike_job.sh <PIPELINE_NAME> <WRIKE_ATTACHMENT_ID> [<RERUN_UID>]
# Called by: wrike_task_handler.sh
# Sources:   pipelines/<PIPELINE_NAME>.sh
# Runs:      scripts/nextflow_progress.sh, backgrounded from the first stage to
#            the start of the last, and once more as that one begins
# Requires:  nextflow (as $NEXTFLOW_DIR/bin/nextflow), curl and jq (via the
#            Wrike helpers)
# Env:       NEXTFLOW_DIR, the Wrike helper functions, the params helpers, the
#            run state helpers, and the fail/read_wrike_task_id helpers, all
#            sourced from .env

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

readonly DETECTED_PARAMS="detected_params.yaml"
readonly RERUN_PARAMS="rerun_params.yaml"

# The run directory is named after the uid, which says nothing about which Wrike
# task it came from - that is recorded in the directory instead. The Wrike
# helpers all read TASK_ID from the environment.
if ! TASK_ID=$(read_wrike_task_id); then
    fail "Cannot tell which Wrike task this run belongs to."
fi

set_run_status "Initializing"
set_run_stage "Getting your run ready."

# Publish a progress page for the length of the run, from here rather than from
# the nextflow stage: staging a few hundred FASTQ files takes long enough that a
# reader opening the link deserves to be told that is what is happening.
# Backgrounded and cosmetic; the loop reports its own trouble and keeps going.
"$NEXTFLOW_DIR/scripts/nextflow_progress.sh" --watch &
PROGRESS_PID=$!

# Stop the watcher, and wait for it. It finishes an upload already under way
# before it exits, so once this returns nothing it sent can land on top of
# whatever is published next.
stop_progress() {
    kill "$PROGRESS_PID" 2>/dev/null || return 0
    wait "$PROGRESS_PID" 2>/dev/null || true
}

# Stop it however this script ends - including when Slurm cancels the job - so
# no orphan keeps publishing over a finished run's report.
trap stop_progress EXIT

# The name a pre- or post-process command is listed under on the progress page:
# its script's name less the pipeline's prefix and extension, so
# "$NEXTFLOW_DIR/scripts/taxprofiler_humann.sh" under "taxprofiler_" is "humann".
step_name() {
    local name="${1%% *}"

    name=${name##*/}
    name=${name%.sh}

    printf '%s' "${name#"$2"}"
}

# Every step this run will take, recorded as ".steps" in the order they run for
# the progress page to list: each pre-process command, the nextflow run, then
# each post-process command, all waiting. Sets NEXTFLOW_STEP_INDEX and
# POST_STEP_FIRST, the places the nextflow run and the first post-process
# command take in that list.
#
# A command's console output is "<name>.out", which is where a step that drives
# a nextflow run of its own tees that run, and where the page reads the
# processes it lists under the step. The nextflow run is listed under the
# pipeline it runs, with nextflow.out.
record_steps() {
    local prefix="${PIPELINE_VERSION,,}" pipeline="nextflow" command name steps i

    prefix="${prefix%%_*}_"

    for (( i = 0; i + 1 < ${#NEXTFLOW_ARGS[@]}; i++ )); do
        if [[ "${NEXTFLOW_ARGS[i]}" == run ]]; then
            pipeline="${NEXTFLOW_ARGS[i + 1]}"
            break
        fi
    done

    NEXTFLOW_STEP_INDEX=${#PRE_PROCESS_CMDS[@]}
    POST_STEP_FIRST=$(( NEXTFLOW_STEP_INDEX + 1 ))

    if steps=$(
        {
            for command in ${PRE_PROCESS_CMDS[@]+"${PRE_PROCESS_CMDS[@]}"}; do
                name=$(step_name "$command" "$prefix")
                printf '%s\t%s.out\n' "$name" "$name"
            done

            printf '%s\tnextflow.out\n' "$pipeline"

            for command in ${POST_PROCESS_CMDS[@]+"${POST_PROCESS_CMDS[@]}"}; do
                name=$(step_name "$command" "$prefix")
                printf '%s\t%s.out\n' "$name" "$name"
            done
        } | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
                         | {name: .[0], log: .[1], state: "waiting"})'
    ) && state_set_json steps "$steps"; then
        return 0
    fi

    warn "Could not record this run's steps; the progress page will list nextflow's processes alone."
}

# One step, with its row on the progress page kept up with it: active while it
# runs, then done - or failed, in which case this job ends with the step's own
# status, as it did before there were rows. The command and its arguments
# arrive already split, the way the pipeline file wrote them.
run_step() {
    local index="$1" status=0
    shift

    set_step_state "$index" active
    "$@" || status=$?

    if (( status != 0 )); then
        set_step_state "$index" failed
        exit "$status"
    fi

    set_step_state "$index" done
}

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

set_wrike_custom_field "$WRIKE_PIPELINE_NAME_CFID" "$PIPELINE_VERSION" \
    || warn "Could not set the pipeline name on task $TASK_ID."

# 3. A rerun takes its command line and its params file from the run it
#    reproduces; only the samples are this run's own.
if [[ -n "$PIPELINE_RERUN_UID" ]]; then
    state_has rerun.manifest \
        || fail "Run $PIPELINE_RERUN_UID cannot be reproduced: its record was not downloaded."

    RERUN_MANIFEST=$(state_get_json rerun.manifest)

    if ! RECORDED_ARGS=$(printf '%s' "$RERUN_MANIFEST" | jq -er '.nextflow_args[]'); then
        fail "Run $PIPELINE_RERUN_UID cannot be reproduced: its record has no nextflow arguments."
    fi

    mapfile -t NEXTFLOW_ARGS <<< "$RECORDED_ARGS"

    PARAMS_FILE=$(state_get rerun.manifest.params_file)

    # Written as a layer rather than applied directly, so it lands in the same
    # order as every other override and is published with the rest of the run
    printf '%s' "$RERUN_MANIFEST" \
        | jq -r '.params // {} | to_entries[] | "\(.key): \(.value | tostring | @json)"' \
        > "$RERUN_PARAMS"

    log "Reproducing run $PIPELINE_RERUN_UID with $PIPELINE_VERSION."
fi

# The rows the progress page lists from here on, one per step, all waiting
record_steps

# 4. Pre-process, e.g. converting the samplesheet to the format nextflow expects
#    and measuring what was sequenced. Unquoted: a pipeline may set a command
#    plus its arguments. They name it by absolute path, so nothing here depends
#    on PATH.
if [[ ${#PRE_PROCESS_CMDS[@]} -gt 0 ]]; then
    set_run_status "Pre-Processing"
    set_run_stage "Preparing your sequencing files."

    for (( i = 0; i < ${#PRE_PROCESS_CMDS[@]}; i++ )); do
        run_step "$i" ${PRE_PROCESS_CMDS[i]}
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
# The sample count rides along because the published copy outlives the run
# directory: wrike_expiration.sh reads it for the page it leaves where an
# expired dashboard was.
if ! MANIFEST=$(jq -n \
        --argjson schema 1 \
        --arg run_id "${PWD##*/}" \
        --arg wrike_task_id "$TASK_ID" \
        --arg recorded_utc "$(date -u "+%Y-%m-%dT%H:%M:%SZ")" \
        --arg pipeline "$PIPELINE_VERSION" \
        --arg pipeline_name "${PIPELINE_NAME:-$PIPELINE_UPPER}" \
        --arg params_file "$PARAMS_FILE" \
        --arg rerun_of "$PIPELINE_RERUN_UID" \
        --arg region "$(state_get region)" \
        --arg retention "$(form_answer retention)" \
        --arg sample_count "$(state_get samples.count)" \
        --argjson nextflow_args "$(printf '%s\n' "${NEXTFLOW_ARGS[@]}" \
            | jq -R -s 'split("\n") | map(select(length > 0))')" \
        --argjson params "$(params_json)" \
        '{schema: $schema, run_id: $run_id, wrike_task_id: $wrike_task_id,
          recorded_utc: $recorded_utc, pipeline: $pipeline, pipeline_name: $pipeline_name,
          params_file: $params_file, nextflow_args: $nextflow_args, params: $params}
         | if $region    != "" then . + {region: $region}       else . end
         | if $retention != "" then . + {retention: $retention} else . end
         | if $rerun_of  != "" then . + {rerun_of: $rerun_of}   else . end
         | if ($sample_count | test("^[0-9]+$"))
           then . + {sample_count: ($sample_count | tonumber)} else . end'); then
    fail "Could not record how this run was set up; it could not be reproduced later."
fi

state_set_json manifest "$MANIFEST" \
    || fail "Could not record how this run was set up; it could not be reproduced later."

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

set_run_status "Running"
set_run_stage "Running the analysis."
set_step_state "$NEXTFLOW_STEP_INDEX" active

# Teed because nextflow's console output is the only live account it gives of its
# own progress, and nextflow_progress.sh reads it from nextflow.out. It still
# reaches the Slurm log. Under pipefail the pipeline's status is nextflow's own.
if ! ./nextflow_command.sh 2>&1 | tee nextflow.out; then
    # Leave a page saying so, rather than one frozen mid-run
    set_step_state "$NEXTFLOW_STEP_INDEX" failed
    stop_progress
    "$NEXTFLOW_DIR/scripts/nextflow_progress.sh" "Failed" || true

    fail "The Nextflow pipeline failed during execution."
fi

set_step_state "$NEXTFLOW_STEP_INDEX" done

# Ship the records alongside the results, since the run directory is deleted once
# the run succeeds. The state file is not among them: it is published to the same
# prefix under its own name, by nextflow_progress.sh, and a stale copy uploaded
# with the results would land on top of it. Best-effort - a pipeline that
# publishes somewhere other than results/ keeps its records in the run directory.
if [[ -d results ]]; then
    cp nextflow_command.sh results/ 2>/dev/null || true
    cp ./*.yaml region_detection.txt results/ 2>/dev/null || true
fi

# 7. Post-process, e.g. uploading results to S3. Unquoted for the same reason as above.
#
#    The last step is the one that publishes the finished dashboard, to the key
#    the progress page is published to, so the watcher stops as that step
#    begins - leaving one page that shows it under way - and nothing it sends
#    can land on top of the dashboard.
if [[ ${#POST_PROCESS_CMDS[@]} -gt 0 ]]; then
    set_run_status "Post-Processing"
    set_run_stage "Packaging and publishing your results."

    for (( i = 0; i < ${#POST_PROCESS_CMDS[@]}; i++ )); do
        if (( i == ${#POST_PROCESS_CMDS[@]} - 1 )); then
            stop_progress
            set_step_state $(( POST_STEP_FIRST + i )) active
            "$NEXTFLOW_DIR/scripts/nextflow_progress.sh" "Post-Processing" || true
        fi

        run_step $(( POST_STEP_FIRST + i )) ${POST_PROCESS_CMDS[i]}
    done
fi

stop_progress

# The success signal wrike_followup.sh checks, reached only when every stage
# above succeeded. Any earlier exit leaves the state file's ".status" on the
# stage that failed. The Wrike task is left to wrike_followup.sh, which moves it
# once it has read this.
set_run_status "Completed"
exit 0
