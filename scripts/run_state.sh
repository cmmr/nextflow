#
# run_state.sh - The one file a run keeps its state in, and the helpers that
#                read and write it.
#
# Author: Daniel Smith
# Date:   August 28th, 2026
#
# Sourced by .env rather than executed.
#
# Every scalar a run records about itself lives in ./run_state.json in the run
# directory - the status, the stage, the message and notes bound for Wrike, the
# Wrike task it came from, the checked form answers, the sample count and read
# length, the detected region, the clocks, the composition statistics, and the
# manifest a rerun is rebuilt from. Bulk artifacts stay files of their own:
# samplesheets, params files, nextflow's logs, the region detection report, and
# the composition plot data.
#
# Values are addressed by a dotted path - "wrike.task_id", "samples.count" -
# which jq splits into an object path. A key carrying a dot would nest; none of
# the keys used here has one.
#
# Writes are serialized on .run_state.lock and land by rename, so the progress
# watcher publishing every ten seconds always reads a whole document, and two
# stages writing at once do not lose an update.
#
# Nothing recorded here is secret. The whole file is published to the run's own
# S3 prefix as run_state.json, beside the page that presents the results, so a
# reader holding the results link holds the complete account of how they were
# made - the request as it was read, every parameter as resolved, and how the run
# went. Anything that must not be published belongs in secrets/.env instead.
#
# Defines: RUN_STATE_FILE, RUN_STATE_KEY, state_init, state_present,
#          state_update, state_get, state_get_json, state_get_tsv, state_has,
#          state_set, state_set_json, state_set_number, state_set_tsv,
#          state_append, state_unset, publish_run_state, set_run_status,
#          set_run_stage, get_run_status
# Requires: jq, and flock where two writers can overlap; aws for
#           publish_run_state; the warn helper and is_valid_uid from
#           utilities.sh, which .env sources first
# Env:      AWS_S3_BUCKET and S3_RUN_PREFIX, for publish_run_state

# In the run directory, which every script that touches state runs from
RUN_STATE_FILE="run_state.json"
RUN_STATE_LOCK=".run_state.lock"

# The same file published beside the run's results, under the run's own S3
# prefix. It is the run's whole account of itself, so it is also what a later
# rerun is rebuilt from and what survives the dashboard's expiry.
RUN_STATE_KEY="run_state.json"
RUN_STATE_SCHEMA=1

# Attempts at one write, and seconds between them
RUN_STATE_TRIES=5
RUN_STATE_RETRY_WAIT=1

state_present() {
    [[ -f "$RUN_STATE_FILE" ]]
}

# Create the state file. wrike_task_handler.sh calls this as it creates the run
# directory; everything after it writes into what this leaves.
state_init() {
    local run_id="${1:-${PWD##*/}}"

    jq -n \
        --argjson schema "$RUN_STATE_SCHEMA" \
        --arg run_id "$run_id" \
        --arg status "Submitted" \
        --arg created_utc "$(date -u "+%Y-%m-%dT%H:%M:%SZ")" \
        '{schema: $schema, run_id: $run_id, status: $status, created_utc: $created_utc, notes: []}' \
        > "$RUN_STATE_FILE"
}

# One pass of the read-modify-write, under the lock and landing by rename
state_update_once() {
    local filter="$1"
    shift

    # Beside the state file, so the rename below stays on one filesystem
    local tmp
    if ! tmp=$(mktemp ".run_state.XXXXXX"); then
        warn "Could not create a temporary file beside $RUN_STATE_FILE."
        return 1
    fi

    {
        # A host without flock leaves the read-modify-write unserialized, which
        # is the exposure the separate state files had
        if command -v flock > /dev/null 2>&1; then
            flock 9 || true
        fi

        # mv is quiet because a lost race is retried rather than reported
        if ! jq "$@" "$filter" "$RUN_STATE_FILE" > "$tmp"                 || ! mv -f "$tmp" "$RUN_STATE_FILE" 2>/dev/null; then
            rm -f "$tmp"
            return 1
        fi
    } 9>>"$RUN_STATE_LOCK"
}

# Apply one jq filter to the document. Every writer below goes through here.
#
# Retried, because the writes a run makes of itself are the record everything
# downstream reports from: wrike_followup.sh reads the status to find out how
# the run ended, and a lost write would have it report the wrong thing.
#
# warn and return rather than fail: fail records its own message through
# state_set, and a failing write must not recurse into itself.
state_update() {
    local attempt

    if ! state_present; then
        warn "No $RUN_STATE_FILE in $PWD; state not recorded."
        return 1
    fi

    for (( attempt = 1; attempt <= RUN_STATE_TRIES; attempt++ )); do
        if state_update_once "$@"; then
            return 0
        fi

        sleep "$RUN_STATE_RETRY_WAIT"
    done

    warn "Could not apply an update to $RUN_STATE_FILE after $RUN_STATE_TRIES attempts."
    return 1
}

