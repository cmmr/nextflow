#!/bin/bash
#
# taxprofiler_upload.sh - Publish a taxprofiler results folder to AWS S3.
#
# Author: Daniel Smith
# Date:   August 19th, 2026
#
# Archives the input FASTQ directory that taxprofiler_samplesheet.sh built, drops
# the archive into the results folder, gives every folder below the results root
# a listing page, copies the folder to s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/<uid>/
# from the inside out - so multiqc/multiqc_report.html lands directly under the
# uid - and lands the page that frames it last. Nextflow's work/ directory is
# left behind.
#
# The archive is stored, not compressed (zip -0): the reads are already gzipped.
# zip stores what a symlink points at, so linked samples are archived as real
# data. A WGS run's reads are large, so this needs free space in the run
# directory equal to the input volume.
#
# Usage:     taxprofiler_upload.sh [results_dir]
#            defaults to ./results, the outdir set in the taxprofiler params file
# Called by: wrike_job.sh, as the POST_PROCESS_CMD of the taxprofiler pipelines
# Requires:  aws, zip, curl and jq (via the Wrike helpers)
# Reads:     templates/taxprofiler/index.html, the landing page template
# Runs:      index_directories.sh, over the results folder
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
RESULTS_DIR="${RESULTS_DIR%/}"

# Input FASTQ directory, named to match what taxprofiler_samplesheet.sh creates.
# The archive it becomes is named for the reader downloading it.
FASTQ_DIR="raw-sequences"
FASTQ_ZIP_NAME="raw-sequences.zip"
FASTQ_ZIP="$RESULTS_DIR/$FASTQ_ZIP_NAME"

# Written by taxprofiler_samplesheet.sh, in the run directory rather than in the
# results: the number of distinct samples
SAMPLE_COUNT_FILE="sample_count.txt"

# The page that frames the report. Both of the links it carries are relative, so
# it only works from the same prefix as the objects it points at.
readonly INDEX_TEMPLATE="$NEXTFLOW_DIR/templates/taxprofiler/index.html"

# The run directory is named after the uid, so results publish under the
# directory's own name. Validated because an empty value would make
# S3_RESULTS_DIR the whole bucket.
RUN_ID="${PWD##*/}"
if ! is_valid_uid "$RUN_ID"; then
    fail "The results could not be published: \"$PWD\" is not a run directory."
fi

# The Wrike helpers read TASK_ID from the environment, and a uid does not lead
# back to a task, so it is recorded in the run directory instead.
if ! TASK_ID=$(read_wrike_task_id); then
    fail "The results could not be published: this run's Wrike task is unknown."
fi

S3_RESULTS_DIR="s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/$RUN_ID"
S3_RESULTS_URL=$(run_results_url "$RUN_ID")

if [[ ! -d "$RESULTS_DIR" ]]; then
    fail "The pipeline finished but produced no results directory ('$RESULTS_DIR') to upload."
fi

# One button per file matching a glob under RESULTS_DIR, labelled with its own
# filename. "view" opens in a new tab, anything else downloads. Paths and hrefs
# are relative to RESULTS_DIR, which is what lands at the prefix root.
add_buttons() {
    local mode="$1"
    local pattern="$2"
    local path name

    for path in "$RESULTS_DIR"/$pattern; do
        [[ -r "$path" ]] || continue

        name=${path#"$RESULTS_DIR/"}
        DOWNLOADS+="<a class=\"download\" href=\"$(escape_html "$name")\""

        if [[ "$mode" == view ]]; then
            DOWNLOADS+=" target=\"_blank\" rel=\"noopener\">"
        else
            DOWNLOADS+=" download>"
        fi

        DOWNLOADS+="$(escape_html "${name##*/}")</a>"
    done
}

# Built from what this run actually produced: a profiler can be turned off, and
# krona covers only some of them. A missing file gets no button.
render_downloads() {
    DOWNLOADS=""

    # The reads are the bulky download most people came for
    add_buttons download "$FASTQ_ZIP_NAME"

    # Interactive classification charts, one per tool and database
    add_buttons view "krona/*.html"

    # taxpasta's merged profiles, one table per tool and database
    add_buttons download "taxpasta/*.tsv"

    printf '%s' "$DOWNLOADS"
}

# 1. Archive the reads into the results folder so they upload with everything
#    else. Skipped for any pipeline that does not stage its inputs this way.
if [[ -d "$FASTQ_DIR" ]]; then
    command -v zip > /dev/null         || fail "The results could not be packaged for download: zip is not installed."

    log "Archiving $FASTQ_DIR for task $TASK_ID..."
    rm -f "$FASTQ_ZIP"

    # zip's output goes into the failure message, so the requester is told why
    # their data could not be packaged
    if ! ZIP_OUTPUT=$(zip -0 -r "$FASTQ_ZIP" "$FASTQ_DIR" 2>&1); then
        fail "The sequencing data could not be packaged for download:"$'
'"$ZIP_OUTPUT"
    fi
else
    log "No $FASTQ_DIR directory; skipping raw sequence archive."
fi

# 2. Give every folder below the results root a listing page, so that the folder
#    links multiqc_report.html carries still resolve once the results are objects
#    in a bucket rather than directories on disk.
if ! "$NEXTFLOW_DIR/scripts/index_directories.sh" "$RESULTS_DIR"; then
    warn "The results folders could not be indexed; their listings will be missing."
fi

# 3. Publish everything in one pass
log "Initiating S3 upload for Task $TASK_ID..."

if ! UPLOAD_OUTPUT=$(aws s3 cp "$RESULTS_DIR/" "$S3_RESULTS_DIR/" --recursive 2>&1); then
    fail "The results could not be uploaded to S3:"$'\n'"$UPLOAD_OUTPUT"
fi

# 4. Land the page that frames all of it last, once nothing it points at is still
#    uploading. This overwrites the progress page published to this key.
if [[ ! -r "$INDEX_TEMPLATE" ]]; then
    fail "The results were uploaded, but the page that presents them is missing from the server."
fi

#    The title is read from Wrike rather than taken from the copy recorded at
#    submission, since the requester may have renamed the task since. That copy
#    is the fallback, and a generic heading the one after that.
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
#    recorded leaves that part of the line out. Validated as a number because it
#    is read from a file and written into the page.
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

# The task name is whatever the requester typed into Wrike, and it goes straight
# into the page header, so it is HTML-escaped on the way in. DOWNLOADS is markup
# the renderer escaped itself.
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
