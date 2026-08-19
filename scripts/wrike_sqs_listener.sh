#!/bin/bash
#
# wrike_sqs_listener.sh - Poll AWS SQS for Wrike webhook events and dispatch handlers.
#
# Author: Daniel Smith
# Date:   August 12th, 2026
#
# A Wrike webhook on the "Dashboards" folder publishes JSON payloads to an AWS
# SQS queue whenever the items inside it change. This daemon runs continuously on
# the cluster login node, long-polls that queue, and routes each payload to the
# handler matching its eventType. Handlers are backgrounded so a slow one never
# stalls polling.
#
# A request arrives as either of two events, because there are two ways a task
# lands in "Dashboards": a request form creates it there (TaskCreated), while the
# `run` script files an existing task there (TaskParentsAdded). Both go to the
# same handler.
#
# Usage:     wrike_sqs_listener.sh      # never returns; start under a supervisor
# Calls:     wrike_task_handler.sh, wrike_delete_handler.sh, both by absolute path
# Requires:  aws, jq, sinfo (Slurm)
# Env:       NEXTFLOW_DIR, AWS_SQS_QUEUE_URL, AWS_REGION, WRIKE_DASHBOARDS_FOLDER_ID,
#            the log/warn helpers and AWS credentials, sourced from .env

set -euo pipefail

source /data/prod/nextflow/.env

# Seconds to wait before re-checking an unreachable Slurm controller
SLURM_RETRY_WAIT=60

# Seconds to back off after a failed poll. A failing aws call returns instantly,
# so without this a persistent failure would spin the loop at full speed.
SQS_ERROR_WAIT=10

# Leave the loop cleanly when the supervisor stops us. The signal is not handled
# until the in-flight aws call returns, so shutdown can lag by SQS_WAIT_SECONDS.
trap 'log "Stopping Wrike SQS Listener Daemon."; exit 0' INT TERM

log "Starting Wrike SQS Listener Daemon..."

while true; do

    # 1. Skip polling entirely while Slurm is down, since no handler could submit
    #    a job anyway. Messages stay in the queue until the cluster returns.
    if ! sinfo > /dev/null 2>&1; then
        warn "Slurm cluster is unreachable or offline. Pausing polling for ${SLURM_RETRY_WAIT}s..."
        sleep "$SLURM_RETRY_WAIT"
        continue
    fi

    # 2. Long poll SQS. A failed call backs off rather than aborting the daemon.
    if ! RESPONSE=$(aws sqs receive-message \
            --queue-url "$AWS_SQS_QUEUE_URL" \
            --region "$AWS_REGION" \
            --max-number-of-messages 1 \
            --wait-time-seconds 20 \
            --output json 2>&1); then
        warn "SQS poll failed, retrying in ${SQS_ERROR_WAIT}s: $RESPONSE"
        sleep "$SQS_ERROR_WAIT"
        continue
    fi

    # 3. Pulling out the receipt handle is also the test for whether the poll
    #    returned anything: a long poll that times out prints no message, so the
    #    handle comes back empty and there is nothing to do. jq is allowed to
    #    fail here - a response that is not message JSON leaves it empty too.
    RECEIPT_HANDLE=$(echo "$RESPONSE" | jq -r '.Messages[0].ReceiptHandle // empty' 2>/dev/null) \
        || RECEIPT_HANDLE=""

    if [[ -z $RECEIPT_HANDLE ]]; then
        continue
    fi

    MESSAGE_BODY=$(echo "$RESPONSE" | jq -r '.Messages[0].Body')

    log "Webhook trigger received from SQS."

    # 4. Delete before dispatching, so a handler that dies cannot cause the
    #    message to be redelivered and the same job to be submitted twice. A
    #    message that cannot be deleted is left undispatched for the same
    #    reason: SQS returns it after the visibility timeout, and dispatching it
    #    now would run it a second time then.
    if ! DELETE_ERROR=$(aws sqs delete-message \
            --queue-url "$AWS_SQS_QUEUE_URL" \
            --receipt-handle "$RECEIPT_HANDLE" \
            --region "$AWS_REGION" 2>&1); then
        warn "Failed to delete SQS message, leaving it for redelivery: $DELETE_ERROR"
        continue
    fi

    # 5. Route on eventType. Handlers run in the background, so their exit
    #    status is not checked here; they log their own outcome.
    EVENT_TYPE=$(echo "$MESSAGE_BODY" | jq -r '.[0].eventType // empty')

    case "$EVENT_TYPE" in
        TaskCreated)
            log "Routing to wrike_task_handler.sh for $EVENT_TYPE event."
            "$NEXTFLOW_DIR/scripts/wrike_task_handler.sh" "$MESSAGE_BODY" &
            ;;
        TaskParentsAdded)
            # How a `run` submission arrives. This fires for any parent change
            # on a task the webhook can see, so check that "Dashboards" is what
            # was added.
            if echo "$MESSAGE_BODY" | jq -e --arg folder "$WRIKE_DASHBOARDS_FOLDER_ID" \
                    '[.[0].addedParents[]?] | any(. == $folder)' > /dev/null; then
                log "Routing to wrike_task_handler.sh for $EVENT_TYPE event."
                "$NEXTFLOW_DIR/scripts/wrike_task_handler.sh" "$MESSAGE_BODY" &
            else
                log "Ignoring $EVENT_TYPE event: \"Dashboards\" was not among the parents added."
            fi
            ;;
        TaskDeleted | TaskParentsRemoved)
            log "Routing to wrike_delete_handler.sh for $EVENT_TYPE event."
            "$NEXTFLOW_DIR/scripts/wrike_delete_handler.sh" "$MESSAGE_BODY" "$EVENT_TYPE" &
            ;;
        *)
            log "Ignoring unhandled event type: $EVENT_TYPE."
            ;;
    esac
done
