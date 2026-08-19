#
# utilities.sh - The log, warn, and fail helpers every script reports through,
#                plus the uid helpers.
#
# Author: Daniel Smith
# Date:   August 12th, 2026
#
# Sourced by .env rather than executed.
#
#   log   a plain line on stdout
#   warn  the same on stderr, marked WARNING; the script carries on
#   fail  an ERROR on stderr, then exit 1
#
# Only log writes to stdout, which keeps stdout free to carry a function's return
# value - several helpers here hand their result back through $(...).
#
# fail also copies its message, unstamped, to ./message.out when that file
# exists. That is how a compute node explains itself to the requester:
# wrike_task_handler.sh creates message.out in the run directory, and
# wrike_followup.sh posts whatever ends up there back to the Wrike task.
#
# Defines: log, warn, fail, run_results_url, escape_html, is_valid_uid, derive_uid
# Env:     RUN_ID_SALT from secrets/.env, for derive_uid only; AWS_S3_BUCKET and
#          S3_RUN_PREFIX for run_results_url

log() {
    echo "[$(date)] $*"
}

warn() {
    echo "[$(date)] WARNING: $*" >&2
}

fail() {
    echo "[$(date)] ERROR: $*" >&2

    # Truncate rather than append: the first failure explains the run
    if [[ -f message.out ]]; then
        echo "$*" > message.out
    fi

    exit 1
}

# Where a run's results live, as a reader sees it. Two scripts write this exact
# string onto the Wrike task - wrike_task_handler.sh once the request has claimed
# its S3 prefix, and ampliseq_upload.sh at the end - so it is spelled once here.
#
# index.html holds the progress page while the run is going and the finished
# report afterwards.
run_results_url() {
    printf 'https://%s/%s/%s/index.html' "$AWS_S3_BUCKET" "$S3_RUN_PREFIX" "$1"
}

# Make a string safe to drop into HTML text. Used on the Wrike task name, which
# heads both published pages. Ampersand first, or it would go back over its own
# replacements.
escape_html() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

# A uid is the name a run is known by everywhere except Wrike: the run directory,
# the Slurm job name, and the S3 prefix its results are published under. Eight
# base32 characters, derived from the Wrike task ID.
#
# Every script that builds a path or an S3 prefix from a uid checks it here
# first, since several of those paths are handed to a recursive delete.
is_valid_uid() {
    [[ "$1" =~ ^[a-z2-7]{8}$ ]]
}

# Turn a Wrike task ID into that uid. Derived rather than stored, so anything
# holding a task ID can recompute it - which is what lets wrike_delete_handler.sh
# find a run to tear down after its task is gone. The reverse direction is not
# derivable; a run reads its task ID back from wrike_task_id.txt.
#
# HMAC rather than a plain digest, so knowing a task ID is not enough to compute
# where someone else's results are published. Lowercase base32: no 0/O or 1/l
# pair to misread in a URL.
#
# warn and return rather than fail: callers read this through $(...), where
# fail's exit would only leave that subshell. warn writes to stderr, so it does
# not land in the captured uid.
derive_uid() {
    if [[ -z "${RUN_ID_SALT:-}" ]]; then
        warn "RUN_ID_SALT is not set; cannot derive a uid."
        return 1
    fi

    local uid
    uid=$(printf '%s' "$1" \
        | openssl dgst -sha256 -hmac "$RUN_ID_SALT" -binary \
        | base32 -w 0 \
        | tr 'A-Z' 'a-z' \
        | cut -c1-8)

    # Emit a whole uid or none at all: callers append this to
    # "s3://$AWS_S3_BUCKET/" and to "$NEXTFLOW_DIR/tmp/", and an empty value
    # would address the entire bucket or the whole tmp directory.
    if ! is_valid_uid "$uid"; then
        warn "Derived an unusable uid from \"$1\"; is openssl working?"
        return 1
    fi

    printf '%s' "$uid"
}
