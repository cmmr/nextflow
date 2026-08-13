#!/bin/bash
#
# ampliseq_upload.sh - Publish an ampliseq results folder and its raw reads to AWS S3.
#
# Author: Daniel Smith
# Date:   August 12th, 2026
#
# Archives the input FASTQ directory that ampliseq_samplesheet.sh built, drops the
# archive into the results folder, and copies the whole folder to
# s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/<uid>/ so clients can download both their report and
# their sequencing data. The results folder is uploaded from the inside out, so
# summary_report/summary_report.html lands directly under the task ID rather than
# under an extra results/ level - which is what S3_RESULTS_URL below points at.
# The nextflow work/ directory is deliberately left behind.
#
# The archive is stored, not compressed (zip -0): the reads are already gzipped,
# so compressing again costs CPU and saves nothing. zip stores what a symlink
# points at, so linked samples are archived as real data.
#
# Usage:     ampliseq_upload.sh [results_dir]
#            defaults to ./results, the outdir set in the ampliseq params file
# Called by: wrike_job.sh, as the POST_PROCESS_CMD of the ampliseq pipelines
# Requires:  aws, zip, curl and jq (via the Wrike helpers)
# Reads:     config/ampliseq/index.html, the landing page template
# Env:       NEXTFLOW_DIR, AWS_S3_BUCKET, S3_RUN_PREFIX, WRIKE_S3_RESULTS_URL_CFID,
#            the Wrike helper functions and the log/fail/escape_html/is_valid_uid
#            helpers, all sourced from .env
# Outputs:   ./message.out on error
#
# Does not write status.txt: wrike_job.sh marks the run Completed only after every
# post-process step it runs has succeeded.

set -euo pipefail

source /data/prod/nextflow/.env

RESULTS_DIR="${1:-results}"

# Input FASTQ directory, named to match what ampliseq_samplesheet.sh creates.
# The archive it becomes is named for the reader downloading it rather than for
# the directory it came from, since that name is what the button shows.
FASTQ_DIR="raw-sequences"
FASTQ_ZIP_NAME="raw-sequences.zip"
FASTQ_ZIP="$RESULTS_DIR/$FASTQ_ZIP_NAME"

# Written by ampliseq_samplesheet.sh, in the run directory rather than in the
# results: the number of samples after any merging
SAMPLE_COUNT_FILE="sample_count.txt"

# The page that frames the report. Both of the links it carries are relative, so
# it only works from the same prefix as the objects it points at.
readonly INDEX_TEMPLATE="$NEXTFLOW_DIR/config/ampliseq/index.html"

# The run directory is named after the uid, so results publish under the
# directory's own name - nothing to derive here. wrike_task_handler.sh confirmed
# this prefix was free before the job was ever queued.
#
# Validated because an empty value would make S3_RESULTS_DIR the whole bucket.
RUN_ID="${PWD##*/}"
if ! is_valid_uid "$RUN_ID"; then
    fail "The results could not be published: \"$PWD\" is not a run directory."
fi

# The Wrike helpers read TASK_ID from the environment, and a uid does not lead
# back to a task, so it is recorded in the run directory instead. Checked up
# here rather than where it is used: uploading results that could never be
# reported would leave the requester with nothing to collect them by.
if ! TASK_ID=$(read_wrike_task_id); then
    fail "The results could not be published: this run's Wrike task is unknown."
fi

S3_RESULTS_DIR="s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/$RUN_ID"

# The landing page, not the report itself: it frames the report under a header
# carrying the task name and the run's downloads. wrike_task_handler.sh already
# put this on the task at submission - it is re-asserted at the end because that
# call was best effort, and because this is the point at which it stops being a
# promise.
S3_RESULTS_URL=$(run_results_url "$RUN_ID")

if [[ ! -d "$RESULTS_DIR" ]]; then
    fail "The pipeline finished but produced no results directory ('$RESULTS_DIR') to upload."
fi

