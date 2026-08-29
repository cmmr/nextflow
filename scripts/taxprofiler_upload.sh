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
# So is everything named in SKIP_UPLOAD below: a shotgun run publishes about ten
# times more bytes than anyone reads, nearly all of it a tool's own scratch or a
# second copy of something the reports already show. The listings, the file index
# and the download zip are all built from the same list, so what the pages
# describe is what a reader can actually fetch.
#
# The raw reads are not published with the results: a WGS run's inputs are large
# enough that packaging and uploading them costs more than the analysis did, and
# the requester already holds them. The page keeps a hidden row for the link
# that will offer them from the cluster instead - see dashboard_link_button.
#
# The pages a reader sees are publish_dashboard.sh's, filled in from what this
# run actually produced: which reports the navigation bar offers, what the
# Overview plots, which files its sidebar offers, what the run measured, and
# which of the outputs named in templates/taxprofiler/outputs.conf exist. The
# plots and the numbers beside them are what taxprofiler_composition.sh left in
# composition_data.json and in the state file's "statistics", and the settings
# stated beside them come off the database sheet and the manifest wrike_job.sh
# recorded.
#
# Usage:     taxprofiler_upload.sh [results_dir]
#            defaults to ./results, the outdir set in the taxprofiler params file
# Called by: wrike_job.sh, as the POST_PROCESS_CMDS entry of the taxprofiler pipelines
# Requires:  aws, curl and jq (via the Wrike helpers)
# Reads:     templates/dashboard.html, templates/overview.html,
#            templates/files.html and templates/taxprofiler/outputs.conf, via
#            the dashboard helpers; ./composition_data.json, and the run's
#            statistics and manifest out of ./run_state.json
# Runs:      taxprofiler_composition.sh and index_directories.sh, over the
#            results folder
# Env:       NEXTFLOW_DIR, AWS_S3_BUCKET, S3_RUN_PREFIX, WRIKE_DASHBOARD_URL_CFID,
#            the Wrike and dashboard helper functions and the log/fail/is_valid_uid
#            helpers, all sourced from .env
# Outputs:   an explanation of a failure in ./run_state.json
#
# Does not record the run's status: wrike_job.sh marks the run Completed only
# after every post-process step it runs has succeeded.

set -euo pipefail

source /data/prod/nextflow/.env

RESULTS_DIR="${1:-results}"
RESULTS_DIR="${RESULTS_DIR%/}"

# Also written per run by taxprofiler_samplesheet.sh, and published with the
# results as part of the record
DB_SHEET="taxprofiler_database.csv"

# The headline numbers taxprofiler_composition.sh counted out of the classifier
# reports, as key and value, for the Overview's sidebar
STATS_KEY="statistics"

# What that script left for the Overview's two plots, or nothing when the run
# produced no reports to plot
PLOT_DATA_FILE="composition_data.json"

# Recorded by wrike_job.sh, and read here for the settings the page names: which
# pipeline version ran, and what it was told to deplete against
RUN_MANIFEST_KEY="manifest"

# What the page calls the analysis, under the task's own name
SUBTITLE="Shotgun metagenomic taxonomic profiling"

# What the landing page's "All output files" view lists, in the order it lists it
readonly OUTPUT_CATALOG="$NEXTFLOW_DIR/templates/taxprofiler/outputs.conf"

# What is not worth the bucket it would sit in, as globs read from the results
# folder. Passed to the listings, to the file index and to the upload, so all
# three agree.
#
# The MetaPhlAn alignments are the whole of the difference: they are its record
# of which read hit which marker gene, kept so that MetaPhlAn can be re-run
# without aligning again, and on this run they were 1.2 GB of a 1.4 GB folder.
# Nobody who asked us for a profile re-runs MetaPhlAn from them; the profile
# itself, the BIOM table and the merged report are all published.
#
# The rest are second copies. MultiQC's data.json is every number in its own
# report as machine-readable JSON, its log is its debug trace, and multiqc_plots
# is each of the report's interactive figures rendered again as PNG, SVG and PDF.
# A FastQC zip holds the same measurements as the HTML report published beside
# it, which is also what MultiQC read to build its own.
# A folder every file of which is left behind is named twice: once for what is
# in it, and once as itself, so that the folder above stops listing a folder
# there is nothing left in.
readonly SKIP_UPLOAD=(
    "metaphlan/*/*.bowtie2out.txt"
    "multiqc/multiqc_data/multiqc_data.json"
    "multiqc/multiqc_data/multiqc.log"
    "multiqc/multiqc_plots"
    "multiqc/multiqc_plots/*"
    "fastqc/*/*_fastqc.zip"
)

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

