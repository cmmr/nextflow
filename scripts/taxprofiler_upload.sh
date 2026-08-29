#!/bin/bash
#
# taxprofiler_upload.sh - Publish a taxprofiler results folder to AWS S3.
#
# Author: Daniel Smith
# Date:   August 19th, 2026
#
# Gives every folder below the results root a listing page, copies the folder to
# s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/<uid>/ from the inside out - so
# multiqc/multiqc_report.html lands directly under the uid - and lands the page
# that frames it last. Nextflow's work/ directory is left behind.
#
# The raw reads are not published with the results: a WGS run's inputs are large
# enough that packaging and uploading them costs more than the analysis did, and
# the requester already holds them. The page keeps a hidden row for the link
# that will offer them from the cluster instead - see dashboard_link_button.
#
# The pages a reader sees are publish_dashboard.sh's, filled in from what this
# run actually produced: which reports the navigation bar offers, which files
# the Overview's sidebar offers, how the run was set up, and which of the
# outputs named in templates/taxprofiler/outputs.conf exist.
#
# Usage:     taxprofiler_upload.sh [results_dir]
#            defaults to ./results, the outdir set in the taxprofiler params file
# Called by: wrike_job.sh, as the POST_PROCESS_CMDS entry of the taxprofiler pipelines
# Requires:  aws, curl and jq (via the Wrike helpers)
# Reads:     templates/dashboard.html, templates/overview.html,
#            templates/files.html and templates/taxprofiler/outputs.conf, via
#            the dashboard helpers; ./pipeline_manifest.json from the run
#            directory
# Runs:      index_directories.sh, over the results folder
# Env:       NEXTFLOW_DIR, AWS_S3_BUCKET, S3_RUN_PREFIX, WRIKE_DASHBOARD_URL_CFID,
#            the Wrike and dashboard helper functions and the log/fail/is_valid_uid
#            helpers, all sourced from .env
# Outputs:   ./message.out on error
#
# Does not write status.txt: wrike_job.sh marks the run Completed only after every
# post-process step it runs has succeeded.

set -euo pipefail

source /data/prod/nextflow/.env

RESULTS_DIR="${1:-results}"
RESULTS_DIR="${RESULTS_DIR%/}"

# Written by taxprofiler_samplesheet.sh, in the run directory rather than in the
# results: the number of distinct samples
SAMPLE_COUNT_FILE="sample_count.txt"

# Also written per run by taxprofiler_samplesheet.sh, and published with the
# results as part of the record
DB_SHEET="taxprofiler_database.csv"

# Written by wrike_job.sh, and read here for the settings the page names: which
# pipeline version ran, and what it was told to deplete against
RUN_MANIFEST="pipeline_manifest.json"

# What the page calls the analysis, under the task's own name
SUBTITLE="Shotgun metagenomic taxonomic profiling"

# What the landing page's "All output files" view lists, in the order it lists it
readonly OUTPUT_CATALOG="$NEXTFLOW_DIR/templates/taxprofiler/outputs.conf"

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

# 1. Ship the database sheet with the results. wrike_job.sh copies the command
#    record and the params files; this one is generated per run by
#    taxprofiler_samplesheet.sh, and it carries the Bracken read length the run
#    actually used. The input samplesheet is left behind: it names the
#    requester's own paths on the cluster.
if [[ -r "$DB_SHEET" ]]; then
    cp "$DB_SHEET" "$RESULTS_DIR/" || warn "Could not publish $DB_SHEET with the results."
fi

# 2. Give every folder below the results root a listing page, so that the folder
#    links the report and the landing page carry still resolve once the results
#    are objects in a bucket rather than directories on disk.
if ! "$NEXTFLOW_DIR/scripts/index_directories.sh" "$RESULTS_DIR"; then
    warn "The results folders could not be indexed; their listings will be missing."
fi

# 3. Publish everything below the landing page
log "Initiating S3 upload for Task $TASK_ID..."

if ! UPLOAD_OUTPUT=$(upload_results_tree "$RESULTS_DIR" "$S3_RESULTS_DIR"); then
    fail "The results could not be uploaded to S3:"$'\n'"$UPLOAD_OUTPUT"
