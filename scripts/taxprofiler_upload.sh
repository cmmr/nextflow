#!/bin/bash
#
# taxprofiler_upload.sh - Publish a taxprofiler results folder to AWS S3.
#
# Author: Daniel Smith
# Date:   August 19th, 2026
#
# Deletes what the run wrote for itself, gives every folder below the results
# root a listing page, and copies the folder to
# s3://$AWS_S3_BUCKET/$S3_RUN_PREFIX/<uid>/ from the inside out - so
# multiqc/multiqc_report.html lands directly under the uid - landing the pages
# that frame it last. Nextflow's work/ directory is left behind.
#
# The pruning is most of what makes that affordable: a shotgun run publishes
# about ten times more bytes than anyone reads, nearly all of it a tool's own
# scratch or a second copy of something the reports already show. What goes is
# named in templates/taxprofiler/prune.conf and deleted from the results folder
# outright, so the listings, the file index, the zip and the bucket cannot come
# to describe different things.
#
# The bulky download does not go to S3 at all. The reads
# taxprofiler_samplesheet.sh staged and the whole dashboard go into the run's
# directory on the CMMR-Nextflow guest collection as a single zip, linked from
# the page - see scripts/globus.sh. A WGS run's inputs are large enough that
# uploading them would cost more than the analysis did; from the collection they
# cost neither storage in the bucket nor egress out of it, and the requester
# gets them at the cluster's own bandwidth.
#
# One zip rather than two, laid out the way this run directory is - the staged
# reads beside the results - so that a requester who takes it has everything
# before the dashboard expires, rather than one of two downloads and the belief
# that it was all of them. The reads are listed in the dashboard's file index
# and in a listing of their own, both greyed, so the page says what is in that
# download without offering files the bucket does not hold.
#
# The pages a reader sees are publish_dashboard.sh's, filled in from what this
# run actually produced: which reports the navigation bar offers, what the
# Overview plots, which files its sidebar offers, what the run measured, and
# which of the outputs named in templates/taxprofiler/outputs.conf exist. The
# plots and the numbers beside them are what taxprofiler_composition.sh left in
# composition_data.json and in the state file's "statistics" - the platform the
# read totals are headed with among them - and the rest of what the page states
# about the run comes off the request and the manifest wrike_job.sh recorded.
#
# Usage:     taxprofiler_upload.sh [results_dir]
#            defaults to ./results, the outdir set in the taxprofiler params file
# Called by: wrike_job.sh, as the POST_PROCESS_CMDS entry of the taxprofiler pipelines
# Requires:  aws, zip, curl and jq (via the Wrike helpers)
# Reads:     templates/dashboard.html, templates/overview.html,
#            templates/files.html and templates/taxprofiler/outputs.conf, via
#            the dashboard helpers; templates/taxprofiler/prune.conf;
#            ./composition_data.json, and the run's statistics and manifest out
#            of ./run_state.json
# Runs:      taxprofiler_composition.sh, prune_results.sh and
#            index_directories.sh, over the results folder
# Env:       NEXTFLOW_DIR, AWS_S3_BUCKET, S3_RUN_PREFIX, WRIKE_DASHBOARD_URL_CFID,
#            GLOBUS_DIR, GLOBUS_RUN_PREFIX, GLOBUS_URL, the Wrike, Globus and
#            dashboard helper functions and the log/fail/is_valid_uid helpers,
#            all sourced from .env
# Writes:    one zip per run into the guest collection, named after the task and
#            the uid
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

# Input FASTQ directory, named to match what taxprofiler_samplesheet.sh creates.
# Named for the reader unpacking it, since this is a folder of the download.
FASTQ_DIR="raw-sequences"

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

# Every tool's own account of what it did, which is where the read totals send a
# reader who wants a step's own numbers, and where it is read from
MULTIQC_REPORT="$RESULTS_DIR/multiqc/multiqc_report.html"
readonly MULTIQC_REPORT_HREF="multiqc/multiqc_report.html"

# What the landing page's "All output files" view lists, in the order it lists it
readonly OUTPUT_CATALOG="$NEXTFLOW_DIR/templates/taxprofiler/outputs.conf"

# What is deleted from the results before any of it is published
readonly PRUNE_LIST="$NEXTFLOW_DIR/templates/taxprofiler/prune.conf"

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

# 2. Everything a requester downloads comes out of one zip, which is built at
#    the end of this script - so the reads are still here to go into it. A WGS
#    run's inputs are larger than everything else it publishes put together, and
#    from the guest collection they are a copy on the cluster's own disk rather
#    than an upload. Checked now rather than then, since a run whose results
#    cannot be packaged is of no use to the requester.
command -v zip > /dev/null \
    || fail "The results could not be packaged for download: zip is not installed."