# The header's download buttons, built from what this run actually produced
# rather than from a fixed list: qiime2 steps can be skipped and the reads
# archive only exists for pipelines that stage their reads. A missing file gets
# no button, which is better than a button that 404s.
#
# Paths are relative to RESULTS_DIR because that is what lands at the prefix
# root, and so are the hrefs - the page is served from beside them. Each button
# is labelled with its own filename, so readers know what they are getting
# before they click and can recognize it once it lands.
add_download() {
    local path="$1"

    [[ -r "$RESULTS_DIR/$path" ]] || return 0

    DOWNLOADS+="<a class=\"download\" href=\"$(escape_html "$path")\" download>"
    DOWNLOADS+="$(escape_html "${path##*/}")</a>"
}

render_downloads() {
    DOWNLOADS=""

    add_download "$FASTQ_ZIP_NAME"

    # The ASV abundance table, carrying its taxonomy as observation metadata
    add_download "qiime2/abundance_tables/feature-table.biom"

    printf '%s' "$DOWNLOADS"
}

# 1. Archive the reads into the results folder so they upload with everything
#    else. Skipped for any pipeline that does not stage its inputs this way.
if [[ -d "$FASTQ_DIR" ]]; then
    command -v zip > /dev/null \
        || fail "The results could not be packaged for download: zip is not installed."

    log "Archiving $FASTQ_DIR for task $TASK_ID..."
    rm -f "$FASTQ_ZIP"

    # zip's output goes into the failure message, so the requester is told why
    # their data could not be packaged rather than just that it wasn't
    if ! ZIP_OUTPUT=$(zip -0 -r "$FASTQ_ZIP" "$FASTQ_DIR" 2>&1); then
        fail "The sequencing data could not be packaged for download:"$'\n'"$ZIP_OUTPUT"
    fi
else
    log "No $FASTQ_DIR directory; skipping raw sequence archive."
fi

# 2. Publish everything in one pass
log "Initiating S3 upload for Task $TASK_ID..."

# Both streams captured, so a failure can be reported back to the user
if ! UPLOAD_OUTPUT=$(aws s3 cp "$RESULTS_DIR/" "$S3_RESULTS_DIR/" --recursive 2>&1); then
    fail "The results could not be uploaded to S3:"$'\n'"$UPLOAD_OUTPUT"
fi

# 3. Land the page that frames all of it, last - it is what a reader arrives at,
#    so it should not point at objects that are still uploading. This also
#    overwrites the progress page nextflow_progress.sh has been publishing to
#    this key, which is how a reader watching the run is handed the report.
#
#    Both substituted values are HTML-escaped: the task name is whatever the
#    requester typed into Wrike, and it goes straight into the page header.
if [[ ! -r "$INDEX_TEMPLATE" ]]; then
    fail "The results were uploaded, but the page that presents them is missing from the server."
fi

#    The title is asked for again rather than taken from the copy recorded at
#    submission: the requester may have renamed the task since, and by now the
#    name is going onto a page they keep. The recorded copy is the fallback, and
#    a generic heading the one after that - a run that produced results is not
#    worth failing over its heading.
TASK_NAME=""
if TASK_JSON=$(call_wrike_api GET "tasks/$TASK_ID"); then
    TASK_NAME=$(echo "$TASK_JSON" | jq -r '.data[0].title // empty')
fi

if [[ -z "$TASK_NAME" && -r "$WRIKE_TASK_NAME_FILE" ]]; then
    warn "Could not read the current task name; using the one recorded at submission."
    read -r TASK_NAME < "$WRIKE_TASK_NAME_FILE" || true
fi

# One line: this is a page header, not a document
TASK_NAME=${TASK_NAME%%$'\n'*}
: "${TASK_NAME:=Sequencing results}"

#    The sample count carries its own separator, so a run whose count was never
#    recorded simply leaves that part of the line out. Validated as a number
#    because it is read from a file and written into the page.
SAMPLE_COUNT_HTML=""
if [[ -r "$SAMPLE_COUNT_FILE" ]]; then
    read -r SAMPLE_COUNT < "$SAMPLE_COUNT_FILE" || true

    if [[ "${SAMPLE_COUNT:-}" =~ ^[0-9]+$ && "$SAMPLE_COUNT" -gt 0 ]]; then
        SAMPLE_COUNT_HTML="&middot; $SAMPLE_COUNT samples"
        [[ "$SAMPLE_COUNT" -eq 1 ]] && SAMPLE_COUNT_HTML="&middot; 1 sample"
    else
        warn "No usable sample count in $SAMPLE_COUNT_FILE; leaving it off the page."
    fi
fi

INDEX_HTML=$(<"$INDEX_TEMPLATE")
INDEX_HTML=${INDEX_HTML//__TASK_NAME__/$(escape_html "$TASK_NAME")}
INDEX_HTML=${INDEX_HTML//__RUN_ID__/$RUN_ID}
INDEX_HTML=${INDEX_HTML//__RUN_DATE__/$(date '+%B %-d, %Y')}
INDEX_HTML=${INDEX_HTML//__SAMPLE_COUNT__/$SAMPLE_COUNT_HTML}
INDEX_HTML=${INDEX_HTML//__DOWNLOADS__/$(render_downloads)}

# --content-type because reading the body from stdin leaves aws nothing to guess
# from, and a page served as binary downloads instead of rendering.
if ! UPLOAD_OUTPUT=$(printf '%s\n' "$INDEX_HTML" \
        | aws s3 cp - "$S3_RESULTS_DIR/index.html" --content-type "text/html" 2>&1); then
    fail "The results were uploaded, but the page that presents them was not:"$'\n'"$UPLOAD_OUTPUT"
fi

update_wrike_custom_field "$WRIKE_S3_RESULTS_URL_CFID" "$S3_RESULTS_URL"
log "Upload successful: $S3_RESULTS_URL"
