#!/bin/bash
#
# wrike_delete_handler.sh - Tear down a run when its Wrike task goes away.
#
# Author: Daniel Smith
# Date:   August 12th, 2026
#
# Called by wrike_sqs_listener.sh for TaskDeleted and TaskParentsRemoved events.
# Cleanup covers all three places a run leaves state: queued or running Slurm
# jobs, published S3 results, and the local run directory. Every step is
# best-effort, since a run may never have created the thing being removed.
#
# TaskParentsRemoved fires for any parent change on a task the webhook can see,
# so the removed parent is checked before anything is destroyed.
#
# Usage:     wrike_delete_handler.sh <sqs_message_body_json> <event_type>
#            where <event_type> is TaskDeleted or TaskParentsRemoved
# Called by: wrike_sqs_listener.sh
# Requires:  jq, aws, scancel (Slurm), openssl (via derive_uid), curl (via
#            call_wrike_api)
# Env:       NEXTFLOW_DIR, AWS_S3_BUCKET, S3_RUN_PREFIX, S3_ZIP_PREFIX, RUN_ID_SALT,
#            WRIKE_DASHBOARDS_FOLDER_ID,
#            the Wrike helper functions and the log/fail/derive_uid helpers, all
#            sourced from .env

set -euo pipefail

source /data/prod/nextflow/.env

if [[ $# -ne 2 ]]; then
    fail "Usage: $0 <sqs_message_body_json> <event_type>"
fi

MESSAGE_BODY="$1"
EVENT_TYPE="$2"

# TASK_ID is read by the add_wrike_task_comment helper.
# "// empty" matters: without it jq prints "null" for a missing key, which looks
# like a perfectly good Wrike ID to the check below.
TASK_ID=$(echo "$MESSAGE_BODY" | jq -r '.[0].taskId // empty')

# Every destructive step below derives a path or an S3 prefix from TASK_ID, so
# anything that could not be a Wrike ID is refused here.
if ! is_valid_wrike_id "$TASK_ID"; then
    fail "Malformed or missing taskId in $EVENT_TYPE payload; nothing cleaned up."
fi

# A deleted task always concerns us; a parent change only when "Dashboards" is
# the parent removed. A task can sit in other folders too - `run` leaves its
# staging space attached - and unfiling it from one of those must not tear down a
# run that is still on the dashboard.
if [[ "$EVENT_TYPE" == "TaskParentsRemoved" ]]; then
    DASHBOARDS_REMOVED=$(echo "$MESSAGE_BODY" \
        | jq -r --arg folder "$WRIKE_DASHBOARDS_FOLDER_ID" \
            '.[0].removedParents[]? | select(. == $folder)')

    if [[ -z "$DASHBOARDS_REMOVED" ]]; then
        log "Ignoring $EVENT_TYPE for task $TASK_ID: \"Dashboards\" was not among the parents removed."
        exit 0
    fi
fi

# Recomputed from the task ID, which is all a delete event carries - by now the
# task may be gone from Wrike along with the custom field holding the results
# URL. Nothing below is best-effort until this succeeds: an empty uid would leave
# RUN_DIR as the whole tmp directory and S3_RESULTS_DIR as the whole bucket, and
# both are deleted recursively below.
if ! RUN_ID=$(derive_uid "$TASK_ID"); then
    fail "Could not derive the uid for task $TASK_ID; nothing cleaned up."
fi

RUN_DIR="$NEXTFLOW_DIR/tmp/$RUN_ID"
S3_RESULTS_DIR="s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/$RUN_ID"

log "Commencing cleanup protocol for task $TASK_ID (uid $RUN_ID)"

# 1. Terminate any Slurm jobs for this run; both the pipeline job and its
#    follow-up are named after the uid. Failure is expected, and ignored, once
#    the jobs have finished.
scancel --name="nf-$RUN_ID" --user="$(whoami)" > /dev/null 2>&1 || true

# 2. Purge everything published under the prefix: the progress page
#    wrike_task_handler.sh put there when the request arrived, and the results on
#    top of it if the run got that far.
aws s3 rm "$S3_RESULTS_DIR" --recursive > /dev/null 2>&1 || true

#    And the zip the download Lambda cached of all that, which is published from
#    a prefix of its own and so is not under the recursive delete above
for CACHED in "$S3_ZIP_PREFIX/$RUN_ID.zip" "$S3_ZIP_PREFIX/$RUN_ID.json"; do
    aws s3 rm "s3://$AWS_S3_BUCKET/$CACHED" > /dev/null 2>&1 || true
done

# 3. Confirm to the user. Only a removed Dashboards tag gets a comment; a deleted
#    task has nowhere to comment on.
if [[ "$EVENT_TYPE" == "TaskParentsRemoved" ]]; then
    REPLY="The Dashboards tag was removed from this task. As a result, its results"
    REPLY+=" dashboard has been deleted"

    # A run directory outlives a request that was rejected or whose job failed,
    # but not one whose job finished - wrike_followup.sh removes it on success.
    if [[ -e "$RUN_DIR" ]]; then
        REPLY+=", along with the temporary run files"
    fi
    REPLY+="."

    add_wrike_task_comment "$REPLY"
    log "Cleanup comment posted for orphaned task $TASK_ID."
else
    log "Task $TASK_ID deleted. Cleanup finished. No comment posted."
fi

# 4. Purge the local run directory last, so the check above still sees it
rm -rf "$RUN_DIR"
