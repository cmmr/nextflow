#!/bin/bash
#
# biobakery_upload.sh - Publish a biobakery results folder to AWS S3.
#
# Author: Daniel Smith
# Date:   September 15th, 2026
#
# The biobakery counterpart of taxprofiler_upload.sh, taking the same steps in
# the same order: work out what the Overview plots and write the Methods page's
# text, delete what templates/biobakery/prune.conf names, declare what the
# dashboard offers, package the staged reads and the results as one zip on the
# Globus guest collection, copy in the run's record and render the pages, write
# a listing page into every folder, add those to the zip, and copy the results to
# s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/<uid>/ with the pages last.
#
# The Overview's composition chart is MetaPhlAn's, and its diversity chart is
# Nonpareil's and mOTUs', on a run that enabled either.
# The sidebar carries KneadData's read totals and a Feature Table tab each for
# MetaPhlAn and HUMAnN; a tool the run did not enable leaves its tab off.
#
# The navigation bar reads Overview, Deliverables (the file index), Methods, QC
# Report (MultiQC) and File Explorer (the results folder's listing).
#
# Usage:     biobakery_upload.sh [results_dir]
#            defaults to ./results, the outdir set in the biobakery params file
# Called by: wrike_job.sh, as the last POST_PROCESS_CMDS entry of the biobakery pipelines
# Requires:  aws, zip, curl and jq (via the Wrike helpers)
# Reads:     templates/biobakery/outputs.conf and templates/biobakery/prune.conf;
#            ./composition_data.json and ./methods_data.json, and the run's
#            statistics and manifest out of ./run_state.json
# Runs:      biobakery_composition.sh, biobakery_methods.sh, prune_results.sh and
#            index_directories.sh, over the results folder
# Env:       NEXTFLOW_DIR, AWS_S3_BUCKET, S3_RUN_PREFIX, WRIKE_DASHBOARD_URL_CFID,
#            the Wrike, Globus and dashboard helper functions and the
#            log/fail/is_valid_uid helpers, all sourced from .env
# Writes:    one zip per run into the guest collection, named after the task and
#            the uid
# Outputs:   an explanation of a failure in ./run_state.json

set -euo pipefail

source /data/prod/nextflow/.env

RESULTS_DIR="${1:-results}"
RESULTS_DIR="${RESULTS_DIR%/}"

# Written by biobakery_samplesheet.sh; the reads go into the download, not S3
FASTQ_DIR="raw-sequences"

STATS_KEY="statistics"
PLOT_DATA_FILE="composition_data.json"
METHODS_DATA_FILE="methods_data.json"
RUN_MANIFEST_KEY="manifest"

SUBTITLE="Shotgun metagenomic taxonomic and functional profiling"

MULTIQC_REPORT="$RESULTS_DIR/multiqc/multiqc_report.html"
readonly MULTIQC_REPORT_HREF="multiqc/multiqc_report.html"

readonly OUTPUT_CATALOG="$NEXTFLOW_DIR/templates/biobakery/outputs.conf"
readonly PRUNE_LIST="$NEXTFLOW_DIR/templates/biobakery/prune.conf"

# Results publish under the run directory's name, which is the uid. Validated
# because an empty value would make S3_RESULTS_DIR the whole bucket.
RUN_ID="${PWD##*/}"
if ! is_valid_uid "$RUN_ID"; then
    fail "The results could not be published: \"$PWD\" is not a run directory."
fi

if ! TASK_ID=$(read_wrike_task_id); then
    fail "The results could not be published: this run's Wrike task is unknown."
fi

S3_RESULTS_DIR="s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/$RUN_ID"
S3_RESULTS_URL=$(run_results_url "$RUN_ID")

if [[ ! -d "$RESULTS_DIR" ]]; then
    fail "The pipeline finished but produced no results directory ('$RESULTS_DIR') to upload."
fi

# 1. The download is built at the end, so check it can be before anything else
command -v zip > /dev/null \
    || fail "The results could not be packaged for download: zip is not installed."

[[ -d "$FASTQ_DIR" ]] || log "No $FASTQ_DIR directory; the download will hold the results alone."

# 2. What the Overview plots and the sidebar reports, and the Methods page's text
if ! "$NEXTFLOW_DIR/scripts/biobakery_composition.sh" "$RESULTS_DIR"; then
    warn "The composition data could not be built; the plots will be missing."