# 2. Work out the two things a requester asks for first - what was in each
#    sample, and how varied each sample was - for the Overview to plot. Ahead of
#    the listings, so the table it leaves in the results is in them.
if ! "$NEXTFLOW_DIR/scripts/taxprofiler_composition.sh" "$RESULTS_DIR"; then
    warn "The composition and diversity data could not be built; the plots will be missing."
fi

# 3. Give every folder below the results root a listing page, so that the folder
#    links the landing page carries still resolve once the results are objects in
#    a bucket rather than directories on disk.
if ! "$NEXTFLOW_DIR/scripts/index_directories.sh" "$RESULTS_DIR" "${SKIP_UPLOAD[@]}"; then
    warn "The results folders could not be indexed; their listings will be missing."
fi

# 4. Publish everything below the landing page
log "Initiating S3 upload for Task $TASK_ID..."

if ! UPLOAD_OUTPUT=$(upload_results_tree "$RESULTS_DIR" "$S3_RESULTS_DIR" \
        "${SKIP_UPLOAD[@]}"); then
    fail "The results could not be uploaded to S3:"$'\n'"$UPLOAD_OUTPUT"
fi

# 5. Build the pages that frame all of it, from what the run produced.
dashboard_reset "$RESULTS_DIR" "$OUTPUT_CATALOG" "${SKIP_UPLOAD[@]}"

#    The navigation bar, after the Overview every run opens on. Krona is the one
#    report of the three that reads a whole taxonomy rather than a summary of it,
#    and the run writes one per classifier and database.
#
#    The one whose name does not say bracken is the one offered. Both are drawn
#    from kraken2's clade counts - checked against the reports on run vbnhm2tf,
#    where every wedge of the two charts carries the same number, and it is
#    kraken2's rather than bracken's: Segatella in sample 4211 is 4,720,453 on
#    both, which is what kraken2 placed there and not the 4,893,782 bracken
#    reassigned to it. So the choice is between two names for one chart, and the
#    one that does not promise bracken's estimates is the one to hand a reader.
#    Both stay in the file index either way.
#
#    The folder's own listing page is passed over: index_directories.sh has
#    already written it, and it sorts ahead of every chart in it.
KRONA_CHART=""
KRONA_FALLBACK=""