[[ -d "$FASTQ_DIR" ]] || log "No $FASTQ_DIR directory; the download will hold the results alone."

# 3. Work out the two things a requester asks for first - what was in each
#    sample, and how varied each sample was - for the Overview to plot. Ahead of
#    the pruning and the listings, so the table it leaves in the results is in
#    them.
if ! "$NEXTFLOW_DIR/scripts/taxprofiler_composition.sh" "$RESULTS_DIR"; then
    warn "The composition and diversity data could not be built; the plots will be missing."
fi

# 4. Choose the Krona chart the navigation bar offers. The run writes one per
#    classifier and database, and the one whose name does not say bracken is the
#    one offered.
#
#    Both are drawn from kraken2's clade counts - checked against the reports on
#    run vbnhm2tf, where every wedge of the two charts carries the same number,
#    and it is kraken2's rather than bracken's: Segatella in sample 4211 is
#    4,720,453 on both, which is what kraken2 placed there and not the 4,893,782
#    bracken reassigned to it. So the choice is between two names for one chart,
#    and the one that does not promise bracken's estimates is the one to hand a
#    reader - and the other, being the same six megabytes under a name that
#    would mislead, is deleted rather than published beside it.
#
#    The folder's own listing page is passed over: index_directories.sh writes
#    it after this, and it sorts ahead of every chart in it.
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

if [[ -n "$KRONA_CHART" && -n "$KRONA_FALLBACK" ]]; then
    rm -f "$RESULTS_DIR/$KRONA_FALLBACK" \
        || warn "Could not delete the duplicate Krona chart $KRONA_FALLBACK."
fi

: "${KRONA_CHART:=$KRONA_FALLBACK}"

# 5. Delete what the run wrote for itself: the per-sample profiles every merged
#    table already holds, a tool's own scratch, and the reports MultiQC encoded
#    a second time. Ahead of the listings, so nothing describes a file that is
#    not there.
if ! "$NEXTFLOW_DIR/scripts/prune_results.sh" "$RESULTS_DIR" "$PRUNE_LIST"; then
    warn "The results could not be pruned; the run will publish its working files too."
fi

# 6. Give every folder below the results root a listing page, so that the folder
#    links the landing page carries still resolve once the results are objects in
#    a bucket rather than directories on disk. The staged reads get one too,
#    written inside the results under their own name: it names every file and its
#    size, greyed, since those files are only in the download.
if ! "$NEXTFLOW_DIR/scripts/index_directories.sh" "$RESULTS_DIR" "$FASTQ_DIR"; then
    warn "The results folders could not be indexed; their listings will be missing."
fi

# 7. Build the pages that frame all of it, from what the run produced.
dashboard_reset "$RESULTS_DIR" "$OUTPUT_CATALOG"

#    The navigation bar, after the Overview every run opens on
dashboard_view krona   "Taxonomy Explorer" "$KRONA_CHART"
dashboard_view quality "Technical Report"  "$MULTIQC_REPORT_HREF"
dashboard_index_view   "File Explorer"

#    The one table a requester opens first, named for what it holds rather than
#    for the tool, the database and the format that named the file: taxpasta's
#    merged bracken profile, the file to load into R or Python.
#
#    Nothing else is here. The second-opinion profiles MetaPhlAn and mOTUs
#    wrote, and the diversity table behind the plot the reader is already
#    looking at, are files a run produces rather than files a run is read
#    through - the file index lists every one of them, under the heading that
#    says what it is for. Everything this run published, the reads included,
#    comes down through the one button at the top of the page.
if ! dashboard_button "taxpasta/bracken_*.tsv" "Species abundance table"; then
    #    "|| true" because a glob that names nothing is a false return, and a
    #    run whose bracken step did not produce a table has nothing left to fall
    #    back to
    dashboard_button "taxpasta/kraken2_*.tsv" "Taxonomic profile table" || true
fi

#    The same table as an object with a tree in it, in the three formats it was
#    written in, so a requester can compute UniFrac and Faith's PD without
#    building a phylogeny of their own. Offered as one row of boxes because it
#    is one file three ways rather than three files.
dashboard_formats "Feature table" \
    "Counts and taxonomy for every species. The BIOM files carry the tree the diversity metrics are computed over." \
    "Plain text|feature_table/feature-table.tsv" \
    "JSON|feature_table/feature-table.json.biom" \
    "HDF5|feature_table/feature-table.hdf5.biom" || true

