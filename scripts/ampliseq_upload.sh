#!/bin/bash
#
# ampliseq_upload.sh - Publish an ampliseq results folder and its raw reads to AWS S3.
#
# Author: Daniel Smith
# Date:   August 12th, 2026
#
# Deletes what the run wrote for itself, gives every folder a listing page, and
# copies the results folder to s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/<uid>/. The
# folder is uploaded from the inside out, so summary_report/summary_report.html
# lands directly under the uid rather than under an extra results/ level.
# Nextflow's work/ directory is left behind.
#
# The two bulky downloads do not go to S3 at all. The reads ampliseq_samplesheet.sh
# staged, and the whole dashboard as one zip, are written into the run's
# directory on the CMMR-Nextflow guest collection and linked from the page - see
# scripts/globus.sh. They are the largest thing a run publishes and the thing
# most likely to be downloaded whole, and from there they cost neither storage
# in the bucket nor egress out of it.
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
# The read archive is stored, not compressed (zip -0): the reads are already
# gzipped. zip stores what a symlink points at, so linked samples are archived
# as real data.
#
# What a run wrote for itself rather than for the requester is deleted before
# any of this, so the listings, the file index, the zip and the bucket all
# describe the same thing - see prune_results.sh and templates/ampliseq/prune.conf.
#
# The pages a reader sees are publish_dashboard.sh's, filled in from what this
# run actually produced: which reports the navigation bar offers, what the
# Overview plots, which files its sidebar offers, what the run measured, and
# which of the outputs named in templates/ampliseq/outputs.conf exist. The plots
# and the numbers beside them are what ampliseq_composition.sh left in
# composition_data.json and in the state file's "statistics", and the settings
# stated beside them come off the manifest wrike_job.sh recorded.
#
# Usage:     ampliseq_upload.sh [results_dir]
#            defaults to ./results, the outdir set in the ampliseq params file
# Called by: wrike_job.sh, as the POST_PROCESS_CMDS entry of the ampliseq pipeline
# Requires:  aws, zip, curl and jq (via the Wrike helpers)
# Reads:     templates/dashboard.html, templates/overview.html,
#            templates/files.html and templates/ampliseq/outputs.conf, via the
#            dashboard helpers; templates/ampliseq/prune.conf; ./composition_data.json,
#            and the run's statistics and manifest out of ./run_state.json
# Runs:      ampliseq_composition.sh, prune_results.sh and index_directories.sh,
#            over the results folder
# Env:       NEXTFLOW_DIR, AWS_S3_BUCKET, S3_RUN_PREFIX, WRIKE_DASHBOARD_URL_CFID,
#            GLOBUS_DIR, GLOBUS_RUN_PREFIX, GLOBUS_URL, the Wrike, Globus and
#            dashboard helper functions and the log/fail/is_valid_uid helpers,
#            all sourced from .env
# Outputs:   an explanation of a failure in ./run_state.json
#
# Does not record the run's status: wrike_job.sh marks the run Completed only
# after every post-process step it runs has succeeded.

set -euo pipefail

source /data/prod/nextflow/.env

RESULTS_DIR="${1:-results}"
RESULTS_DIR="${RESULTS_DIR%/}"

# Input FASTQ directory, named to match what ampliseq_samplesheet.sh creates,
# and the archive it becomes on the guest collection. Both are named for the
# reader downloading them, since those names are what the buttons show.
FASTQ_DIR="raw-sequences"
FASTQ_ZIP_NAME="raw-sequences.zip"

# The whole dashboard as one zip, published beside the reads
DASHBOARD_ZIP_NAME="dashboard.zip"

# The headline numbers ampliseq_composition.sh counted out of the ASV and
# abundance tables, as key and value, for the Overview's sidebar
STATS_KEY="statistics"

# What that script left for the Overview's two plots to draw, or nothing when
# the run produced no tables to plot
PLOT_DATA_FILE="composition_data.json"

# Recorded by wrike_job.sh, and read here for the settings the page names: which
# pipeline version ran, which region it measured, and what it classified against
RUN_MANIFEST_KEY="manifest"

