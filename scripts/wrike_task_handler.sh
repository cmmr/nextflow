#!/bin/bash
#
# wrike_task_handler.sh - Validate a new pipeline request and submit it to Slurm.
#
# Author: Daniel Smith
# Date:   August 12th, 2026
#
# wrike_sqs_listener.sh calls this for both kinds of request: the "Bioinformatics
# Pipeline" form creates a task in "Dashboards" (TaskCreated), and the `run`
# script files an already-built task there (TaskParentsAdded). Everything used
# below - task ID, custom field, attachment - is read from Wrike rather than from
# the event, so the two payloads are handled the same way.
#
# Runs on the login node and must stay lightweight; all real work goes to Slurm.
#
# Every validation failure replies on the originating Wrike task and exits 0: a
# rejected request is a normal outcome, not a daemon error.
#
# The run's two homes - its local run directory and the S3 prefix its results
# page is published to - are created before that validation, as soon as the
# request has a uid to name them with. Both last until the Wrike task is deleted;
# the run directory also goes when its job finishes successfully, at which point
# wrike_followup.sh removes it. So a rejected request still has a page saying so
# and a directory to look in, and the results link is on the task from the start.
#
# Every answer on the request form is checked against the list wrike_api.sh
# allows and then written, unaltered, to form_answers.tsv in the run directory.
# Nothing here interprets one: which answers mean anything is a pipeline's
# business, and this script knows no pipeline from another. There is no free-text
# parameter field, so a requester can only ask for what that list offers.
#
# The one answer it does read is "Pipeline", whose options are
# "<name> :: <what it is for>" and whose first word names a file in pipelines/ -
# except "prev_run_id", which instead means the settings come from the run named
# in "Previous Run ID". That run's published pipeline_manifest.json is fetched
# into rerun_manifest.json for wrike_job.sh to rebuild from.
#
# Usage:     wrike_task_handler.sh <sqs_message_body_json>
# Called by: wrike_sqs_listener.sh
# Submits:   wrike_job.sh, then wrike_followup.sh (dependent on the first)
# Runs:      scripts/nextflow_progress.sh, to publish the results page
# Requires:  jq, sbatch/squeue (Slurm), aws, openssl (via derive_uid), curl (via
#            call_wrike_api)
# Env:       NEXTFLOW_DIR, AWS_S3_BUCKET, S3_RUN_PREFIX, RUN_ID_SALT,
#            WRIKE_S3_RESULTS_URL_CFID, WRIKE_FORM_ANSWERS and its helpers, and
#            the log/warn/fail/derive_uid/run_results_url helpers, all from .env

set -euo pipefail

source /data/prod/nextflow/.env

# A form submission's attachment arrives as its own webhook event, so the file
# may not have landed yet. Attempts, and seconds between them.
ATTACHMENT_TRIES=5
ATTACHMENT_WAIT=3

# How much of an answer to quote back to the user when refusing it
ANSWER_ECHO_CHARS=50

