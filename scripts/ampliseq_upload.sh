#!/bin/bash
#
# ampliseq_upload.sh - Publish an ampliseq results folder and its raw reads to AWS S3.
#
# Author: Daniel Smith
# Date:   August 12th, 2026
#
# Archives the input FASTQ directory that ampliseq_samplesheet.sh built, drops the
# archive into the results folder, and copies the whole folder to
# s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/<uid>/ so clients can download both their
# report and their sequencing data. The results folder is uploaded from the
# inside out, so summary_report/summary_report.html lands directly under the uid
# rather than under an extra results/ level. Nextflow's work/ directory is left
# behind.
#
# The folders go up browsable: index_directories.sh gives each one a
# directory_listing.html first, since a bucket has no directories for the
# report's folder links to land on. The one such link the report writes as "../"
# is repointed at the listing for the results folder, since a folder URL for the
# top of a run is the dashboard the report is being read inside.
#
# ampliseq_composition.sh runs before both, and leaves behind the diversity table
# and the data the Overview's two plots are drawn from.
#
# The archive is stored, not compressed (zip -0): the reads are already gzipped.
# zip stores what a symlink points at, so linked samples are archived as real
# data.
#
# The pages a reader sees are publish_dashboard.sh's, filled in from what this
# run actually produced: which reports the navigation bar offers, what the
# Overview plots, which files its sidebar offers, what the run measured, and
# which of the outputs named in templates/ampliseq/outputs.conf exist. The plots
# and the numbers beside them are what ampliseq_composition.sh left in
# composition_data.json and run_statistics.tsv, and the settings stated beside
# them come off the manifest wrike_job.sh recorded.
#
# Usage:     ampliseq_upload.sh [results_dir]
#            defaults to ./results, the outdir set in the ampliseq params file
# Called by: wrike_job.sh, as the POST_PROCESS_CMDS entry of the ampliseq pipeline
# Requires:  aws, zip, curl and jq (via the Wrike helpers)
# Reads:     templates/dashboard.html, templates/overview.html,
#            templates/files.html and templates/ampliseq/outputs.conf, via the
#            dashboard helpers; ./composition_data.json, ./run_statistics.tsv
#            and ./pipeline_manifest.json from the run directory
# Runs:      ampliseq_composition.sh and index_directories.sh, over the results
#            folder
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

# Input FASTQ directory, named to match what ampliseq_samplesheet.sh creates.
# The archive it becomes is named for the reader downloading it, since that name
# is what the button shows.
FASTQ_DIR="raw-sequences"
FASTQ_ZIP_NAME="raw-sequences.zip"
FASTQ_ZIP="$RESULTS_DIR/$FASTQ_ZIP_NAME"

# Written by ampliseq_samplesheet.sh, in the run directory rather than in the
# results: the number of samples after any merging
SAMPLE_COUNT_FILE="sample_count.txt"

# The headline numbers ampliseq_composition.sh counted out of the ASV and
# abundance tables, as key and value, for the Overview's sidebar
STATS_FILE="run_statistics.tsv"

# What that script left for the Overview's two plots to draw, or nothing when
# the run produced no tables to plot
PLOT_DATA_FILE="composition_data.json"

# Written by wrike_job.sh, and read here for the settings the page names: which
# pipeline version ran, which region it measured, and what it classified against
RUN_MANIFEST="pipeline_manifest.json"

# What the page calls the analysis, under the task's own name
SUBTITLE="16S rRNA amplicon sequencing analysis"

# ampliseq's own account of the run, and the first thing the dashboard shows
SUMMARY_REPORT="$RESULTS_DIR/summary_report/summary_report.html"

# What the landing page's "All output files" view lists, in the order it lists it
readonly OUTPUT_CATALOG="$NEXTFLOW_DIR/templates/ampliseq/outputs.conf"

# The run directory is named after the uid, so results publish under the
# directory's own name. Validated because an empty value would make
# S3_RESULTS_DIR the whole bucket.
RUN_ID="${PWD##*/}"
if ! is_valid_uid "$RUN_ID"; then
    fail "The results could not be published: \"$PWD\" is not a run directory."
fi

# The Wrike helpers read TASK_ID from the environment, and a uid does not lead
# back to a task, so it is recorded in the run directory instead. Checked before
# the upload, since results nothing can report are of no use to the requester.
if ! TASK_ID=$(read_wrike_task_id); then
    fail "The results could not be published: this run's Wrike task is unknown."
fi

S3_RESULTS_DIR="s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/$RUN_ID"

# The landing page, not the report itself. wrike_task_handler.sh put this on the
# task when the request was picked up; re-asserted here because that call was
# best effort.
S3_RESULTS_URL=$(run_results_url "$RUN_ID")

if [[ ! -d "$RESULTS_DIR" ]]; then
    fail "The pipeline finished but produced no results directory ('$RESULTS_DIR') to upload."