# What the page calls the analysis, under the task's own name
SUBTITLE="16S rRNA amplicon sequencing analysis"

# ampliseq's own account of the run, and the first thing the dashboard shows
SUMMARY_REPORT="$RESULTS_DIR/summary_report/summary_report.html"

# What the landing page's "All output files" view lists, in the order it lists it
readonly OUTPUT_CATALOG="$NEXTFLOW_DIR/templates/ampliseq/outputs.conf"

# What is deleted from the results before any of it is published
readonly PRUNE_LIST="$NEXTFLOW_DIR/templates/ampliseq/prune.conf"

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

# 1. Archive the reads into this run's directory on the guest collection, rather
#    than into the results folder: they are most of what a run publishes, and
#    nobody reads them through the dashboard. Skipped for any pipeline that does
#    not stage its inputs this way.
FASTQ_URL=""

if [[ -d "$FASTQ_DIR" ]]; then
    command -v zip > /dev/null \
        || fail "The results could not be packaged for download: zip is not installed."

    log "Archiving $FASTQ_DIR for task $TASK_ID..."

    # zip's output goes into the failure message, so the requester is told why
    # their data could not be packaged
    if ! ZIP_OUTPUT=$(globus_archive "$RUN_ID" "$FASTQ_ZIP_NAME" "$FASTQ_DIR" -0); then
        fail "The sequencing data could not be packaged for download:"$'\n'"$ZIP_OUTPUT"
    fi

    FASTQ_URL=$(globus_run_url "$RUN_ID" "$FASTQ_ZIP_NAME")
else
    log "No $FASTQ_DIR directory; skipping raw sequence archive."
fi

# 2. Work out the two things a requester asks for first - what was in each
#    sample, and how varied each sample was - for the Overview to plot. Ahead of
#    the pruning and the listings, so the table it leaves in the results is in
#    them.
if ! "$NEXTFLOW_DIR/scripts/ampliseq_composition.sh" "$RESULTS_DIR"; then
    warn "The composition and diversity data could not be built; the plots will be missing."
fi

# 3. Delete what the run wrote for itself: DADA2's working copies of tables
#    published beside them, and the reports MultiQC rendered a second time. Ahead
#    of the listings, so nothing describes a file that is not there.
if ! "$NEXTFLOW_DIR/scripts/prune_results.sh" "$RESULTS_DIR" "$PRUNE_LIST"; then
    warn "The results could not be pruned; the run will publish its working files too."
fi

# 4. Give every folder below the results root a listing page, so that the folder
#    links the report and the landing page carry still resolve once the results
#    are objects in a bucket rather than directories on disk.
if ! "$NEXTFLOW_DIR/scripts/index_directories.sh" "$RESULTS_DIR"; then
    warn "The results folders could not be indexed; their listings will be missing."
fi

# 5. Send the report's link to the "base results folder" to the listing page for
#    it. That link is written as "../", which resolves to the landing page this
#    report is being read inside of - so following it opens a second copy of the
#    dashboard in the dashboard's own frame. index_directories.sh has just
#    written the listing the reader was actually after.
if [[ -w "$SUMMARY_REPORT" ]]; then
    sed -i 's|href="\.\./"|href="../directory_listing.html"|g' "$SUMMARY_REPORT" \
        || warn "The report's link to the results folder could not be redirected."
fi

# 6. Build the pages that frame all of it, from what the run produced.
dashboard_reset "$RESULTS_DIR" "$OUTPUT_CATALOG" "$(globus_run_url "$RUN_ID")"

#    The navigation bar, after the Overview every run opens on
dashboard_view report  "Analysis Report" "summary_report/summary_report.html"
dashboard_view quality "Technical Report" "multiqc/multiqc_report.html"
dashboard_index_view   "File Explorer"

