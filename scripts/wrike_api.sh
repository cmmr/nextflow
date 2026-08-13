#
# wrike_api.sh - Wrike REST helpers shared by every script that talks to Wrike.
#
# Author: Daniel Smith
# Date:   August 12th, 2026
#
# Sourced by .env rather than executed. Every helper except call_wrike_api,
# is_valid_wrike_id and read_wrike_task_id acts on the task named by TASK_ID,
# read from the environment rather than passed in.
#
# Request bodies are built with jq, not by splicing values into hand-written
# JSON: pipeline names originate in a free-text field the requester fills in.
#
# The Wrike object IDs below are opaque references rather than secrets - useless
# without a token - so they live here in git, next to the code that uses them,
# rather than in secrets/.env where a fresh clone could not recover them.
#
# Requires: curl, jq, Bash 4+ (WRIKE_CUSTOM_STATUS_IDS is an associative array),
#           and the warn helper from utilities.sh, which .env sources first
# Defines:  WRIKE_DASHBOARDS_FOLDER_ID, WRIKE_NXFPIPE_*, WRIKE_*_CFID,
#           WRIKE_CUSTOM_STATUS_IDS, WRIKE_TASK_ID_FILE, WRIKE_TASK_NAME_FILE
# Env:      WRIKE_API_TOKEN from secrets/.env, and TASK_ID at the call site

export WRIKE_BOT_USER_ID="KUAYXHNY"
export WRIKE_NXFPIPE_SPACE_ID="MQAAAAEN9xux"
export WRIKE_NXFPIPE_WORKFLOW_ID="IEAAIKU5K4HRVOKU"
export WRIKE_NXFPIPE_REQUEST_FORM_ID="IEAAIKU5LIACYIUI"
export WRIKE_DASHBOARDS_FOLDER_ID="MQAAAAEN9zQV"
export WRIKE_PIPELINE_NAME_CFID="IEAAIKU5JUANAH3C"
export WRIKE_S3_RESULTS_URL_CFID="IEAAIKU5JUANAH3J"
declare -A WRIKE_CUSTOM_STATUS_IDS=(
    [Submitted]="IEAAIKU5JMHRVOKU"
    [Validating]="IEAAIKU5JMHRVOK6"
    [Queued]="IEAAIKU5JMHRVOLI"
    [Initializing]="IEAAIKU5JMHRXWVK"
    [Pre-Processing]="IEAAIKU5JMHRVOLS"
    [Running]="IEAAIKU5JMHRVOL4"
    [Post-Processing]="IEAAIKU5JMHRVOMG"
    [Completed]="IEAAIKU5JMHRVOKV"
    [Failed]="IEAAIKU5JMHRVOMR"
    [Archived]="IEAAIKU5JMHRVOM3"
    [Cancelled]="IEAAIKU5JMHRVONH"
)
export WRIKE_TASK_ID_FILE="wrike_task_id.txt"
export WRIKE_TASK_NAME_FILE="wrike_task_name.txt"