fi

# 4. Build the page that frames all of it, from what the run produced.
dashboard_reset "$RESULTS_DIR" "$OUTPUT_CATALOG"

dashboard_view quality "Quality Control" "multiqc/multiqc_report.html"
dashboard_index_view   "File Explorer"

#    The interactive classification charts, one per tool and database, and
#    taxpasta's merged profiles. The raw reads follow them as a row that stays
#    hidden until it is given the address they are served from.
dashboard_button "krona/*.html"
dashboard_button "taxpasta/*.tsv"
dashboard_link_button "" "Raw sequencing data"

#    How the run was set up, as the sidebar states it: what was depleted before
#    classification, and what was classified against. The databases are named by
#    the sheet the run was given, one row per tool.
PIPELINE=""

if [[ -r "$RUN_MANIFEST" ]]; then
    PIPELINE=$(jq -r '.pipeline // empty' "$RUN_MANIFEST") || true
else
    warn "No $RUN_MANIFEST in the run directory; the page will not name the pipeline."
fi

HOST_REMOVAL=$(form_answer hostremoval_reference)
: "${HOST_REMOVAL:=PhiX}"

DATABASES=""
if [[ -r "$DB_SHEET" ]]; then
    DATABASES=$(awk -F, 'NR > 1 && $2 != "" && !seen[$2]++ {
        printf "%s%s", (n++ ? ", " : ""), $2
    }' "$DB_SHEET")
fi

dashboard_stat_group "RUN CONFIGURATION"
dashboard_stat_row   "Host removal" "$HOST_REMOVAL"
dashboard_stat_row   "Databases"    "$DATABASES"

#    The title is read from Wrike rather than taken from the copy recorded at
#    submission, since the requester may have renamed the task since. That copy
#    is the fallback, and a generic heading the one after that. The same reply
#    carries the date the dashboard is torn down on.
TASK_NAME=""
EXPIRES_ON=""

if TASK_JSON=$(call_wrike_api GET "tasks/$TASK_ID"); then
    TASK_NAME=$(echo "$TASK_JSON" | jq -r '.data[0].title // empty')
    EXPIRES_ON=$(wrike_dashboard_expiration "$TASK_JSON") \
        || warn "Could not work out when this dashboard expires; the page will not say."
fi

if [[ -z "$TASK_NAME" && -r "$WRIKE_TASK_NAME_FILE" ]]; then
    warn "Could not read the current task name; using the one recorded at submission."
    read -r TASK_NAME < "$WRIKE_TASK_NAME_FILE" || true
fi

# One line: this is a page header, not a document
TASK_NAME=${TASK_NAME%%$'\n'*}
: "${TASK_NAME:=Sequencing results}"

#    How many samples the header says this run covers. A count that was never
#    recorded, or that is not a number, leaves that note off the header
#    altogether. Validated because it is read from a file and written into the
#    page.
SAMPLE_COUNT=""
if [[ -r "$SAMPLE_COUNT_FILE" ]]; then
    read -r SAMPLE_COUNT < "$SAMPLE_COUNT_FILE" || true

    if [[ ! "${SAMPLE_COUNT:-}" =~ ^[0-9]+$ ]]; then
        warn "No usable sample count in $SAMPLE_COUNT_FILE; leaving it off the page."
        SAMPLE_COUNT=""
    fi
fi

# 5. Land the pages last, once nothing they point at is still uploading. The
#    landing page overwrites the progress page published to this key.
if ! UPLOAD_OUTPUT=$(publish_dashboard "$S3_RESULTS_DIR" "$RUN_ID" "$TASK_NAME" \
        "$SUBTITLE" "$PIPELINE" "$(date '+%b %-d, %Y')" "$SAMPLE_COUNT" \
        "$EXPIRES_ON"); then
    fail "The results were uploaded, but the pages that present them were not:"$'\n'"$UPLOAD_OUTPUT"
fi

update_wrike_custom_field "$WRIKE_DASHBOARD_URL_CFID" "$S3_RESULTS_URL"
log "Upload successful: $S3_RESULTS_URL"