for KRONA_PATH in "$RESULTS_DIR"/krona/*.html; do
    [[ -r "$KRONA_PATH" ]] || continue
    [[ "${KRONA_PATH##*/}" == directory_listing.html ]] && continue

    if [[ "$KRONA_PATH" == *bracken* ]]; then
        : "${KRONA_FALLBACK:=${KRONA_PATH#"$RESULTS_DIR/"}}"
        continue
    fi

    KRONA_CHART=${KRONA_PATH#"$RESULTS_DIR/"}
    break
done

: "${KRONA_CHART:=$KRONA_FALLBACK}"

dashboard_view krona   "Taxonomy Explorer" "$KRONA_CHART"
dashboard_view quality "Quality Control"   "multiqc/multiqc_report.html"
dashboard_index_view   "File Explorer"

#    The three tables a requester opens first, named for what they hold rather
#    than for the tool, the database and the format that named the file.
#    taxpasta's merged bracken profile is the one to load into R or Python; the
#    diversity table is what the Overview's second plot is drawn from; MetaPhlAn
#    is the second opinion. The raw reads follow them as a row that stays hidden
#    until it is given the address they are served from.
if ! dashboard_button "taxpasta/bracken_*.tsv" "Species abundance table"; then
    dashboard_button "taxpasta/kraken2_*.tsv" "Taxonomic profile table"
fi

dashboard_button "alpha_diversity.tsv" "Per-sample diversity"
dashboard_button "metaphlan/metaphlan_*_combined_reports.txt" "MetaPhlAn profiles"
dashboard_link_button "" "Raw sequencing data"

#    How the run was set up. The pipeline version comes off the manifest
#    wrike_job.sh recorded, so the page and the record cannot disagree; the host
#    and the databases come off the request and the sheet the run was given.
PIPELINE=""

if state_has "$RUN_MANIFEST_KEY"; then
    PIPELINE=$(state_get "$RUN_MANIFEST_KEY.pipeline")
else
    warn "This run recorded no manifest; the page will not name the pipeline."
fi

HOST_REMOVAL=$(form_answer hostremoval_reference)
: "${HOST_REMOVAL:=PhiX}"

#    Read as a note over the read totals rather than as a row of its own, so the
#    reads that were taken out are read beside what took them out
if [[ "${HOST_REMOVAL,,}" == "none" ]]; then
    DEPLETED="No host depletion"
else
    DEPLETED="$HOST_REMOVAL depleted"
fi

DATABASES=""
if [[ -r "$DB_SHEET" ]]; then
    DATABASES=$(awk -F, 'NR > 1 && $2 != "" && !seen[$2]++ {
        printf "%s%s", (n++ ? ", " : ""), $2
    }' "$DB_SHEET")
fi

#    What the run measured, as the sidebar reports it. The counts are whole
#    numbers written out in the units a sidebar has room for; the bars are only
#    how far each reading got.
declare -A STATS=()

while IFS=$'\t' read -r STAT_KEY STAT_VALUE; do
    STATS["$STAT_KEY"]="$STAT_VALUE"
done < <(state_get_tsv "$STATS_KEY")

# One reading as a bar: what it is, how many reads it was, and what share of the
# reads the run started with. Every bar in the sidebar is a share of that one
# number, so two of them can be read against each other. Green is for the reads
# that came through; what was taken out is left in the navy every total wears.
stat_share() {
    local label="$1" count="$2" total="$3" tone="${4:-growth}"
    local percent

    [[ "$count" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 0
    (( total > 0 )) || return 0

    percent=$(( (count * 100 + total / 2) / total ))

    dashboard_stat_bar "$label" "$percent% · $(human_count "$count")" "$percent" "$tone"
}

#    Reads as they reached the pipeline, and what became of them. Where host
#    removal ran it counted them first, so its total is the one every share is
#    taken against; without it the classifier's own total is.
TOTAL_READS=${STATS[host_total]:-${STATS[reads_total]:-}}

if [[ "$TOTAL_READS" =~ ^[0-9]+$ ]] && (( TOTAL_READS > 0 )); then
    dashboard_stat_group "READ TOTALS" "$DEPLETED"
    dashboard_stat_bar "Total reads" "$(human_count "$TOTAL_READS")" 100

    stat_share "Host removed" "${STATS[host_removed]:-}" "$TOTAL_READS" total
    stat_share "Classified"   "${STATS[reads_classified]:-}" "$TOTAL_READS"

    dashboard_stat_group "READS PER SAMPLE"
    dashboard_stat_chips "$(human_count "${STATS[reads_min]:-0}")|Min" \
                         "$(human_count "${STATS[reads_median]:-0}")|Median" \
                         "$(human_count "${STATS[reads_max]:-0}")|Max"

    #    How far down the taxonomy the classifier could place a read. Each rank
    #    counts the reads that landed inside some clade of it, which is the same
    #    reading kraken2's own report gives, and each is a share of the total
    #    above - so the three bars are one funnel rather than three readings.
    dashboard_stat_group "CLASSIFICATION" \
        "${STATS[profiler]:+${STATS[profiler]} · }${STATS[database]:-}"

    stat_share "Phylum level"  "${STATS[phylum_reads]:-}"  "$TOTAL_READS"
    stat_share "Genus level"   "${STATS[genus_reads]:-}"   "$TOTAL_READS"
    stat_share "Species level" "${STATS[species_reads]:-}" "$TOTAL_READS"
fi

#    How many distinct taxa the run named, over every sample rather than in any
#    one of them
if [[ -n "${STATS[phyla]:-}${STATS[genera]:-}${STATS[species]:-}" ]]; then
    dashboard_stat_group "TAXA DETECTED"
    dashboard_stat_chips "$(human_count "${STATS[phyla]:-0}")|Phyla" \
                         "$(human_count "${STATS[genera]:-0}")|Genera" \
                         "$(human_count "${STATS[species]:-0}")|Species"
fi

dashboard_stat_group "RUN CONFIGURATION"
dashboard_stat_row   "Databases" "$DATABASES"

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

# 6. Land the pages last, once nothing they point at is still uploading. The
#    landing page overwrites the progress page published to this key.
if ! UPLOAD_OUTPUT=$(publish_dashboard "$S3_RESULTS_DIR" "$RUN_ID" "$TASK_NAME" \
        "$SUBTITLE" "$PIPELINE" "$(date '+%b %-d, %Y')" "$SAMPLE_COUNT" \
        "$EXPIRES_ON" "$PLOT_DATA_FILE"); then
    fail "The results were uploaded, but the pages that present them were not:"$'\n'"$UPLOAD_OUTPUT"
fi

update_wrike_custom_field "$WRIKE_DASHBOARD_URL_CFID" "$S3_RESULTS_URL"
log "Upload successful: $S3_RESULTS_URL"
