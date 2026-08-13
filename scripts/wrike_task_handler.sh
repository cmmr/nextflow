#!/bin/bash
#
# wrike_task_handler.sh - Validate a new pipeline request and submit it to Slurm.
#
# Author: Daniel Smith
# Date:   August 12th, 2026
#
# wrike_sqs_listener.sh calls this for both kinds of request: the "Bioinformatics
# Pipeline" form creates a task in "Dashboards" (TaskCreated), and the `run` script
# files an already-built task there (TaskParentsAdded). The two payloads differ,
# but everything used below - task ID, custom field, attachment - is read from
# Wrike rather than from the event.
#
# Runs on the login node and must stay lightweight; all real work goes to Slurm.
#
# The requested pipeline comes from the task's pipeline-name custom field, which
# accepts any text, so it is validated as a name before being used as a path.
#
# Every validation failure replies on the originating Wrike task and exits 0: a
# rejected request is a normal outcome, not a daemon error.
#
# Usage:     wrike_task_handler.sh <sqs_message_body_json>
# Called by: wrike_sqs_listener.sh
# Submits:   wrike_job.sh, then wrike_followup.sh (dependent on the first)
# Runs:      scripts/nextflow_progress.sh once, to seed the results page
# Requires:  jq, sbatch/squeue (Slurm), aws, openssl (via derive_uid), curl (via
#            call_wrike_api)
# Env:       NEXTFLOW_DIR, NEXTFLOW_NODE, AWS_S3_BUCKET, S3_RUN_PREFIX,
#            RUN_ID_SALT, WRIKE_PIPELINE_NAME_CFID, WRIKE_S3_RESULTS_URL_CFID,
#            the Wrike helper functions and the log/warn/fail/derive_uid/
#            run_results_url helpers, all from .env

set -euo pipefail

source /data/prod/nextflow/.env

# A form submission's attachment arrives as its own webhook event, so the file may
# not have landed yet. Attempts, and seconds between them.
ATTACHMENT_TRIES=5
ATTACHMENT_WAIT=3

# How much of the pipeline field to quote back to the user. The field is free
# text, so a bad value could be an entire pasted document.
PIPELINE_ECHO_CHARS=50