# True when the argument could be a Wrike API v4 ID. Wrike's own pattern for one
# is ^([a-zA-Z0-9-_:.=]){1,256}$ - not the bare alphanumerics these IDs used to
# look like - and the documentation asks that they be treated as opaque text
# rather than matched against whatever shape they happen to have today. So this
# is not a test for a well-formed ID; it only rules out the values that must
# never reach a filesystem path, an S3 prefix, or an rm -rf: empty, "null" from
# a missing jq key, and anything carrying a character Wrike cannot have issued.
is_valid_wrike_id() {
    local id="$1"

    # Length is checked with ${#id} rather than as a {1,256} bound on the regex
    # below: POSIX caps a bound at 255, and over that the pattern does not fail
    # to match, it fails to compile - which [[ =~ ]] reports the same way it
    # reports a bad ID, so every task would have been rejected.
    if (( ${#id} < 1 || ${#id} > 256 )); then
        return 1
    fi

    # "." and ".." are the only values over that character set that would
    # traverse a path - it has no "/" to build anything longer out of - so they
    # are all that has to be excluded on top of the character set itself.
    [[ "$id" =~ ^[A-Za-z0-9._:=-]+$ && "$id" != "." && "$id" != ".." ]]
}

# Recover the task a run belongs to, for the helpers below to act on. Run
# directories are named after the uid, and a uid cannot be turned back into a
# task ID, so wrike_task_handler.sh records it in this file when it creates the
# directory. Everything on the compute node reads it back from there.

read_wrike_task_id() {
    local file="${1:-$WRIKE_TASK_ID_FILE}"
    local id

    if [[ ! -r "$file" ]]; then
        warn "Cannot read $file; the run's Wrike task is unknown."
        return 1
    fi

    # First line only, without surrounding whitespace
    read -r id < "$file" || true

    # Validated on the way out as well as in: this drives every URL the helpers
    # below build, and an empty value would address the whole tasks collection.
    if ! is_valid_wrike_id "$id"; then
        warn "$file does not contain a usable Wrike task ID."
        return 1
    fi

    printf '%s' "$id"
}

call_wrike_api() {
    local verb="$1"
    local endpoint="$2"
    shift 2

    # Tolerate a leading slash on the endpoint
    local url="https://www.wrike.com/api/v4/${endpoint#/}"

    # -sS: quiet, but still show errors; -f: non-zero exit on HTTP 4xx/5xx
    curl -sS -f -X "$verb" "$url" -H "Authorization: bearer $WRIKE_API_TOKEN" "$@"

    local status=$?
    if [[ $status -ne 0 ]]; then
        # warn, not fail: every caller decides for itself whether a failed call
        # is fatal. To stderr, since most calls sit inside a command
        # substitution that would otherwise swallow the warning.
        warn "Request failed: $verb $endpoint (curl exit code $status)" >&2

        # The one place that reports without stopping, so it writes message.out
        # itself rather than leaving it to fail
        if [[ -f message.out ]]; then
            echo "Curl error code $status for $verb $endpoint." > message.out
        fi

        return $status
    fi
}

# PUT to the current task. body is assigned separately so a jq failure is not
# masked by the assignment's own exit status.
update_wrike_task() {
    local jq_filter="$1"
    shift

    local body
    body=$(jq -n "$@" "$jq_filter")

    call_wrike_api PUT "tasks/$TASK_ID" \
      -H "Content-Type: application/json" \
      -d "$body"
}

update_wrike_custom_field() {
    local custom_field_id="$1"
    local new_value="$2"

    update_wrike_task '{customFields: [{id: $id, value: $value}]}' \
        --arg id "$custom_field_id" \
        --arg value "$new_value"
}

update_wrike_task_status() {
    local new_value="$1"
    local status_id="${WRIKE_CUSTOM_STATUS_IDS[$new_value]:-}"

    if [[ -z "$status_id" ]]; then
        warn "No Wrike custom status is mapped to \"$new_value\"; status not reported."
        return 0
    fi

    update_wrike_task '{customStatus: $status}' --arg status "$status_id"
}

update_wrike_pipeline_progress() {
    local new_value="$1"

    echo "$new_value" > status.txt

    update_wrike_task_status "$new_value"
}

update_wrike_pipeline_name() {
    local new_value="$1"

    update_wrike_custom_field "$WRIKE_PIPELINE_NAME_CFID" "$new_value"
}

update_wrike_add_parent() {
    local new_parent="$1"

    update_wrike_task '{addParents: [$parent]}' --arg parent "$new_parent"
}

add_wrike_task_comment() {
    local message="$*"

    call_wrike_api POST "tasks/$TASK_ID/comments" \
      -d "plainText=true" \
      --data-urlencode "text=$message" \
      > /dev/null
}
