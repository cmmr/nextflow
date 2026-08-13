#
# utilities.sh - The log, warn, and fail helpers every script reports through,
#                plus the uid helpers.
#
# Author: Daniel Smith
# Date:   August 12th, 2026
#
# Sourced by .env rather than executed, so these are available to any script that
# sources .env - including wrike_api.sh, which reports through them itself.
#
# All three stamp the time:
#
#   log   a plain line on stdout
#   warn  the same, marked WARNING; the script carries on regardless
#   fail  an ERROR on stderr, then exit 1, so the caller stops where it stands
#
# fail also copies its message - unstamped - to ./message.out when that file
# exists. That is how a compute node explains itself to the requester:
# wrike_task_handler.sh creates message.out with the run directory, and
# wrike_followup.sh posts whatever ends up in it back to the Wrike task once the
# job ends. Elsewhere there is no such file, so the copy is skipped.
#
# The uid helpers are here rather than in wrike_api.sh because nothing about a
# uid is Wrike's: it names a directory, a job, and an S3 prefix, and only takes
# a task ID because that is what the system happens to key on.
#
# Defines: log, warn, fail, run_results_url, escape_html, is_valid_uid, derive_uid
# Env:     RUN_ID_SALT from secrets/.env, for derive_uid only; AWS_S3_BUCKET and
#          S3_RUN_PREFIX for run_results_url

log() {
    echo "[$(date)] $*"
}

warn() {
    echo "[$(date)] WARNING: $*"
}

fail() {
    echo "[$(date)] ERROR: $*" >&2

    # Truncate rather than append: the first failure explains the run, and
    # anything after it is a consequence of that one
    if [[ -f message.out ]]; then
        echo "$*" > message.out
    fi

    exit 1
}

# Where a run's results live, as a reader sees it. Built here rather than at
# each call site because two scripts write this exact string onto the Wrike task
# - wrike_task_handler.sh at submission and ampliseq_upload.sh at the end - and
# a run whose task points somewhere its results are not is worse than one with
# no link at all.
#
# index.html rather than the report itself: that key holds the progress page
# while the run is going and the finished report afterwards, so the address is
# good from the moment the job is queued.
run_results_url() {
    printf 'https://%s/%s/%s/index.html' "$AWS_S3_BUCKET" "$S3_RUN_PREFIX" "$1"
}

# Make a string safe to drop into HTML text. Used on the Wrike task name, which
# heads both published pages and is whatever the requester typed into a form.
# Ampersand first, or it would go back over its own replacements.
escape_html() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

# A uid is the name a run is known by everywhere except Wrike: the run
# directory, the Slurm job name, and the S3 prefix its results are published
# under. It is derived from the Wrike task ID, which cannot serve as any of
# those itself: Wrike may issue IDs containing ":" and "=", which S3 asks to be
# URL-encoded and which Apptainer reads as bind-spec separators, and at up to
# 256 characters they can also outrun a 255-byte path component.
#
# Derived rather than randomly generated because nothing stores the mapping in
# that direction. A successful run's directory is deleted, and
# wrike_delete_handler.sh has only a task ID to clean up from - by then the task
# itself is gone from Wrike, so there is nothing left to look the uid up in.
# Recomputing it is what keeps teardown possible, and it also means a redelivered
# SQS event lands on the same uid instead of orphaning a second copy of a run.
#
# The reverse direction is not derivable, so a run that needs its task ID back
# reads it out of wrike_task_id.txt; see read_wrike_task_id in wrike_api.sh.
#
# 8 base32 characters is 40 bits: across 1000 runs, roughly a 1 in 2.2e6 chance
# that any two tasks derive the same uid, and 1 in 2.2e4 across 10,000. Short
# enough to keep a results URL readable, and affordable only because
# wrike_task_handler.sh checks the S3 prefix is unused before accepting a
# request - a collision is a rejected request the requester can retry, not one
# client's results overwriting another's. Lengthening it later is a one-character
# change here and in derive_uid, but it strands everything already published.
is_valid_uid() {
    [[ "$1" =~ ^[a-z2-7]{8}$ ]]
}

# warn and return rather than fail: callers read this through $(...), and fail's
# exit would only leave that subshell. Every call site checks the return status
# and decides for itself how to report the failure.
derive_uid() {
    if [[ -z "${RUN_ID_SALT:-}" ]]; then
        warn "RUN_ID_SALT is not set; cannot derive a uid."
        return 1
    fi

    # HMAC rather than a plain digest: the uid is handed to clients as part of a
    # URL, so knowing a task ID must not be enough to compute where someone
    # else's results are published. Lowercased because the URL may be retyped,
    # and base32 for the same reason - no 0/O or 1/l pair to misread.
    local uid
    uid=$(printf '%s' "$1" \
        | openssl dgst -sha256 -hmac "$RUN_ID_SALT" -binary \
        | base32 -w 0 \
        | tr 'A-Z' 'a-z' \
        | cut -c1-8)

    # Emit a whole uid or none at all. Callers append this to
    # "s3://$AWS_S3_BUCKET/" and to "$NEXTFLOW_DIR/tmp/", where an empty value
    # silently addresses the entire bucket or the whole tmp directory - and both
    # of those get handed to a recursive delete. Checked here rather than
    # trusted to set -e, which does not fire on an assignment from a failed
    # command substitution.
    if ! is_valid_uid "$uid"; then
        warn "Derived an unusable uid from \"$1\"; is openssl working?"
        return 1
    fi

    printf '%s' "$uid"
}