if [[ $# -ne 1 ]]; then
    fail "Usage: $0 <sqs_message_body_json>"
fi

MESSAGE_BODY="$1"

# TASK_ID is read by the update_wrike_* and add_wrike_task_comment helpers.
# "// empty" matters: without it jq prints "null" for a missing key, which looks
# like a perfectly good Wrike ID to the check below.
TASK_ID=$(echo "$MESSAGE_BODY" | jq -r '.[0].taskId // empty')

# TASK_ID names the run directory, the Slurm job, and the S3 prefix, so refuse
# anything that could not be a Wrike ID rather than sending the run after
# tmp/null. See is_valid_wrike_id for what Wrike can actually put here.
if ! is_valid_wrike_id "$TASK_ID"; then
    fail "Malformed or missing taskId in request payload; ignoring."
fi

# Apologize on the task, then give up. The SQS message is deleted before dispatch,
# so there is no redelivery: without this the user would watch a task that never
# does anything. Best effort, since Wrike being unreachable is the usual reason
# for getting here at all.
fail_with_apology() {
    local reply="Something went wrong on my end while handling this request."
    reply+=" Please submit a new request to try again."
    add_wrike_task_comment "$reply" || true

    # Nothing was submitted, so release the step 4 guard if it was taken
    if [[ -n "${RUN_DIR:-}" && -d "$RUN_DIR" ]]; then
        cd /
        rm -rf "$RUN_DIR"
    fi

    # Last, because it does not return. The run directory is gone, so there is no
    # message.out for fail to write to - nor any need, the user having been told
    # on the task itself.
    fail "$* (task $TASK_ID); asked the user to resubmit."
}

# Show the requester their request was picked up, before anything slow.
# update_wrike_task_status rather than the pipeline_progress helper: there is no
# run directory yet for status.txt to live in. Cosmetic, so not worth abandoning
# a good request over - the next call will report a Wrike outage anyway.
update_wrike_task_status "Validating" || true

# And say so in as many words, since the status field alone is easy to miss.
# Everything after this point reports back by commenting on the task, so this
# also tells the requester where the answer will show up. Best effort for the
# same reason as the status above.
REPLY="Hi! I've picked up your request and am validating it now."
REPLY+=" Watch this task's \"Status\" to follow the job's progress,"
REPLY+=" and I'll comment here as soon as there's anything to report."
add_wrike_task_comment "$REPLY" || true

# 1. Read the requested pipeline out of the task's custom field, which the form
#    fills in and `run` sets directly. Free text, so users can pin an exact
#    version like "16Sv4_01" - and so its contents are whatever they typed. Keep
#    the first line only, without surrounding whitespace.
if ! TASK_JSON=$(call_wrike_api GET "tasks/$TASK_ID"); then
    fail_with_apology "Could not read the task"
fi

PIPELINE_FIELD=$(echo "$TASK_JSON" \
    | jq -r --arg cfid "$WRIKE_PIPELINE_NAME_CFID" \
        '.data[0].customFields[]? | select(.id == $cfid) | .value // empty')

read -r PIPELINE_INPUT <<< "$PIPELINE_FIELD"

# 2. Resolve that name to a script in pipelines/, upper-cased so "16Sv4",
#    "16sv4", and "16SV4" all resolve to pipelines/16SV4.sh.
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

    PIPELINE_SHOWN=${PIPELINE_INPUT:0:$PIPELINE_ECHO_CHARS}

    if [[ -z "$PIPELINE_INPUT" ]]; then
        REPLY="You didn't tell me which pipeline to run."
    else
        REPLY="I couldn't find a pipeline named \"$PIPELINE_SHOWN\"."
    fi
    REPLY+=" Please submit a new request with one of the following options:"
    REPLY+=$'\n'"$VALID_PIPELINES"
    add_wrike_task_comment "$REPLY"
    log "Validation failed: Invalid pipeline requested (${PIPELINE_SHOWN:-none})."
    exit 0
fi

# 3. Require exactly one samplesheet on the task. The form makes the attachment
#    mandatory, but AttachmentAdded is a separate webhook event from the
#    TaskCreated that got us here and Wrike promises no order, so give the file a
#    few seconds to appear. Requests from `run` attach before filing the task, so
#    for those this loop always succeeds on the first attempt.
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
    add_wrike_task_comment "$REPLY"
    log "Validation failed: Expected 1 attachment, found $ATTACHMENT_COUNT."
    exit 0
fi

ATTACHMENT_ID=$(echo "$ATTACHMENTS_JSON" | jq -r '.data[0].id')
ATTACHMENT_NAME=$(echo "$ATTACHMENTS_JSON" | jq -r '.data[0].name')

if [[ ! "$ATTACHMENT_NAME" =~ \.(txt|tsv|out)$ ]]; then
    REPLY="I don't recognize the file extension on \"$ATTACHMENT_NAME\"."
    REPLY+=" Please submit a new request with a samplesheet that ends in .txt, .tsv, or .out."
    add_wrike_task_comment "$REPLY"
    log "Validation failed: Invalid extension on file $ATTACHMENT_NAME."
    exit 0
fi

# 4. Work out the uid this run will be known by - its directory, its Slurm job
#    name, and the S3 prefix it publishes under - and claim that prefix. The uid
#    is derived from the task ID (see derive_uid), so unlike the task ID it is
#    not unique by construction and has to be checked against what is already
#    published. Two tasks deriving the same uid is remote, but it would mean one
#    client's results overwriting another's, and the check costs one API call
#    against the request's whole lifetime.
#
#    Checked here rather than at upload time so a collision costs the requester
#    a resubmission instead of a run's worth of cluster time.
#
#    derive_uid's status is tested explicitly because set -e does not fire on an
#    assignment from a failed command substitution.
if ! RUN_ID=$(derive_uid "$TASK_ID"); then
    fail_with_apology "Could not derive a uid"
fi

# A failed call is not a free prefix: treat "cannot tell" as fatal rather than
# publishing over results that might be there.
if ! S3_LISTING=$(aws s3api list-objects-v2 --bucket "$AWS_S3_BUCKET" \
        --prefix "$S3_RUN_PREFIX/$RUN_ID/" --max-keys 1 2>&1); then
    fail_with_apology "Could not check whether the S3 prefix $S3_RUN_PREFIX/$RUN_ID is free"
fi

if [[ "$(echo "$S3_LISTING" | jq -r '.KeyCount // 0')" -ne 0 ]]; then
    # Deliberately vague: the requester can neither diagnose nor fix this, and
    # resubmitting is the whole remedy - a new task derives a new uid.
    REPLY="Something rare went wrong on my end: the storage location for this"
    REPLY+=" job's results is already taken. Please submit a new request, which"
    REPLY+=" will be given a different one."
    add_wrike_task_comment "$REPLY"
    log "Validation failed: uid $RUN_ID (task $TASK_ID) is already in use in S3."
    exit 0
fi

# 5. Create the run directory, named after the uid - which is how wrike_job.sh
#    and wrike_followup.sh know theirs, from their working directory. Creating
#    it also guards against running a task twice: SQS delivers at least once,
#    and a redelivered event would otherwise put a second pipeline behind the
#    same uid. The uid is derived, so a redelivery lands on this same directory
#    rather than a fresh one. Plain mkdir, not mkdir -p, so that an existing
#    directory is an error.
RUN_DIR="$NEXTFLOW_DIR/tmp/$RUN_ID"
mkdir -p "$NEXTFLOW_DIR/tmp"

if ! mkdir "$RUN_DIR" 2>/dev/null; then
    log "Ignoring task $TASK_ID: $RUN_DIR already exists, so this request has already been handled."
    exit 0
fi

cd "$RUN_DIR"

# The one thing about a run that cannot be worked out from its directory: uids
# are derived one way only, so record the task this one came from. Everything on
# the compute node reads it back through read_wrike_task_id.
echo "$TASK_ID" > "$WRIKE_TASK_ID_FILE"

# The title too, since the published results page is headed with it. Taken from
# the task JSON already fetched at step 1 rather than asked for again, and kept
# to one line - it is going into an HTML header, not a document. Best effort:
# the pages fall back to a generic heading, which is no reason to lose a run.
TASK_NAME=$(echo "$TASK_JSON" | jq -r '.data[0].title // empty') || TASK_NAME=""
printf '%s\n' "${TASK_NAME%%$'\n'*}" > "$WRIKE_TASK_NAME_FILE"

# Open the channel back to the requester now that we are inside the run directory:
# fail writes to message.out wherever it exists, so anything that goes wrong from
# here on - here, in wrike_job.sh, or in a pipeline's pre/post-process scripts -
# reaches the user when wrike_followup.sh posts it at the end of the job.
: > message.out

# 6. Seed the task's pipeline name and status, and status.txt in the run directory
#    for wrike_followup.sh to read later. Must happen before submission, because
#    the job starts by overwriting both. Writing the name back normalizes whatever
#    the user typed to the name that actually resolved.
#
#    Nothing is submitted yet, so a Wrike failure here is recoverable by asking
#    for a resubmit rather than leaving a half-marked task behind.
if ! update_wrike_pipeline_name "$PIPELINE_UPPER" \
        || ! update_wrike_pipeline_progress "Queued"; then
    fail_with_apology "Could not set the task's pipeline name and status"
fi

# 7. Submit the job, then a follow-up job that reports the outcome either way.
#    Both are named after the uid so wrike_delete_handler.sh can scancel them,
#    and both run in RUN_DIR. sbatch options must precede the script name.
#
#    Queue depth is cosmetic, so a failing squeue must not take the submission
#    with it: the task is already marked Queued, and dying here would strand it
#    that way with no job behind it.
JOBS_AHEAD=$(squeue -h -t PENDING | wc -l) || JOBS_AHEAD="an unknown number of"

if JOB_ID=$(sbatch --parsable --job-name="$RUN_ID" --chdir="$RUN_DIR" \
        --nodelist="$NEXTFLOW_NODE" \
        "$NEXTFLOW_DIR/scripts/wrike_job.sh" "$PIPELINE_UPPER" "$ATTACHMENT_ID"); then

    # afterany, not afterok, so failures are reported to the user too. A
    # follow-up that fails to submit is not fatal - the pipeline is already
    # queued - but it does mean nothing will report the outcome.
    if ! FOLLOWUP_ID=$(sbatch --parsable --job-name="$RUN_ID" --chdir="$RUN_DIR" \
            --nodelist="$NEXTFLOW_NODE" \
            --dependency=afterany:"$JOB_ID" \
            "$NEXTFLOW_DIR/scripts/wrike_followup.sh"); then
        FOLLOWUP_ID="none"
        warn "Follow-up submission failed for task $TASK_ID; job $JOB_ID will run unreported."
    fi

    # The results address is known the moment the run has a uid, so publish it
    # now rather than at the end: it is where the requester watches the job as
    # well as where they collect it. Best effort from here on - the job is
    # queued, and nothing below is worth abandoning it over. ampliseq_upload.sh
    # sets the same field again when the results land, which covers a failure
    # here.
    RESULTS_URL=$(run_results_url "$RUN_ID")

    update_wrike_custom_field "$WRIKE_S3_RESULTS_URL_CFID" "$RESULTS_URL" \
        || warn "Could not set the results URL on task $TASK_ID."

    # Put a page at that address straight away, so the link in the comment below
    # leads somewhere from the moment it is posted. Until the job starts running
    # this says the run is queued; nextflow_progress.sh takes over once the
    # pipeline is under way.
    "$NEXTFLOW_DIR/scripts/nextflow_progress.sh" \
        || warn "Could not publish the initial progress page for task $TASK_ID."

    REPLY="Success! Your job for the $PIPELINE_UPPER pipeline was successfully"
    REPLY+=" submitted to the cluster using the attached samplesheet."
    REPLY+=" There are currently $JOBS_AHEAD pending jobs ahead of yours in the queue."
    REPLY+=$'\n\n'"You can follow along here, and this is where your results will"
    REPLY+=" appear once the run finishes:"$'\n'"$RESULTS_URL"
    add_wrike_task_comment "$REPLY"
    log "Job $JOB_ID submitted for task $TASK_ID as uid $RUN_ID, followed by dependent job $FOLLOWUP_ID."
else
    update_wrike_pipeline_progress "Failed"

    REPLY="Your pipeline name and samplesheet are valid, but there was an error"
    REPLY+=" submitting this job to the cluster. Please submit a new request."
    add_wrike_task_comment "$REPLY"

    # Both cleans up and releases the step 4 guard
    cd /
    rm -rf "$RUN_DIR"

    fail "Slurm submission failed for task $TASK_ID."
fi