fi

# 1. Archive the reads into the results folder so they upload with everything
#    else. Skipped for any pipeline that does not stage its inputs this way.
if [[ -d "$FASTQ_DIR" ]]; then
    command -v zip > /dev/null \
        || fail "The results could not be packaged for download: zip is not installed."

    log "Archiving $FASTQ_DIR for task $TASK_ID..."
    rm -f "$FASTQ_ZIP"

    # zip's output goes into the failure message, so the requester is told why
    # their data could not be packaged
    if ! ZIP_OUTPUT=$(zip -0 -r "$FASTQ_ZIP" "$FASTQ_DIR" 2>&1); then
        fail "The sequencing data could not be packaged for download:"$'\n'"$ZIP_OUTPUT"
    fi
else
    log "No $FASTQ_DIR directory; skipping raw sequence archive."
fi

# 2. Work out the two things a requester asks for first - what was in each
#    sample, and how varied each sample was - for the Overview to plot. Ahead of
#    the listings, so the table it leaves in the results is in them.
if ! "$NEXTFLOW_DIR/scripts/ampliseq_composition.sh" "$RESULTS_DIR"; then
    warn "The composition and diversity data could not be built; the plots will be missing."
fi

# 3. Give every folder below the results root a listing page, so that the folder
#    links the report and the landing page carry still resolve once the results
#    are objects in a bucket rather than directories on disk.
if ! "$NEXTFLOW_DIR/scripts/index_directories.sh" "$RESULTS_DIR"; then
    warn "The results folders could not be indexed; their listings will be missing."
fi

# 4. Send the report's link to the "base results folder" to the listing page for
#    it. That link is written as "../", which resolves to the landing page this
#    report is being read inside of - so following it opens a second copy of the
#    dashboard in the dashboard's own frame. index_directories.sh has just
#    written the listing the reader was actually after.
if [[ -w "$SUMMARY_REPORT" ]]; then
    sed -i 's|href="\.\./"|href="../directory_listing.html"|g' "$SUMMARY_REPORT" \
        || warn "The report's link to the results folder could not be redirected."
fi

# 5. Publish everything below the landing page
log "Initiating S3 upload for Task $TASK_ID..."

if ! UPLOAD_OUTPUT=$(upload_results_tree "$RESULTS_DIR" "$S3_RESULTS_DIR"); then
    fail "The results could not be uploaded to S3:"$'\n'"$UPLOAD_OUTPUT"
fi

# 6. Build the pages that frame all of it, from what the run produced.
dashboard_reset "$RESULTS_DIR" "$OUTPUT_CATALOG"

#    The navigation bar, after the Overview every run opens on
dashboard_view report  "Analysis Report" "summary_report/summary_report.html"
dashboard_view quality "Quality Control" "multiqc/multiqc_report.html"
dashboard_index_view   "File Explorer"

#    The reads are the bulky download most people came for; the ASV table
#    carries its taxonomy as observation metadata
dashboard_button "$FASTQ_ZIP_NAME"
dashboard_button "qiime2/abundance_tables/feature-table.biom"

#    How the run was set up. Every value comes off the manifest wrike_job.sh
#    recorded, so the page and the record cannot disagree; anything it does not
#    carry leaves its note off the sidebar. Each is stated over the numbers it
#    explains rather than in a row of its own - what was amplified and what read
#    it over the read totals, what they were classified against over the
#    classification.
PIPELINE=""
REGION=""
REF_TAXONOMY=""
SEQUENCING_TYPE=""

if [[ -r "$RUN_MANIFEST" ]]; then
    PIPELINE=$(jq -r '.pipeline // empty' "$RUN_MANIFEST") || true
    REGION=$(jq -r '.region // empty' "$RUN_MANIFEST") || true
    REF_TAXONOMY=$(jq -r '.params.dada_ref_taxonomy // empty' "$RUN_MANIFEST") || true
    SEQUENCING_TYPE=$(jq -r '.params.sequencing_type // empty' "$RUN_MANIFEST") || true
else
    warn "No $RUN_MANIFEST in the run directory; the page will not say how the run was set up."
fi

case "$SEQUENCING_TYPE" in
    illumina_pe) PLATFORM="Illumina, paired-end" ;;
    illumina_se) PLATFORM="Illumina, single-end" ;;
    nanopore)    PLATFORM="Oxford Nanopore" ;;
    pacbio)      PLATFORM="PacBio HiFi" ;;
    *)           PLATFORM="$SEQUENCING_TYPE" ;;
esac

