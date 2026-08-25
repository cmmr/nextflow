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
# Request bodies are built with jq rather than by splicing values into
# hand-written JSON.
#
# The Wrike object IDs below are opaque references rather than secrets - useless
# without a token - so they live here in git next to the code that uses them.
#
# Requires: curl, jq, Bash 4+ (associative arrays), and the warn helper from
#           utilities.sh, which .env sources first
# Defines:  the WRIKE_* object IDs, WRIKE_FORM_ANSWERS and the helpers that read
#           and check them, WRIKE_CUSTOM_STATUS_IDS, and WRIKE_LAST_RESPONSE (the
#           reply to the most recent update_wrike_task)
# Env:      WRIKE_API_TOKEN from secrets/.env, and TASK_ID at the call site

export WRIKE_BOT_USER_ID="KUAYXHNY"
export WRIKE_NXFPIPE_SPACE_ID="MQAAAAEN9xux"
export WRIKE_NXFPIPE_WORKFLOW_ID="IEAAIKU5K4HRVOKU"
export WRIKE_NXFPIPE_REQUEST_FORM_ID="IEAAIKU5LIACYIUI"
export WRIKE_DASHBOARDS_FOLDER_ID="MQAAAAEN9zQV"
export WRIKE_S3_RESULTS_URL_CFID="IEAAIKU5JUANAH3J"

# Every question on the "Bioinformatics Pipeline" request form, as
# key | its title in Wrike | the answers this system accepts.
#
# Answers are checked against these lists rather than passed through, because
# each one ends up in a nextflow command line. There is no free-text parameter
# field: what a requester can ask for is exactly what is listed here.
#
# Fields are matched by title rather than by ID, so recreating one in Wrike needs
# no change here. A CheckBox answer arrives comma-separated and every part has to
# be allowed. An empty list is checked by shape instead - only "Previous Run ID",
# which is_valid_uid answers for.
#
# "Pipeline" is the one whose options carry a description after the name
# ("ampliseq :: 16S full length or variable region amplicons"), so only its first
# word is read and checked.
WRIKE_FORM_ANSWERS=(
    "pipeline|Pipeline|ampliseq,taxprofiler,prev_run_id"
    "availability|Availability|1 Month,3 Months,6 Months,12 Months,24 Months,Unlimited"
    "previous_run|Previous Run ID|"
    "host|Host Depletion|None,PhiX,Human + PhiX,Mouse + PhiX"
    "settings|Settings|Default,Custom"
    "dada_ref|Primary ASV Taxonomic Database (DADA2)|silva=138.2,greengenes2=2024.09,coidb=221216,gtdb=R11-RS232,midori2-co1=gb250,pr2=5.1.0,rdp=18,sbdi-gtdb=R11-RS232-1,unite-alleuk=10.0,unite-fungi=10.0,zehr-nifh=2.5.0"
    "qiime_ref|Secondary QIIME2 Taxonomic Database|silva=138,greengenes2=2024.09"
    "kraken2_ref|Read-Based Taxonomic Database (Kraken2)|silva=138,rdp=18,greengenes=13.5,standard=20240904"
    "picrust|Functional Profiling (PICRUSt2)|No,Yes"
    "exclude_taxa|Taxa Exclusion Filter|mitochondria,chloroplast,Francisella"
)

# The "Pipeline" answer that names no pipeline: it asks for an earlier run to be
# repeated, and names that run in "Previous Run ID".
export WRIKE_RERUN_ANSWER="prev_run_id"

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
    [Expired]="IEAAIKU5JMHRVOM3"
    [Cancelled]="IEAAIKU5JMHRVONH"
)
export WRIKE_TASK_ID_FILE="wrike_task_id.txt"
export WRIKE_TASK_NAME_FILE="wrike_task_name.txt"

# Where wrike_task_handler.sh leaves the checked answers, in the run directory,
# as "key<tab>value" lines. Pipelines read it with form_answer.
export WRIKE_FORM_ANSWERS_FILE="form_answers.tsv"

