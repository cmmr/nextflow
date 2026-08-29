#
# pipeline_params.sh - The parameter map a pipeline's params file is built from.
#
# Author: Daniel Smith
# Date:   August 25th, 2026
#
# Sourced by .env rather than executed.
#
# A pipeline file no longer writes its params file itself. It calls params_set
# for each default, and wrike_job.sh writes the file after the pre-process stage
# has run - late enough that a step which measures the data, such as
# ampliseq_detect_region.sh, can contribute parameters of its own.
#
# The map is layered. Each layer overwrites the keys it names and leaves the rest
# alone, so all of these end up in one params file:
#
#   1. the pipeline file's defaults, plus whatever it makes of the request form's
#      answers, which it reads with form_answer
#   2. detected_params.yaml, from the pre-process stage
#   3. a rerun's recorded params, which pin everything
#
# PIPELINE_PARAM_ORDER keeps insertion order, which the associative array does
# not, so a params file reads in the order the pipeline declared it.
#
# Values are scalars. YAML lists and maps are not supported; nf-core accepts a
# comma-separated string wherever this system needs more than one value.
#
# Defines: params_reset, params_set, params_get, params_has, params_unset,
#          params_load, params_write, params_json, form_answer, PIPELINE_PARAMS,
#          PIPELINE_PARAM_ORDER
# Requires: jq, for params_json; the warn and fail helpers from utilities.sh,
#           and state_get from run_state.sh for form_answer

declare -A PIPELINE_PARAMS=()
declare -a PIPELINE_PARAM_ORDER=()

# The two characters params_write escapes and params_load puts back. Held in
# variables because a ${var//pattern/} pattern ending in a lone backslash matches
# nothing, whatever it is quoted with. Not readonly: .env sources this, and .env
# is safe to source any number of times.
PARAMS_BACKSLASH='\'
PARAMS_QUOTE='"'

params_reset() {
    PIPELINE_PARAMS=()
    PIPELINE_PARAM_ORDER=()
}

# True when the argument could be an nf-core parameter name; a key is written
# unquoted into a YAML file.
params_valid_key() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

params_set() {
    local key="$1"
    local value="$2"

    if ! params_valid_key "$key"; then
        fail "\"$key\" is not a usable pipeline parameter name."
    fi

    # Tabs are the separator params_json builds its JSON from, and a newline
    # would end the line a value is written on
    if [[ "$value" == *$'\t'* || "$value" == *$'\n'* ]]; then
        fail "The value of \"$key\" may not contain tabs or newlines."
    fi

    if [[ -z "${PIPELINE_PARAMS[$key]+set}" ]]; then
        PIPELINE_PARAM_ORDER+=("$key")
    fi

    PIPELINE_PARAMS["$key"]="$value"
}

params_get() {
    printf '%s' "${PIPELINE_PARAMS[$1]:-}"
}

params_has() {
    [[ -n "${PIPELINE_PARAMS[$1]+set}" ]]
}

# Leaves the key in PIPELINE_PARAM_ORDER; params_write skips names the map no
# longer holds.
params_unset() {
    unset "PIPELINE_PARAMS[$1]"
}

# Apply one layer, given as "key: value" lines. Blank lines and # comments are
# skipped; surrounding whitespace and one level of quoting are stripped, so a
# file params_write produced reads back unchanged.
params_load() {
    local file="$1"
    local line key value

    [[ -r "$file" ]] || fail "Cannot read the parameters in \"$file\"."

    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line//$'\r'/}

        # Trim both ends
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}

        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" != *:* ]]; then
            fail "\"$file\" has a line that is not a \"name: value\" pair: $line"
        fi

        key=${line%%:*}
        value=${line#*:}

        key=${key%"${key##*[![:space:]]}"}
        value=${value#"${value%%[![:space:]]*}"}

        if ! params_valid_key "$key"; then
            fail "\"$key\" in \"$file\" is not a usable pipeline parameter name."
        fi

        # One level of quoting, matching what params_write emits. Both patterns
        # are expanded from variables: a pattern ending in a lone backslash
        # matches nothing.
        if [[ ${#value} -ge 2 && "$value" == \"*\" ]]; then
            value=${value:1:${#value}-2}
            value=${value//"$PARAMS_BACKSLASH$PARAMS_QUOTE"/"$PARAMS_QUOTE"}
            value=${value//"$PARAMS_BACKSLASH$PARAMS_BACKSLASH"/"$PARAMS_BACKSLASH"}
        elif [[ ${#value} -ge 2 && "$value" == \'*\' ]]; then
            value=${value:1:${#value}-2}
        fi

        params_set "$key" "$value"
    done < "$file"
}

# Write the map as the params file nextflow reads. Booleans, numbers and null go
# in bare so nextflow types them; everything else is quoted, with backslashes and
# double quotes escaped.
params_write() {
    local file="$1"
    local key value

    : > "$file"

    for key in "${PIPELINE_PARAM_ORDER[@]}"; do
        params_has "$key" || continue

        value="${PIPELINE_PARAMS[$key]}"

        if [[ "$value" =~ ^(true|false|null)$ || "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
            printf '%s: %s\n' "$key" "$value" >> "$file"
        else
            value=${value//"$PARAMS_BACKSLASH"/"$PARAMS_BACKSLASH$PARAMS_BACKSLASH"}
            value=${value//"$PARAMS_QUOTE"/"$PARAMS_BACKSLASH$PARAMS_QUOTE"}
            printf '%s: "%s"\n' "$key" "$value" >> "$file"
        fi
    done
}

# The same map as a JSON object, for the run manifest a rerun is rebuilt from.
# Every value is a JSON string; params_write retypes them on the way back out.
params_json() {
    local key

    for key in "${PIPELINE_PARAM_ORDER[@]}"; do
        params_has "$key" || continue
        printf '%s\t%s\n' "$key" "${PIPELINE_PARAMS[$key]}"
    done | jq -R -s 'split("\n")
        | map(select(length > 0) | split("\t") | {(.[0]): (.[1] // "")})
        | add // {}'
}

# One checked request form answer, from the run's state file, where
# wrike_task_handler.sh records them under "answers". Empty when the question
# was not answered, which is what a pipeline reads as "use my own default".
form_answer() {
    state_get "$WRIKE_FORM_ANSWERS_KEY.$1"
}