fi

if ! "$NEXTFLOW_DIR/scripts/biobakery_methods.sh" "$RESULTS_DIR"; then
    warn "The methods text could not be written; the dashboard will have no Methods page."
    rm -f "$METHODS_DATA_FILE"
fi

# 3. Delete what the run wrote for itself, ahead of the listings
if ! "$NEXTFLOW_DIR/scripts/prune_results.sh" "$RESULTS_DIR" "$PRUNE_LIST"; then
    warn "The results could not be pruned; the run will publish its working files too."
fi

# 4. What the pages offer, from what the run produced
dashboard_reset "$RESULTS_DIR" "$OUTPUT_CATALOG"

dashboard_index_view   "Deliverables"
dashboard_methods_view "$METHODS_DATA_FILE" "Methods"
dashboard_view quality "QC Report" "$MULTIQC_REPORT_HREF"
dashboard_listing_view "File Explorer"

PIPELINE=""

if state_has "$RUN_MANIFEST_KEY"; then
    PIPELINE=$(state_get "$RUN_MANIFEST_KEY.pipeline")
else
    warn "This run recorded no manifest; the page will not name the pipeline."
fi

declare -A STATS=()

while IFS=$'\t' read -r STAT_KEY STAT_VALUE; do
    STATS["$STAT_KEY"]="$STAT_VALUE"
done < <(state_get_tsv "$STATS_KEY")

#    Reads as sequenced, what trimming and host depletion each left, and what
#    was kept. Each step behind "details" links to KneadData's table in the
#    QC Report.
TOTAL_READS=${STATS[raw_total]:-}

if [[ "$TOTAL_READS" =~ ^[0-9]+$ ]] && (( TOTAL_READS > 0 )); then
    READS_NOTE=${STATS[platform]:-}
    [[ -n "${STATS[layout]:-}" ]] && READS_NOTE+="${READS_NOTE:+, }${STATS[layout]}"

    KNEADDATA_SECTION=$(dashboard_report_section "$MULTIQC_REPORT" "$MULTIQC_REPORT_HREF" \
        "kneaddata")

    dashboard_stat_group "READ TOTALS" "$READS_NOTE"
    dashboard_stat_bar "Total reads" "$(human_count "$TOTAL_READS")" 100

    dashboard_stat_share_detail reads "After trimming" "${STATS[trimmed_total]:-}" \
        "$TOTAL_READS" "$KNEADDATA_SECTION"
    dashboard_stat_share_detail reads "After host depletion" "${STATS[host_kept]:-}" \
        "$TOTAL_READS" "$KNEADDATA_SECTION"

    dashboard_stat_share "Retained reads" "${STATS[retained_total]:-}" "$TOTAL_READS" growth reads

    dashboard_stat_group "READS PER SAMPLE"
    dashboard_stat_chips "$(human_count "${STATS[reads_min]:-0}")|Min" \
                         "$(human_count "${STATS[reads_median]:-0}")|Median" \
                         "$(human_count "${STATS[reads_max]:-0}")|Max"
fi

#    The Feature Table card, one tab per tool: the SGB read counts in three
#    BIOM formats, and HUMAnN's RPK tables in classic tabular form
dashboard_tab metaphlan "MetaPhlAn"

dashboard_formats "" \
    "Taxa|BIOM (tsv)|metaphlan/metaphlan-sgb-reads.tsv" \
    "Taxa|BIOM (json)|metaphlan/metaphlan-sgb-reads.json.biom" \
    "Taxa|BIOM (hdf5)|metaphlan/metaphlan-sgb-reads.hdf5.biom" || true

#    Each tool's mapped reads out of the reads KneadData retained, with the
#    database it mapped against named under the bar
if [[ -n "${STATS[metaphlan_mapped]:-}" ]]; then
    dashboard_stat_group
    dashboard_stat_share_of "Mapped reads" "${STATS[metaphlan_mapped]}" \
        "${STATS[retained_total]:-${STATS[metaphlan_total]:-}}" "${STATS[metaphlan_database]:-}" \
        "MetaPhlAn's estimate of the reads that came from the organisms it identified. Only reads matching its clade-specific marker genes are aligned; each identified clade's marker coverage is then scaled up by its genome size to estimate all the reads it contributed. The rest, including organisms with no markers in the database, is unclassified."
fi

dashboard_tab humann "HUMAnN"

