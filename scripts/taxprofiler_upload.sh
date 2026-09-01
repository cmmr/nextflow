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
# The two bulky downloads do not go to S3 at all. The reads
# taxprofiler_samplesheet.sh staged, and the whole dashboard as one zip, are
# written into the run's directory on the CMMR-Nextflow guest collection and
# linked from the page - see scripts/globus.sh. A WGS run's inputs are large
# enough that uploading them would cost more than the analysis did; from the
# collection they cost neither storage in the bucket nor egress out of it, and
# the requester gets them at the cluster's own bandwidth.
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

# Input FASTQ directory, named to match what taxprofiler_samplesheet.sh creates,
# and the archive it becomes on the guest collection. Both are named for the
# reader downloading them, since those names are what the buttons show.
FASTQ_DIR="raw-sequences"
FASTQ_ZIP_NAME="raw-sequences.zip"

# The whole dashboard as one zip, published beside the reads
DASHBOARD_ZIP_NAME="dashboard.zip"

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

# 2. Archive the reads into this run's directory on the guest collection. A WGS
#    run's inputs are larger than everything else it publishes put together, and
#    from there they are a copy on the cluster's own disk rather than an upload.
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
#    a bucket rather than directories on disk.
if ! "$NEXTFLOW_DIR/scripts/index_directories.sh" "$RESULTS_DIR"; then
    warn "The results folders could not be indexed; their listings will be missing."
fi

# 7. Build the pages that frame all of it, from what the run produced.
dashboard_reset "$RESULTS_DIR" "$OUTPUT_CATALOG" "$(globus_run_url "$RUN_ID")"

#    The navigation bar, after the Overview every run opens on
dashboard_view krona   "Taxonomy Explorer" "$KRONA_CHART"
dashboard_view quality "Technical Report"  "multiqc/multiqc_report.html"
dashboard_index_view   "File Explorer"

#    The one table a requester opens first, named for what it holds rather than
#    for the tool, the database and the format that named the file: taxpasta's
#    merged bracken profile, the file to load into R or Python. The two archives
#    follow it: the reads as they went in, and the whole of this dashboard, both
#    served from the guest collection and both of what "Download everything"
#    fetches.
#
#    Nothing else is here. The second-opinion profiles MetaPhlAn and mOTUs
#    wrote, and the diversity table behind the plot the reader is already
#    looking at, are files a run produces rather than files a run is read
#    through - the file index lists every one of them, under the heading that
#    says what it is for.
if ! dashboard_button "taxpasta/bracken_*.tsv" "Species abundance table"; then
    #    "|| true" because a glob that names nothing is a false return, and a
    #    run whose bracken step did not produce a table has nothing left to fall
    #    back to
    dashboard_button "taxpasta/kraken2_*.tsv" "Taxonomic profile table" || true
fi

dashboard_bundle "Raw sequencing data" "$FASTQ_URL"
dashboard_bundle "All result files" "$(globus_run_url "$RUN_ID" "$DASHBOARD_ZIP_NAME")"

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

# One reading as a bar: what it is, how many reads it was, and what share of the
# total it was taken against. Green is for the reads that came through; what was
# taken out is left in the navy every total wears.
#
# The share is written whole, except where rounding it whole would read 100% for
# a step that did drop reads: quality filtering keeps 99.5% of a good run, and a
# sidebar calling that 100% tells the reader nothing happened.
stat_share() {
    local label="$1" count="$2" total="$3" tone="${4:-growth}"
    local percent reading

    [[ "$count" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 0
    (( total > 0 )) || return 0

    read -r percent reading < <(LC_ALL=C awk -v c="$count" -v t="$total" 'BEGIN {
        share = c * 100 / t
        text = sprintf("%.0f", share)

        if (text == "100" && c < t) {
            text = sprintf("%.1f", share)
            if (text == "100.0") text = "99.9"
        }

        printf "%.4f %s\n", share, text
    }')

    dashboard_stat_bar "$label" "$reading% · $(human_count "$count")" "$percent" "$tone"
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
    #    reports. What each step in between took is that step's own accounting
    #    and is in the Technical Report; a sidebar carrying all of it is a funnel
    #    nobody reads.
    dashboard_stat_group "READ TOTALS" "${STATS[platform]:-}"
    dashboard_stat_bar "Total reads" "$(human_count "$TOTAL_READS")" 100

    stat_share "Retained reads" "$RETAINED_READS" "$TOTAL_READS"

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

# 8. Write the three pages into the results folder, so the zip below holds the
#    same dashboard the bucket will serve.
if ! RENDER_OUTPUT=$(render_dashboard "$RUN_ID" "$TASK_NAME" "$SUBTITLE" \
        "$PIPELINE" "$(date '+%b %-d, %Y')" "$SAMPLE_COUNT" "$EXPIRES_ON" \
        "$PLOT_DATA_FILE"); then
    fail "The pages that present these results could not be built:"$'\n'"$RENDER_OUTPUT"
fi

# 9. Archive the finished dashboard beside the reads. Deflated rather than
#    stored: what is left after the pruning is mostly HTML and tables.
if ! ZIP_OUTPUT=$(globus_archive "$RUN_ID" "$DASHBOARD_ZIP_NAME" "$RESULTS_DIR"); then
    warn "The results could not be packaged as one download:"$'\n'"$ZIP_OUTPUT"
fi

# 10. Publish everything, the pages last - the landing page overwrites the
#     progress page published to that key.
log "Initiating S3 upload for Task $TASK_ID..."

if ! UPLOAD_OUTPUT=$(publish_results "$S3_RESULTS_DIR"); then
    fail "The results could not be uploaded to S3:"$'\n'"$UPLOAD_OUTPUT"
fi

set_wrike_custom_field "$WRIKE_DASHBOARD_URL_CFID" "$S3_RESULTS_URL"
log "Upload successful: $S3_RESULTS_URL"