if [[ $# -ne 1 ]]; then
    fail "Usage: $0 <sqs_message_body_json>"
fi

MESSAGE_BODY="$1"

# TASK_ID is read by the update_wrike_* and add_wrike_task_comment helpers.
# "// empty" matters: without it jq prints "null" for a missing key, which looks
# like a perfectly good Wrike ID to the check below.
TASK_ID=$(echo "$MESSAGE_BODY" | jq -r '.[0].taskId // empty')

# The uid naming the run directory, the Slurm job, and the S3 prefix is derived
# from TASK_ID, so anything that could not be a Wrike ID is refused here.
if ! is_valid_wrike_id "$TASK_ID"; then
    fail "Malformed or missing taskId in request payload; ignoring."
fi

# Publish the run's results page, which reports whatever status.txt says. Called
# at each point that answer changes. Cosmetic: nothing about the run depends on
# it.
publish_progress_page() {
    "$NEXTFLOW_DIR/scripts/nextflow_progress.sh" \
        || warn "Could not publish the progress page for task $TASK_ID."
}

# Leave the task, and the page published for it, reading "Failed". Before the run
# directory exists there is no status.txt to write and no page to publish, so
# only the task's own status is set.
mark_failed() {
    if [[ "$PWD" == "${RUN_DIR:-}" ]]; then
        update_wrike_pipeline_progress "Failed" || true
        publish_progress_page
    else
        update_wrike_task_status "Failed" || true
    fi
}

# Tell the requester what was wrong with their request, mark it failed, and exit
# 0. Whatever the run created stays behind for the life of the Wrike task.
reject() {
    local reply="$1" reason="$2"

    add_wrike_task_comment "$reply" || true
    mark_failed
    log "Validation failed: $reason"
    exit 0
}

# Apologize on the task, then give up. The SQS message is deleted before
# dispatch, so there is no redelivery: without this the user would watch a task
# that never does anything.
fail_with_apology() {
    local reply="Something went wrong on my end while handling this request."
    reply+=" Please submit a new request to try again."
    add_wrike_task_comment "$reply" || true

    mark_failed

    # Last, because it does not return. Inside a run directory, fail's copy of
    # this message lands in message.out there.
    fail "$* (task $TASK_ID); asked the user to resubmit."
}

# Show the requester their request was picked up, before anything slow.
# update_wrike_task_status rather than the pipeline_progress helper: there is no
# run directory yet for status.txt to live in.
update_wrike_task_status "Validating" || true

# Everything after this point reports back by commenting on the task, so this
# also tells the requester where the answer will show up.
REPLY="Hi! I've picked up your request and am validating it now."
REPLY+=" Watch this task's \"Status\" to follow the job's progress,"
REPLY+=" and I'll comment here as soon as there's anything to report."
add_wrike_task_comment "$REPLY" || true

# 1. Read the task: the request form's answers, and the title, which heads the
#    results page.
if ! TASK_JSON=$(call_wrike_api GET "tasks/$TASK_ID"); then
    fail_with_apology "Could not read the task"
fi

if ! read_wrike_answers "$TASK_JSON"; then
    fail_with_apology "Could not read the request form's custom fields"
fi

#    The "Pipeline" options are "<name> :: <what it is for>", so only the first
#    word names anything. Normalized here so it is checked like every other answer.
read -r PIPELINE_INPUT _ <<< "$(wrike_answer pipeline)"

if [[ -n "$PIPELINE_INPUT" ]]; then
    WRIKE_ANSWERS[pipeline]="$PIPELINE_INPUT"
fi

# One line: the title goes into an HTML header. Best effort - the pages fall back
# to a generic heading.
TASK_NAME=$(echo "$TASK_JSON" | jq -r '.data[0].title // empty') || TASK_NAME=""
TASK_NAME=${TASK_NAME%%$'\n'*}

# 2. Derive the uid this run is known by and create the run directory named after
#    it, which is how wrike_job.sh and wrike_followup.sh know theirs, from their
#    working directory.
#
#    Creating it also guards against running a task twice: SQS delivers at least
#    once, and a redelivered event derives this same directory. Plain mkdir, not
#    mkdir -p, so that an existing directory is an error.
#
#    derive_uid's status is tested explicitly because set -e does not fire on an
#    assignment from a failed command substitution.
if ! RUN_ID=$(derive_uid "$TASK_ID"); then
    fail_with_apology "Could not derive a uid"
fi

RUN_DIR="$NEXTFLOW_DIR/tmp/$RUN_ID"
mkdir -p "$NEXTFLOW_DIR/tmp"

if ! mkdir "$RUN_DIR" 2>/dev/null; then
    log "Ignoring task $TASK_ID: $RUN_DIR already exists, so this request has already been handled."
    exit 0
fi

cd "$RUN_DIR"

# A uid does not lead back to a task, so record the one this run came from.
# Everything on the compute node reads it back through read_wrike_task_id.
echo "$TASK_ID" > "$WRIKE_TASK_ID_FILE"

# The title too, since both published pages are headed with it
printf '%s\n' "$TASK_NAME" > "$WRIKE_TASK_NAME_FILE"

# Open the channel back to the requester: fail writes to message.out wherever it
# exists, so anything that goes wrong from here on - here, in wrike_job.sh, or in
# a pipeline's pre/post-process scripts - reaches the user when wrike_followup.sh
# posts it at the end of the job. notes.txt is the same channel for a run that
# succeeds, which stages append to rather than overwrite.
: > message.out
: > notes.txt

# The run's own record of how far it has got, which the page below reads
echo "Validating" > status.txt

# 3. Claim the S3 prefix. A uid is derived, so it is not unique by construction
#    and has to be checked against what is already published; a collision would
#    mean one client's results overwriting another's. A failed call is not a free
#    prefix, so "cannot tell" is fatal.
if ! S3_LISTING=$(aws s3api list-objects-v2 --bucket "$AWS_S3_BUCKET" \
        --prefix "$S3_RUN_PREFIX/$RUN_ID/" --max-keys 1 2>&1); then
    fail_with_apology "Could not check whether the S3 prefix $S3_RUN_PREFIX/$RUN_ID is free"
fi

if [[ "$(echo "$S3_LISTING" | jq -r '.KeyCount // 0')" -ne 0 ]]; then
    REPLY="Something rare went wrong on my end: the storage location for this"
    REPLY+=" job's results is already taken. Please submit a new request, which"
    REPLY+=" will be given a different one."
    add_wrike_task_comment "$REPLY" || true

    update_wrike_task_status "Failed" || true

    # The one rejection that publishes nothing and removes its run directory:
    # both the prefix and the directory belong to the run that got there first.
    log "Validation failed: uid $RUN_ID (task $TASK_ID) is already in use in S3."
    cd /
    rm -rf "$RUN_DIR"
    exit 0
fi

# Put a page at the prefix, and the address of that page on the task. Both are
# best effort; ampliseq_upload.sh sets the same field again when the results land.
RESULTS_URL=$(run_results_url "$RUN_ID")

publish_progress_page

update_wrike_custom_field "$WRIKE_S3_RESULTS_URL_CFID" "$RESULTS_URL" \
    || warn "Could not set the results URL on task $TASK_ID."

# 4. Check every answer against the list the form offers. These values reach a
#    nextflow command line, so anything not offered is refused rather than
#    passed on. "Previous Run ID" has no list and is checked by shape below.
for ANSWER_KEY in "${!WRIKE_ANSWERS[@]}"; do
    if ! wrike_answer_allowed "$ANSWER_KEY" "${WRIKE_ANSWERS[$ANSWER_KEY]}"; then
        REPLY="I don't recognize \"${WRIKE_ANSWERS[$ANSWER_KEY]:0:$ANSWER_ECHO_CHARS}\""
        REPLY+=" as an answer. Please submit a new request choosing one of:"
        REPLY+=$'\n'"$(wrike_answer_options "$ANSWER_KEY")"
        reject "$REPLY" "Answer to \"$ANSWER_KEY\" is not one the form offers."
    fi
done

# 5. A request naming a previous run reproduces it. That run's manifest decides
#    which pipeline is used, so it is fetched before the name is resolved.
RERUN_UID=""
RERUN_INPUT=$(wrike_answer previous_run)

if [[ "$PIPELINE_INPUT" == "$WRIKE_RERUN_ANSWER" && -z "$RERUN_INPUT" ]]; then
    REPLY="You asked to reuse an earlier run's settings, but didn't say which run."
    REPLY+=" Please submit a new request with its run ID - the eight characters in"
    REPLY+=" its results link, for example the \"$RUN_ID\" in $RESULTS_URL."
    reject "$REPLY" "Rerun requested with no previous run ID."
fi

if [[ "$PIPELINE_INPUT" == "$WRIKE_RERUN_ANSWER" ]]; then
    #    Accepts a uid or the results URL it appears in, since that link is what
    #    the requester was given
    RERUN_UID=${RERUN_INPUT,,}
    RERUN_UID=${RERUN_UID##*"$S3_RUN_PREFIX"/}
    RERUN_UID=${RERUN_UID%%/*}

    if ! is_valid_uid "$RERUN_UID"; then
        REPLY="\"$RERUN_INPUT\" is not a run ID."
        REPLY+=" A run ID is the eight characters in its results link,"
        REPLY+=" for example the \"$RUN_ID\" in $RESULTS_URL."
        REPLY+=" Please submit a new request with that, or with none at all."
        reject "$REPLY" "Malformed previous run ID ($RERUN_INPUT)."
    fi

    #    A run's manifest is written before nextflow starts and published with
    #    its results, so a run that never finished has none
    if ! aws s3 cp "s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/$RERUN_UID/pipeline_manifest.json" \
            "$RUN_DIR/rerun_manifest.json" > /dev/null 2>&1; then
        REPLY="I have no record of how run \"$RERUN_UID\" was set up, so I cannot repeat it."
        REPLY+=" That happens when the run never finished."
        REPLY+=" Please submit a new request naming a different run, or none at all."
        reject "$REPLY" "No pipeline_manifest.json published for run $RERUN_UID."
    fi

    if ! PIPELINE_INPUT=$(jq -er '.pipeline' "$RUN_DIR/rerun_manifest.json"); then
        REPLY="The record of run \"$RERUN_UID\" does not say which pipeline it used,"
        REPLY+=" so I cannot repeat it. Please submit a new request naming a different run,"
        REPLY+=" or none at all."
        reject "$REPLY" "rerun_manifest.json for run $RERUN_UID names no pipeline."
    fi

    log "Task $TASK_ID reproduces run $RERUN_UID, which ran $PIPELINE_INPUT."
fi

#    Resolve the requested name to a script in pipelines/, upper-cased so
#    "ampliseq", "Ampliseq" and "AMPLISEQ" all resolve to pipelines/AMPLISEQ.sh.
PIPELINE_UPPER=${PIPELINE_INPUT^^}
PIPELINE_SCRIPT="$NEXTFLOW_DIR/pipelines/$PIPELINE_UPPER.sh"

# Validated as a name, not merely resolved as a path: wrike_job.sh sources what
# this resolves to, so a "/" or ".." reaching the filesystem would be arbitrary
# code execution rather than just a bad pipeline choice.
if [[ ! "$PIPELINE_UPPER" =~ ^[A-Z0-9_]+$ || ! -f "$PIPELINE_SCRIPT" ]]; then
    # The basenames of every available pipeline, without the .sh suffix
    VALID_PIPELINES=""
    for script in "$NEXTFLOW_DIR"/pipelines/*.sh; do
        script=${script##*/}
        VALID_PIPELINES+="${script%.sh} "
    done

    PIPELINE_SHOWN=${PIPELINE_INPUT:0:$ANSWER_ECHO_CHARS}

    if [[ -n "$RERUN_UID" ]]; then
        REPLY="Run \"$RERUN_UID\" used a pipeline named \"$PIPELINE_SHOWN\","
        REPLY+=" which no longer exists here, so I cannot repeat it."
    elif [[ -z "$PIPELINE_INPUT" ]]; then
        REPLY="You didn't tell me which pipeline to run."
    else
        REPLY="I couldn't find a pipeline named \"$PIPELINE_SHOWN\"."
    fi
    REPLY+=" Please submit a new request with one of the following options:"
    REPLY+=$'\n'"$VALID_PIPELINES"
    reject "$REPLY" "Invalid pipeline requested (${PIPELINE_SHOWN:-none})."
fi

# 6. Leave the checked answers in the run directory. Recorded rather than
#    interpreted: which answers mean anything is a pipeline's business, and
#    nothing here knows one pipeline from another.
for ANSWER_KEY in "${!WRIKE_ANSWERS[@]}"; do
    printf '%s\t%s\n' "$ANSWER_KEY" "${WRIKE_ANSWERS[$ANSWER_KEY]}"
done | sort > "$RUN_DIR/$WRIKE_FORM_ANSWERS_FILE"

# 7. Require exactly one samplesheet on the task. AttachmentAdded is a separate
#    webhook event from the TaskCreated that got us here, and Wrike promises no
#    order, so give the file a few seconds to appear. Requests from `run` attach
#    before filing the task, so for those this loop succeeds on the first attempt.
TRIES_LEFT=$ATTACHMENT_TRIES
while true; do
    # A failed call is worth another attempt for the same reason a missing
    # attachment is; only running out of attempts is fatal.
    if ! ATTACHMENTS_JSON=$(call_wrike_api GET "tasks/$TASK_ID/attachments"); then
        if (( --TRIES_LEFT == 0 )); then
            fail_with_apology "Could not list the task's attachments"
        fi
        sleep "$ATTACHMENT_WAIT"
        continue
    fi

    ATTACHMENT_COUNT=$(echo "$ATTACHMENTS_JSON" | jq '[.data[]?] | length')

    if [[ "$ATTACHMENT_COUNT" -ne 0 ]] || (( --TRIES_LEFT == 0 )); then
        break
    fi
    sleep "$ATTACHMENT_WAIT"
done

if [[ "$ATTACHMENT_COUNT" -ne 1 ]]; then
    REPLY="I need exactly one samplesheet attached to run the $PIPELINE_UPPER pipeline,"
    REPLY+=" but this request has $ATTACHMENT_COUNT."
    REPLY+=" Please submit a new request with a single samplesheet attached."
    reject "$REPLY" "Expected 1 attachment, found $ATTACHMENT_COUNT."
fi

ATTACHMENT_ID=$(echo "$ATTACHMENTS_JSON" | jq -r '.data[0].id')
ATTACHMENT_NAME=$(echo "$ATTACHMENTS_JSON" | jq -r '.data[0].name')

if [[ ! "$ATTACHMENT_NAME" =~ \.(txt|tsv|out)$ ]]; then
    REPLY="I don't recognize the file extension on \"$ATTACHMENT_NAME\"."
    REPLY+=" Please submit a new request with a samplesheet that ends in .txt, .tsv, or .out."
    reject "$REPLY" "Invalid extension on file $ATTACHMENT_NAME."
fi

# 8. Move the task's status on, before submission: the job starts by overwriting it.
if ! update_wrike_pipeline_progress "Queued"; then
    fail_with_apology "Could not set the task's status"
fi

# 9. Submit the job, then a follow-up job that reports the outcome either way.
#    Both are named after the uid so wrike_delete_handler.sh can scancel them,
#    and both run in RUN_DIR. sbatch options must precede the script name.
#
#    Queue depth is cosmetic, so a failing squeue must not take the submission
#    with it.
JOBS_AHEAD=$(squeue -h -t PENDING | wc -l) || JOBS_AHEAD="an unknown number of"

if JOB_ID=$(sbatch --parsable --job-name="nf-$RUN_ID" --chdir="$RUN_DIR" \
        "$NEXTFLOW_DIR/scripts/wrike_job.sh" "$PIPELINE_UPPER" "$ATTACHMENT_ID" "$RERUN_UID"); then

    # afterany, not afterok, so failures are reported to the user too. A
    # follow-up that fails to submit is not fatal - the pipeline is already
    # queued - but it does mean nothing will report the outcome.
    if ! FOLLOWUP_ID=$(sbatch --parsable --job-name="nf-$RUN_ID" --chdir="$RUN_DIR" \
            --dependency=afterany:"$JOB_ID" \
            "$NEXTFLOW_DIR/scripts/wrike_followup.sh"); then
        FOLLOWUP_ID="none"
        warn "Follow-up submission failed for task $TASK_ID; job $JOB_ID will run unreported."
    fi

    # Bring the page up to the "Queued" step 8 just set. nextflow_progress.sh
    # takes over once the pipeline is under way.
    publish_progress_page

    REPLY="Success! Your job for the $PIPELINE_UPPER pipeline was successfully"
    REPLY+=" submitted to the cluster using the attached samplesheet."
    if [[ -n "$RERUN_UID" ]]; then
        REPLY+=" It runs with exactly the settings run $RERUN_UID used."
    fi
    REPLY+=" There are currently $JOBS_AHEAD pending jobs ahead of yours in the queue."
    REPLY+=$'\n\n'"You can follow along here, and this is where your results will"
    REPLY+=" appear once the run finishes:"$'\n'"$RESULTS_URL"
    add_wrike_task_comment "$REPLY"
    log "Job $JOB_ID submitted for task $TASK_ID as uid $RUN_ID, followed by dependent job $FOLLOWUP_ID."
else
    REPLY="Your pipeline name and samplesheet are valid, but there was an error"
    REPLY+=" submitting this job to the cluster. Please submit a new request."
    add_wrike_task_comment "$REPLY" || true

    mark_failed

    # The run directory stays, with fail's explanation in its message.out. No
    # follow-up job was submitted, so nothing else will report this.
    fail "Slurm submission failed for task $TASK_ID."
fi