dashboard_formats "" \
    "Pathways|BIOM (tsv)|humann/pathway-abundance-rpk.tsv" \
    "Genes|BIOM (tsv)|humann/gene-families-rpk.tsv" \
    "Enzymes|BIOM (tsv)|humann/ec-rpk.tsv" || true

if [[ -n "${STATS[humann_mapped]:-}" ]]; then
    dashboard_stat_group
    dashboard_stat_share_of "Mapped reads" "${STATS[humann_mapped]}" \
        "${STATS[retained_total]:-${STATS[humann_total]:-}}" "${STATS[humann_database]:-}" \
        "Reads HUMAnN aligned to a gene family: first as DNA to the ChocoPhlAn pangenomes of the species MetaPhlAn found, then, for reads left over, as translated protein against UniRef90. Reads that matched neither are unmapped. A sample HUMAnN could not finish is counted as unmapped."
fi

dashboard_tab_end

#    The task's current name and expiration date, falling back to the name
#    recorded at submission
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

TASK_NAME=${TASK_NAME%%$'\n'*}
: "${TASK_NAME:=Sequencing results}"

SAMPLE_COUNT=$(state_get samples.count)

if [[ -n "$SAMPLE_COUNT" && ! "$SAMPLE_COUNT" =~ ^[0-9]+$ ]]; then
    warn "This run recorded no usable sample count; leaving it off the page."
    SAMPLE_COUNT=""
fi

# 5. The reads as they went in and the results, as the one download. Built
#    before the pages, which state its size and address; the reads are stored
#    as they are, being gzipped already.
BUNDLE_NAME=$(globus_bundle_name "$RUN_ID" "$TASK_NAME")
BUNDLE_PARTS=("$RESULTS_DIR|-9")

[[ -d "$FASTQ_DIR" ]] && BUNDLE_PARTS=("$FASTQ_DIR|-0" "${BUNDLE_PARTS[@]}")

log "Packaging $BUNDLE_NAME for task $TASK_ID..."

if ! ZIP_OUTPUT=$(globus_archive "$RUN_ID" "$BUNDLE_NAME" "${BUNDLE_PARTS[@]}"); then
    fail "This run could not be packaged for download:"$'\n'"$ZIP_OUTPUT"
fi

#    The folders it was zipped from, for the tree the file index draws of it
dashboard_bundle "$(globus_run_url "$RUN_ID" "$BUNDLE_NAME")" \
    "$(globus_archive_size "$RUN_ID" "$BUNDLE_NAME")" "${BUNDLE_PARTS[@]%%|*}"

# 6. The run's record into the results folder, for the download and the File
#    Explorer to carry, and the three pages
dashboard_stage_records \
    || warn "The run's record could not be copied into the results; the download will not carry it."

if ! RENDER_OUTPUT=$(render_dashboard "$RUN_ID" "$TASK_NAME" "$SUBTITLE" \
        "$PIPELINE" "$(date '+%b %-d, %Y')" "$SAMPLE_COUNT" "$EXPIRES_ON" \
        "$PLOT_DATA_FILE"); then
    fail "The pages that present these results could not be built:"$'\n'"$RENDER_OUTPUT"
fi

# 7. A listing page in every folder, and one for the staged reads, once every
#    file published beside them is in place
if ! "$NEXTFLOW_DIR/scripts/index_directories.sh" "$RESULTS_DIR" "$FASTQ_DIR"; then
    warn "The results folders could not be indexed; their listings will be missing."
fi

# 8. And all of that into the archive, which was built without it
mapfile -t BUNDLE_LATE < <(dashboard_late_files)

if ! ZIP_OUTPUT=$(globus_archive_add "$RUN_ID" "$BUNDLE_NAME" "${BUNDLE_LATE[@]}"); then
    warn "The download will not carry the dashboard's pages, listings and record:"$'\n'"$ZIP_OUTPUT"
fi

# 9. Everything, the pages last - the landing page replaces the progress page
log "Initiating S3 upload for Task $TASK_ID..."

if ! UPLOAD_OUTPUT=$(publish_results "$S3_RESULTS_DIR"); then
    fail "The results could not be uploaded to S3:"$'\n'"$UPLOAD_OUTPUT"
fi

set_wrike_custom_field "$WRIKE_DASHBOARD_URL_CFID" "$S3_RESULTS_URL"
log "Upload successful: $S3_RESULTS_URL"