#    How the run was set up. The pipeline version comes off the manifest
#    wrike_job.sh recorded, so the page and the record cannot disagree; what was
#    depleted comes off the request.
PIPELINE=""

if state_has "$RUN_MANIFEST_KEY"; then
    PIPELINE=$(state_get "$RUN_MANIFEST_KEY.pipeline")
else
    warn "This run recorded no manifest; the page will not name the pipeline."
fi

#    What the run measured, as the sidebar reports it. The counts are whole
#    numbers written out in the units a sidebar has room for; the bars are only
#    how far each reading got.
declare -A STATS=()

while IFS=$'\t' read -r STAT_KEY STAT_VALUE; do
    STATS["$STAT_KEY"]="$STAT_VALUE"
done < <(state_get_tsv "$STATS_KEY")

# A count against the total it was taken against, as the fill a bar takes and
# the reading written beside it.
#
# The share is written whole, except where rounding it whole would read 100% for
# a step that did drop reads: quality filtering keeps 99.5% of a good run, and a
# sidebar calling that 100% tells the reader nothing happened.
#
# Nothing at all when either is not a count, which is how a step the run did not
# take leaves out its bar rather than reporting a share of nothing.
share_reading() {
    local count="$1" total="$2"

    [[ "$count" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 1
    (( total > 0 )) || return 1

    LC_ALL=C awk -v c="$count" -v t="$total" 'BEGIN {
        share = c * 100 / t
        text = sprintf("%.0f", share)

        if (text == "100" && c < t) {
            text = sprintf("%.1f", share)
            if (text == "100.0") text = "99.9"
        }

        printf "%.4f %s\n", share, text
    }'
}

# One reading as a bar: what it is, how many reads it was, and what share of the
# total. Green is for the reads that came through; what was taken out is left in
# the navy every total wears.
stat_share() {
    local label="$1" count="$2" total="$3" tone="${4:-growth}" details="${5:-}"
    local percent reading

    read -r percent reading < <(share_reading "$count" "$total") || return 0

    dashboard_stat_bar "$label" "$reading% · $(human_count "$count")" "$percent" \
        "$tone" "$details"
}

# The same reading as one of the steps behind a bar's "details" link
stat_share_detail() {
    local group="$1" label="$2" count="$3" total="$4" href="${5:-}"
    local percent reading

    read -r percent reading < <(share_reading "$count" "$total") || return 0

    dashboard_stat_detail "$group" "$label" "$reading% · $(human_count "$count")" \
        "$percent" "$href"
}

#    Reads as they reached the pipeline, and what was still in hand at each step
#    after it. Quality filtering counted them first, so its total is the one the
#    read totals are taken against; without it host removal's count is, and
#    without that the classifier's own.
TOTAL_READS=${STATS[qc_total]:-${STATS[host_total]:-${STATS[reads_total]:-}}}

#    What reached the classifier, which is what a classification share is a
#    share of: by then quality filtering and depletion have taken their cut, and
#    reading those bars against the reads the run started with would report the
#    classifier as having missed what it was never given. It is also what came
#    through the run as a whole, so it is the second of the read totals.
RETAINED_READS=${STATS[reads_total]:-$TOTAL_READS}

if [[ "$TOTAL_READS" =~ ^[0-9]+$ ]] && (( TOTAL_READS > 0 )); then
    #    What went in and what was left, on one scale, so the survival rate is
    #    the second bar by eye - the same two readings the amplicon dashboard
    #    reports. What each step in between took sits behind the "details" link
    #    on the second of them, out of the way of a reader who only wants the
    #    two, and each of those labels leads to that step's own accounting in the
    #    Technical Report.
    dashboard_stat_group "READ TOTALS" "${STATS[platform]:-}"
    dashboard_stat_bar "Total reads" "$(human_count "$TOTAL_READS")" 100

    #    Host depletion counts what bowtie2 was given rather than what quality
    #    filtering passed, so what is left is worked out from its own two
    #    numbers rather than by subtracting from the bar above.
    HOST_KEPT=""
    if [[ "${STATS[host_total]:-}" =~ ^[0-9]+$ && "${STATS[host_removed]:-}" =~ ^[0-9]+$ ]]; then
        HOST_KEPT=$(( STATS[host_total] - STATS[host_removed] ))
    fi

    stat_share_detail reads "After quality filter" "${STATS[qc_passed]:-}" "$TOTAL_READS" \
        "$(dashboard_report_section "$MULTIQC_REPORT" "$MULTIQC_REPORT_HREF" \
            "fastp-filtered-reads-chart fastp general_stats")"

    stat_share_detail reads "After host depletion" "$HOST_KEPT" "$TOTAL_READS" \
        "$(dashboard_report_section "$MULTIQC_REPORT" "$MULTIQC_REPORT_HREF" \
            "bowtie2 general_stats")"

    stat_share "Retained reads" "$RETAINED_READS" "$TOTAL_READS" growth reads

    dashboard_stat_group "READS PER SAMPLE"
    dashboard_stat_chips "$(human_count "${STATS[reads_min]:-0}")|Min" \
                         "$(human_count "${STATS[reads_median]:-0}")|Median" \
                         "$(human_count "${STATS[reads_max]:-0}")|Max"

    #    How far down the taxonomy the classifier could place a read. Each rank
    #    counts the reads that landed inside some clade of it, which is the same
    #    reading kraken2's own report gives, and each is a share of the reads it
    #    was given - so the three bars are one funnel rather than three readings.
    dashboard_stat_group "CLASSIFICATION" \
        "${STATS[profiler]:+${STATS[profiler]} · }${STATS[database]:-}"

    stat_share "Phylum level"  "${STATS[phylum_reads]:-}"  "$RETAINED_READS"
    stat_share "Genus level"   "${STATS[genus_reads]:-}"   "$RETAINED_READS"
    stat_share "Species level" "${STATS[species_reads]:-}" "$RETAINED_READS"
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

# 8. Package the whole run - the reads as they went in, and the results - as the
#    one file the dashboard offers. Named after the task and the uid, so a
#    requester can tell it apart in a downloads folder and still quote the run
#    back to us.
#
#    Built before the pages, because they say how big it is and what address it
#    is at; the pages then go in on top of it, in step 10. What that leaves out
#    of the figure the button shows is three HTML files, which is not a size a
#    reader is being told anything by.
#
#    The reads go in stored (-0), being already gzipped; the results are
#    deflated, being mostly HTML and tables.
BUNDLE_NAME=$(globus_bundle_name "$RUN_ID" "$TASK_NAME")
BUNDLE_PARTS=("$RESULTS_DIR|-9")

[[ -d "$FASTQ_DIR" ]] && BUNDLE_PARTS=("$FASTQ_DIR|-0" "${BUNDLE_PARTS[@]}")

log "Packaging $BUNDLE_NAME for task $TASK_ID..."

# zip's output goes into the failure message, so the requester is told why their
# data could not be packaged
if ! ZIP_OUTPUT=$(globus_archive "$RUN_ID" "$BUNDLE_NAME" "${BUNDLE_PARTS[@]}"); then
    fail "This run could not be packaged for download:"$'\n'"$ZIP_OUTPUT"
fi

dashboard_bundle "$(globus_run_url "$RUN_ID" "$BUNDLE_NAME")" \
    "$(globus_archive_size "$RUN_ID" "$BUNDLE_NAME")"

# 9. Write the three pages into the results folder, so the copy in that archive
#    is the same dashboard the bucket will serve.
if ! RENDER_OUTPUT=$(render_dashboard "$RUN_ID" "$TASK_NAME" "$SUBTITLE" \
        "$PIPELINE" "$(date '+%b %-d, %Y')" "$SAMPLE_COUNT" "$EXPIRES_ON" \
        "$PLOT_DATA_FILE"); then
    fail "The pages that present these results could not be built:"$'\n'"$RENDER_OUTPUT"
fi

# 10. And into the archive, which was built without them. A download missing
#     them is still every file the run produced, so this warns rather than fails.
BUNDLE_PAGES=()
for PAGE in "${DASHBOARD_PAGES[@]}"; do
    BUNDLE_PAGES+=("$RESULTS_DIR/$PAGE")
done

if ! ZIP_OUTPUT=$(globus_archive_add "$RUN_ID" "$BUNDLE_NAME" "${BUNDLE_PAGES[@]}"); then
    warn "The download will not carry the dashboard's own pages:"$'\n'"$ZIP_OUTPUT"
fi

# 11. Publish everything, the pages last - the landing page overwrites the
#     progress page published to that key.
log "Initiating S3 upload for Task $TASK_ID..."

if ! UPLOAD_OUTPUT=$(publish_results "$S3_RESULTS_DIR"); then
    fail "The results could not be uploaded to S3:"$'\n'"$UPLOAD_OUTPUT"
fi

set_wrike_custom_field "$WRIKE_DASHBOARD_URL_CFID" "$S3_RESULTS_URL"
log "Upload successful: $S3_RESULTS_URL"