# True when the argument could be a Wrike API v4 ID: 1-256 characters over
# Wrike's own [a-zA-Z0-9-_:.=], and neither "." nor "..". This rules out the
# values that must never reach a filesystem path, an S3 prefix, or an rm -rf -
# empty, "null" from a missing jq key, and anything carrying a character Wrike
# cannot have issued.
is_valid_wrike_id() {
    local id="$1"

    # Length is checked separately: as a {1,256} bound on the regex below it
    # would exceed the POSIX limit of 255 and fail to compile, which [[ =~ ]]
    # reports as a non-match.
    if (( ${#id} < 1 || ${#id} > 256 )); then
        return 1
    fi

    [[ "$id" =~ ^[A-Za-z0-9._:=-]+$ && "$id" != "." && "$id" != ".." ]]
}

# Recover the task a run belongs to, for the helpers below to act on. Run
# directories are named after the uid, which does not lead back to a task, so
# wrike_task_handler.sh records the ID in this file when it creates the
# directory.
#
# Like derive_uid, this warns and returns rather than failing: callers read it
# through $(...). stdout here is the task ID, which is why warn writes to stderr.
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
        # is fatal. Safe here, where the response is on stdout, because warn
        # writes to stderr.
        warn "Request failed: $verb $endpoint (curl exit code $status)"

        # Reports without stopping, so it writes message.out itself rather than
        # leaving it to fail
        if [[ -f message.out ]]; then
            echo "Curl error code $status for $verb $endpoint." > message.out
        fi

        return $status
    fi
}

# PUT to the current task. body is assigned separately so a jq failure is not
# masked by the assignment's own exit status.
#
# Wrike answers a PUT with the whole updated task, which none of the helpers
# below wants on stdout - it would land in a Slurm log or the daemon's log - so
# the reply is captured in WRIKE_LAST_RESPONSE instead. The assignment's exit
# status is the request's, so callers still see a failure.
update_wrike_task() {
    local jq_filter="$1"
    shift

    local body
    body=$(jq -n "$@" "$jq_filter")

    WRIKE_LAST_RESPONSE=$(call_wrike_api PUT "tasks/$TASK_ID" \
      -H "Content-Type: application/json" \
      -d "$body")
}

# Set one custom field, then confirm Wrike agreed to it.
#
# A rejected custom field write comes back as 200 with the change simply omitted
# - no error, nothing in the body to distinguish it from success - so the reply's
# copy of the task's fields is the only way to know the write landed.
#
# A rejected write warns but still returns success: these fields are display
# only, and callers on the compute node run under set -e, where a non-zero return
# would abandon a finished pipeline. A transport failure still returns non-zero.
update_wrike_custom_field() {
    local custom_field_id="$1"
    local new_value="$2"

    update_wrike_task '{customFields: [{id: $id, value: $value}]}' \
        --arg id "$custom_field_id" \
        --arg value "$new_value" || return 1

    local applied
    applied=$(echo "$WRIKE_LAST_RESPONSE" \
        | jq -r --arg id "$custom_field_id" \
            '.data[0].customFields[]? | select(.id == $id) | .value')

    if [[ "$applied" != "$new_value" ]]; then
        warn "Wrike accepted the write to custom field $custom_field_id but did not apply it:" \
             "asked for \"$new_value\", field now reads \"$applied\"." \
             "Check that the field is editable and shared with the bot, and that the bot is" \
             "still a regular Wrike user - a Collaborator cannot edit fields at all."
        return 0
    fi
}

# Wrike sets a status by ID; the names are mapped in WRIKE_CUSTOM_STATUS_IDS
# above. An unmapped name is logged and skipped rather than reported.
update_wrike_task_status() {
    local new_value="$1"
    local status_id="${WRIKE_CUSTOM_STATUS_IDS[$new_value]:-}"

    if [[ -z "$status_id" ]]; then
        warn "No Wrike custom status is mapped to \"$new_value\"; status not reported."
        return 0
    fi

    update_wrike_task '{customStatus: $status}' --arg status "$status_id"
}

# The status, plus the run directory's own copy of it, which wrike_followup.sh
# reads to find out how far the run got. Only for callers inside a run directory.
update_wrike_pipeline_progress() {
    local new_value="$1"

    echo "$new_value" > status.txt

    update_wrike_task_status "$new_value"
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

# Read the request form's answers off a task into WRIKE_ANSWERS, keyed as in
# WRIKE_FORM_ANSWERS. Unanswered questions are simply absent. One customfields
# call resolves every title, since a task carries only IDs.
declare -A WRIKE_ANSWERS=()

read_wrike_answers() {
    local task_json="$1"
    local fields_json entry key title id value

    fields_json=$(call_wrike_api GET "customfields") || return 1

    WRIKE_ANSWERS=()

    for entry in "${WRIKE_FORM_ANSWERS[@]}"; do
        key=${entry%%|*}
        title=${entry#*|}
        title=${title%%|*}

        id=$(echo "$fields_json" | jq -r --arg t "$title" \
            'first(.data[] | select(.title == $t) | .id) // empty')

        [[ -n "$id" ]] || continue

        value=$(echo "$task_json" | jq -r --arg id "$id" \
            '.data[0].customFields[]? | select(.id == $id) | .value // empty')

        # One line, trimmed: every answer here is a single value
        read -r value <<< "$value" || true

        [[ -n "$value" ]] && WRIKE_ANSWERS["$key"]="$value"
    done
}

wrike_answer() {
    printf '%s' "${WRIKE_ANSWERS[$1]:-}"
}

# The ID of one custom field, by its title. Empty when Wrike has no such field.
wrike_custom_field_id() {
    call_wrike_api GET "customfields" \
        | jq -r --arg t "$1" 'first(.data[] | select(.title == $t) | .id) // empty'
}

# True when every comma-separated part of an answer is one the form offers. An
# empty allow list means the answer is checked by shape by its caller instead.
wrike_answer_allowed() {
    local key="$1" value="$2"
    local entry allowed part

    for entry in "${WRIKE_FORM_ANSWERS[@]}"; do
        [[ "${entry%%|*}" == "$key" ]] || continue

        allowed=${entry##*|}
        [[ -n "$allowed" ]] || return 0

        while IFS= read -r part; do
            [[ ",$allowed," == *",$part,"* ]] || return 1
        done <<< "${value//,/$'\n'}"

        return 0
    done

    return 1
}

# The answers the form offers for one question, for a message that has to list them
wrike_answer_options() {
    local entry

    for entry in "${WRIKE_FORM_ANSWERS[@]}"; do
        if [[ "${entry%%|*}" == "$1" ]]; then
            printf '%s' "${entry##*|}"
            return 0
        fi
    done
}