# One value as text. A missing key, and a key holding null, both read as empty,
# which is what a caller reads as "never recorded". Numbers and booleans come
# back as they are written; an object or an array comes back as JSON.
state_get() {
    state_present || return 0

    jq -r --arg key "$1" '
        getpath($key | split(".")) as $value
        | if   $value == null       then ""
          elif ($value|type) == "string" then $value
          else ($value|tojson) end' "$RUN_STATE_FILE"
}

# One value as compact JSON, or "null" when it was never recorded
state_get_json() {
    state_present || { printf 'null'; return 0; }

    jq -c --arg key "$1" 'getpath($key | split(".")) // null' "$RUN_STATE_FILE"
}

# An object read back as "key<tab>value" lines, in the order jq holds them
state_get_tsv() {
    state_present || return 0

    jq -r --arg key "$1" '
        getpath($key | split(".")) // {}
        | to_entries[]
        | "\(.key)\t\(.value | if type == "string" then . else tojson end)"' \
        "$RUN_STATE_FILE"
}

state_has() {
    state_present || return 1

    jq -e --arg key "$1" 'getpath($key | split(".")) != null' \
        "$RUN_STATE_FILE" > /dev/null 2>&1
}

state_set() {
    state_update 'setpath($key | split("."); $value)' \
        --arg key "$1" --arg value "$2"
}

# The same, for a value that is already JSON - an object, an array, or a number
state_set_json() {
    local key="$1" value="$2"

    if ! printf '%s' "$value" | jq -e . > /dev/null 2>&1; then
        warn "The value offered for \"$key\" is not JSON; not recorded."
        return 1
    fi

    state_update 'setpath($key | split("."); $value)' \
        --arg key "$key" --argjson value "$value"
}

# A count or a measurement, stored as a number so a reader does not have to
# retype it. A value that is not a number is skipped rather than written as text.
state_set_number() {
    local key="$1" value="$2"

    if [[ ! "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        warn "\"$value\" is not a number; \"$key\" not recorded."
        return 1
    fi

    state_set_json "$key" "$value"
}

# An object built from "key<tab>value" lines on stdin. Values are strings, as
# they were read.
state_set_tsv() {
    local key="$1" object

    object=$(jq -R -s 'split("\n")
        | map(select(length > 0) | split("\t") | {(.[0]): (.[1] // "")})
        | add // {}') || return 1

    state_set_json "$key" "$object"
}

# Add one line to an array - notes, which stages append to rather than overwrite
state_append() {
    state_update '($key | split(".")) as $path
        | setpath($path; ((getpath($path) // []) + [$value]))' \
        --arg key "$1" --arg value "$2"
}

state_unset() {
    state_update 'delpaths([$key | split(".")])' --arg key "$1"
}

# Put the run's state beside its results, at the prefix the results link
# addresses. Called wherever the state has just changed in a way a reader would
# want - which is every point nextflow_progress.sh publishes a page.
#
# Cosmetic while a run is going and a record afterwards: nothing about the run
# depends on the upload succeeding, so callers warn rather than stop.
publish_run_state() {
    local run_id="${1:-${PWD##*/}}"

    state_present || return 1

    # Validated because it names the prefix this is written to
    if ! is_valid_uid "$run_id"; then
        warn "Not a run directory ($PWD); $RUN_STATE_FILE not published."
        return 1
    fi

    aws s3 cp "$RUN_STATE_FILE"         "s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/$run_id/$RUN_STATE_KEY"         --content-type "application/json" > /dev/null
}

# How far the run has got, as the Wrike custom statuses name it: "Validating"
# through "Running" to "Completed" or "Failed". wrike_followup.sh reads this to
# find out how the run ended, and nextflow_progress.sh to head the page.
#
# Deliberately separate from set_wrike_status, which sets the same name
# on the Wrike task: a caller reports to one, the other, or both.
set_run_status() {
    state_set status "$1"
}

get_run_status() {
    state_get status
}

# What the run is doing right now, in one sentence a requester would recognise,
# for the line under the run's name on the progress page. Overwritten rather
# than appended: the page reports where the run is, not how it got there.
#
# Best effort, since a run must not fail over a status line.
set_run_stage() {
    state_set stage "$1" 2>/dev/null || true
}