#    ampliseq names a database as it is passed to it - "silva=138.2". Read as a
#    note rather than as a parameter, it wants a space and its own capitals.
REFERENCE=""
if [[ -n "$REF_TAXONOMY" ]]; then
    REFERENCE_NAME=${REF_TAXONOMY%%=*}
    REFERENCE_VERSION=${REF_TAXONOMY#*=}

    if (( ${#REFERENCE_NAME} <= 5 )); then
        REFERENCE_NAME=${REFERENCE_NAME^^}
    else
        REFERENCE_NAME=${REFERENCE_NAME^}
    fi

    REFERENCE="$REFERENCE_NAME"
    [[ "$REFERENCE_VERSION" != "$REF_TAXONOMY" ]] && REFERENCE+=" $REFERENCE_VERSION"
fi

#    The detector records the region as "16SV4"; a reader reads "16S V4"
SEQUENCED=""
[[ -n "$REGION" ]] && SEQUENCED=${REGION/#16S/16S }

if [[ -n "$PLATFORM" ]]; then
    SEQUENCED+="${SEQUENCED:+ · }$PLATFORM"
fi

#    What the run measured, as the sidebar reports it. The counts are whole
#    numbers written out in the units a sidebar has room for; the bars are only
#    how far each reading got.
declare -A STATS=()

if [[ -r "$STATS_FILE" ]]; then
    while IFS=$'\t' read -r STAT_KEY STAT_VALUE; do
        if [[ "$STAT_VALUE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            STATS["$STAT_KEY"]="$STAT_VALUE"
        fi
    done < "$STATS_FILE"
fi

if [[ -n "${STATS[reads_retained]:-}" ]]; then
    RETAINED=${STATS[reads_retained]}
    TOTAL_READS=${STATS[reads_total]:-$RETAINED}

    #    Reads that reached an ASV, against the reads that went in. The two bars
    #    share a scale, so the second one is the survival rate by eye.
    RETAINED_PCT=100
    if (( TOTAL_READS > 0 )); then
        RETAINED_PCT=$(( (RETAINED * 100 + TOTAL_READS / 2) / TOTAL_READS ))
    fi

    RETAINED_READING="$RETAINED_PCT% · $(human_count "$RETAINED")"

    dashboard_stat_group "READ TOTALS" "$SEQUENCED"
    dashboard_stat_bar "Total reads"    "$(human_count "$TOTAL_READS")" 100
    dashboard_stat_bar "Retained reads" "$RETAINED_READING" "$RETAINED_PCT" growth

    dashboard_stat_group "READS PER SAMPLE"
    dashboard_stat_chips "$(human_count "${STATS[reads_min]:-0}")|Min" \
                         "$(human_count "${STATS[reads_median]:-0}")|Median" \
                         "$(human_count "${STATS[reads_max]:-0}")|Max"
fi

#    How many ASVs the run called, and how far down the classifier could name
#    them. Each rank is a count of the ASVs that reached it, against the ASV
#    total the block opens with - the same reading ampliseq's own report gives.
if [[ -n "${STATS[asvs]:-}${STATS[phylum_asvs]:-}${STATS[genus_asvs]:-}${STATS[species_asvs]:-}" ]]; then
    dashboard_stat_group "CLASSIFICATION" "$REFERENCE"

    TOTAL_ASVS=${STATS[asvs]:-0}

    if [[ -n "${STATS[asvs]:-}" ]]; then
        dashboard_stat_bar "Total ASVs" "$(human_count "${STATS[asvs]}")" 100
    fi

    for RANK_STAT in "Phylum level|phylum_asvs" "Genus level|genus_asvs" \
                     "Species level|species_asvs"; do
        RANK_LABEL=${RANK_STAT%%|*}
        RANK_KEY=${RANK_STAT##*|}
        RANK_COUNT=${STATS[$RANK_KEY]:-}

        [[ -n "$RANK_COUNT" ]] || continue

        RANK_PCT=0
        if (( TOTAL_ASVS > 0 )); then
            RANK_PCT=$(( (RANK_COUNT * 100 + TOTAL_ASVS / 2) / TOTAL_ASVS ))
        fi

        RANK_READING="$RANK_PCT% · $(human_count "$RANK_COUNT")"
        dashboard_stat_bar "$RANK_LABEL" "$RANK_READING" "$RANK_PCT" growth
    done
fi

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

# 7. Land the pages last, once nothing they point at is still uploading. The
#    landing page overwrites the progress page published to this key, which is
#    how a reader watching the run is handed the report.
if ! UPLOAD_OUTPUT=$(publish_dashboard "$S3_RESULTS_DIR" "$RUN_ID" "$TASK_NAME" \
        "$SUBTITLE" "$PIPELINE" "$(date '+%b %-d, %Y')" "$SAMPLE_COUNT" \
        "$EXPIRES_ON" "$PLOT_DATA_FILE"); then
    fail "The results were uploaded, but the pages that present them were not:"$'\n'"$UPLOAD_OUTPUT"
fi

update_wrike_custom_field "$WRIKE_DASHBOARD_URL_CFID" "$S3_RESULTS_URL"
log "Upload successful: $S3_RESULTS_URL"