#    The ASV table carries its taxonomy as observation metadata, so it is the
#    one file most people came for. The two archives follow it: the reads as
#    they went in, and the whole of this dashboard, both served from the guest
#    collection and both of what "Download everything" fetches.
dashboard_button "qiime2/abundance_tables/feature-table.biom" || true
dashboard_bundle "Raw sequencing data" "$FASTQ_URL"
dashboard_bundle "All result files" "$(globus_run_url "$RUN_ID" "$DASHBOARD_ZIP_NAME")"

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

if state_has "$RUN_MANIFEST_KEY"; then
    PIPELINE=$(state_get "$RUN_MANIFEST_KEY.pipeline")
    REGION=$(state_get "$RUN_MANIFEST_KEY.region")
    REF_TAXONOMY=$(state_get "$RUN_MANIFEST_KEY.params.dada_ref_taxonomy")
    SEQUENCING_TYPE=$(state_get "$RUN_MANIFEST_KEY.params.sequencing_type")
else
    warn "This run recorded no manifest; the page will not say how the run was set up."
fi

#    The instrument the reads came off, which is what the note over the read
#    totals is. Whether the run was paired or single-end is how the pipeline was
#    set up rather than what the reads are, and it is in the samplesheet and the
#    manifest for anyone who needs it.
case "$SEQUENCING_TYPE" in
    illumina_pe|illumina_se) PLATFORM="Illumina" ;;
    nanopore)                PLATFORM="Oxford Nanopore" ;;
    pacbio)                  PLATFORM="PacBio HiFi" ;;
    *)                       PLATFORM="$SEQUENCING_TYPE" ;;
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

while IFS=$'\t' read -r STAT_KEY STAT_VALUE; do
    if [[ "$STAT_VALUE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        STATS["$STAT_KEY"]="$STAT_VALUE"
    fi
done < <(state_get_tsv "$STATS_KEY")

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

if [[ -z "$TASK_NAME" ]]; then
    warn "Could not read the current task name; using the one recorded at submission."
    TASK_NAME=$(state_get "$WRIKE_TASK_NAME_KEY")
fi

# One line: this is a page header, not a document
TASK_NAME=${TASK_NAME%%$'\n'*}
: "${TASK_NAME:=Sequencing results}"

#    How many samples the header says this run covers. A count that was never
#    recorded, or that is not a number, leaves that note off the header
#    altogether. Validated because it is read from a file and written into the
#    page.
SAMPLE_COUNT=$(state_get samples.count)

if [[ -n "$SAMPLE_COUNT" && ! "$SAMPLE_COUNT" =~ ^[0-9]+$ ]]; then
    warn "This run recorded no usable sample count; leaving it off the page."
    SAMPLE_COUNT=""
fi

# 7. Write the three pages into the results folder, so the zip below holds the
#    same dashboard the bucket will serve.
if ! RENDER_OUTPUT=$(render_dashboard "$RUN_ID" "$TASK_NAME" "$SUBTITLE" \
        "$PIPELINE" "$(date '+%b %-d, %Y')" "$SAMPLE_COUNT" "$EXPIRES_ON" \
        "$PLOT_DATA_FILE"); then
    fail "The pages that present these results could not be built:"$'\n'"$RENDER_OUTPUT"
fi

# 8. Archive the finished dashboard beside the reads. Deflated rather than
#    stored: what is left after the pruning is mostly HTML and tables.
if ! ZIP_OUTPUT=$(globus_archive "$RUN_ID" "$DASHBOARD_ZIP_NAME" "$RESULTS_DIR"); then
    warn "The results could not be packaged as one download:"$'\n'"$ZIP_OUTPUT"
fi

# 9. Publish everything, the pages last - the landing page overwrites the
#    progress page published to that key, which is how a reader watching the run
#    is handed the report.
log "Initiating S3 upload for Task $TASK_ID..."

if ! UPLOAD_OUTPUT=$(publish_results "$S3_RESULTS_DIR"); then
    fail "The results could not be uploaded to S3:"$'\n'"$UPLOAD_OUTPUT"
fi

set_wrike_custom_field "$WRIKE_DASHBOARD_URL_CFID" "$S3_RESULTS_URL"
log "Upload successful: $S3_RESULTS_URL"
