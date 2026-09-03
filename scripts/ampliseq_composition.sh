#!/bin/bash
#
# ampliseq_composition.sh - Work out what a run found, for the dashboard to plot.
#
# Author: Daniel Smith
# Date:   August 27th, 2026
#
# What a requester wants out of a 16S run is usually two things: what was in each
# sample, and how varied each sample was. Both are worked out from the run's own
# feature table, which is assembled here rather than taken from the pipeline.
#
# scripts/R/ampliseq_tables.R does that work, in the rbiom container. It reads
# what DADA2 published - counts, taxonomy and sequences - and the phylogeny
# EPA-NG placed those ASVs on, assembles them into one object, and writes:
#
#   feature_table/         the same table as classic TSV, BIOM 1.0 and BIOM 2.1
#   abundance_tables/      counts and sample shares collapsed to each rank
#   alpha_diversity.tsv    per-sample diversity, unrarefied
#   composition_data.json  what the Overview's two charts draw
#
# so the file a requester downloads and the numbers on the page are the same
# object read twice. QIIME 2 built these before, and no longer runs: see
# docs/results/composition.md.
#
# What is left here is everything that does not come out of the feature table.
# The read totals are counted off overall_summary.tsv, which is the only place
# the reads that went in are written down, and the classification database is
# read off DADA2's own record of it. Both are added to the "statistics" of
# ./run_state.json beside the counts the R script returned, for
# ampliseq_upload.sh to read.
#
# Nothing is rarefied, and no group is compared against another: these runs
# carry no experimental metadata to compare by. The read depth every index was
# computed at is published in the same table for a reader to judge them against,
# and the feature table is there to be rarefied downstream.
#
# Usage:     ampliseq_composition.sh [results_dir]
#            defaults to ./results, the outdir set in the ampliseq params file
# Called by: ampliseq_upload.sh, before it indexes and uploads the results
# Requires:  GNU awk, apptainer
# Reads:     scripts/R/ampliseq_tables.R
# Outputs:   <results_dir>/feature_table/, <results_dir>/abundance_tables/,
#            <results_dir>/alpha_diversity.tsv, ./composition_data.json,
#            and the "statistics" of ./run_state.json
# Env:       NEXTFLOW_DIR, RBIOM_CONTAINER, the log/warn/fail helpers and the
#            run state helpers, sourced from .env

set -euo pipefail

source /data/prod/nextflow/.env

RESULTS_DIR="${1:-results}"
RESULTS_DIR="${RESULTS_DIR%/}"

# R with rbiom, h5lite and phyloseq, built from nix/rbiom.nix - which pins every
# version in the closure to one nixpkgs revision. See docs/operations/nix.md.
# Set in .env; a path to a .sif, or any address apptainer can pull.
readonly RBIOM_CONTAINER="${RBIOM_CONTAINER:-}"

# The script that does the work, run inside that container
readonly TABLES_SCRIPT="$NEXTFLOW_DIR/scripts/R/ampliseq_tables.R"

# Reads surviving each stage of the pipeline, one row per sample, which is the
# only place the reads that went in are counted
readonly OVERALL_SUMMARY="$RESULTS_DIR/overall_summary.tsv"

# DADA2's record of which reference it classified against, named for the
# database the run used
readonly TAXONOMY_DIR="$RESULTS_DIR/dada2"

# What FastQC measured off each raw FASTQ, as MultiQC tabulated it. The zips
# FastQC wrote are pruned from the results; this table is not.
readonly FASTQC_TABLE="$RESULTS_DIR/multiqc/multiqc_data/multiqc_fastqc.txt"

# What the Overview's two plots are drawn from, in the run directory rather than
# in the results: it is that page's own data, and every number in it comes from
# a table that is published
readonly PLOT_DATA="composition_data.json"

# The headline counts the R script returns, as key and value, for the sidebar
readonly STATS_KEY="statistics"

# The columns of the summary the sidebar breaks the read total down by. Which of
# them a run wrote depends on the path it took - chopper and savont are the
# nanopore route, DADA2's four the Illumina one, cutadapt either - so a stage a
# run never reached simply has no column and is left out.
#
# They are reported in the order the summary's own header lists them, which is
# the order they ran, rather than in the order named here: the two paths do not
# run their steps in the same order, and a funnel whose bars rise partway down
# is not a funnel.
readonly READ_STAGE_COLUMNS=(
    chopper_output
    cutadapt_passing_filters
    filtered
    merged
    nonchim
    savont_output
    ssufilter_output
    lenfilter_output
)

# Everything the R script hands back, before it is merged with what is counted
# here
readonly WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

readonly TABLE_STATS="$WORK/statistics.tsv"


# The stages this run's summary actually carries, in the order its header lists
# them - which is the order the pipeline ran them in.
summary_stages() {
    LC_ALL=C awk -F'\t' -v known="${READ_STAGE_COLUMNS[*]}" '
        BEGIN { split(known, list, " "); for (i in list) wanted[list[i]] = 1 }

        NR == 1 {
            for (i = 1; i <= NF; i++) {
                if ($i in wanted) printf "%s%s", (found++ ? " " : ""), $i
            }

            printf "\n"
            exit
        }
    ' "$OVERALL_SUMMARY"
}

# Reads at one stage of the run, summed over every sample. The stage is named as
# the columns that could carry it, earliest first, and the first of them the
# summary has is the one taken - which column counts a stage depends on what the
# run did. Prints nothing when the summary carries none of them, so a caller can
# leave out a stage this run never reached.
#
# cutadapt writes its counts with thousands separators, so everything that is
# not part of the number is stripped before it is read as one.
summary_reads() {
    LC_ALL=C awk -F'\t' -v candidates="$1" '
        NR == 1 {
            for (i = 1; i <= NF; i++) at[$i] = i

            split(candidates, want, " ")

            for (i = 1; i in want; i++) {
                if (want[i] in at) { pick = at[want[i]]; break }
            }
            next
        }

        pick {
            reads = $pick
            gsub(/[^0-9.]/, "", reads)
            total += reads + 0
        }

        END { if (pick) print total + 0 }
    ' "$OVERALL_SUMMARY"
}

total_input_reads() {
    summary_reads "chopper_input cutadapt_total_processed DADA2_input input_reads input"
}

# The reference DADA2 classified against, as it titles itself
taxonomy_database() {
    local path title

    for path in "$TAXONOMY_DIR"/ref_taxonomy.*.txt; do
        [[ -r "$path" ]] || continue

        title=$(LC_ALL=C awk '/^Title: / { sub(/^Title:[ \t]*/, ""); print; exit }' "$path")

        [[ -n "$title" ]] || continue

        printf '%s' "$title"
        return 0
    done

    return 1
}

# The chemistry FastQC read off the raw files, as a reader says it: "2 × 250 bp"
# for a paired run, "250 bp" for a single-ended one, and "250 + 150 bp" where the
# two mates were read to different lengths.
#
# FastQC states a length as one number or as a range - "35-251" for files a
# trimmer has already been over - and the chemistry is the longest read in the
# file, so the top of the range is what is taken.
#
# A mate is read off the trailing _1 / _2 MultiQC names the file by, and the
# commonest length of each mate is the run's, since one file sequenced
# differently does not rename the run. Ties go to the longer, or the page would
# come out differently on two runs of the same data.
#
# A nanopore run has none of this to report. Its read lengths are a wide
# distribution rather than a chemistry - the sequencer reads whatever molecule it
# is given, to whatever length that molecule is - so any one number for them
# would describe the run less well than saying nothing. Such a run is named by
# its instrument alone.
read_chemistry() {
    local chemistry

    [[ "$(state_get "manifest.params.sequencing_type")" == "nanopore" ]] && return 1

    [[ -r "$FASTQC_TABLE" ]] || return 1

    chemistry=$(LC_ALL=C awk -F'	' '
        function longest(s,   n, top) {
            while (match(s, /[0-9]+/)) {
                n = substr(s, RSTART, RLENGTH) + 0
                if (n > top) top = n
                s = substr(s, RSTART + RLENGTH)
            }

            return top
        }

        NR == 1 {
            for (i = 1; i <= NF; i++) at[$i] = i

            if (!("Sample" in at) || !("Sequence length" in at)) exit

            named = 1
            next
        }

        named {
            mate = ($(at["Sample"]) ~ /_2$/) ? 2 : 1
            seen[mate, longest($(at["Sequence length"]))]++
        }

        END {
            for (key in seen) {
                split(key, part, SUBSEP)
                mate = part[1] + 0
                bp   = part[2] + 0

                if (seen[key] < most[mate]) continue
                if (seen[key] == most[mate] && bp <= len[mate]) continue

                most[mate] = seen[key]
                len[mate]  = bp
            }

            if (!len[1])                  exit
            else if (!len[2])             printf "%d bp", len[1]
            else if (len[1] == len[2])    printf "2 × %d bp", len[1]
            else                          printf "%d + %d bp", len[1], len[2]
        }
    ' "$FASTQC_TABLE")

    [[ -n "$chemistry" ]] || return 1

    printf '%s' "$chemistry"
}

# How those numbers were made, for the caption under the composition chart
composition_method() {
    local database

    database=$(taxonomy_database) || return 1

    printf 'ASVs were inferred with DADA2 and classified against %s.' "$database"
}

# Everything the sidebar reports: what the R script counted off the feature
# table, the chemistry FastQC read off the raw files, and the read totals counted
# off the summary beside them.
write_run_statistics() {
    local CHEMISTRY

    {
        cat "$TABLE_STATS"

        CHEMISTRY=$(read_chemistry) && printf 'read_chemistry	%s
' "$CHEMISTRY"

        if [[ -r "$OVERALL_SUMMARY" ]]; then
            printf 'reads_total\t%s\n' "$(total_input_reads)"

            #    The order is the sidebar's to follow, and only this script has
            #    read the header it comes from, so it is recorded beside the
            #    counts rather than left to be guessed at from them
            READ_STAGES=$(summary_stages)

            if [[ -n "$READ_STAGES" ]]; then
                printf 'read_stages\t%s\n' "$READ_STAGES"

                for READ_STAGE in $READ_STAGES; do
                    printf 'reads_%s\t%s\n' "$READ_STAGE" "$(summary_reads "$READ_STAGE")"
                done
            fi
        fi
    } | state_set_tsv "$STATS_KEY"
}


log "Summarising composition and diversity under $RESULTS_DIR..."

# A server that cannot run the builder warns and stops rather than failing:
# these are our problem rather than the requester's, and fail would put the
# message on their Wrike task. The upload carries on and publishes the
# pipeline's own outputs; the Overview falls back to its empty state.
if ! command -v apptainer > /dev/null; then
    warn "apptainer is not installed; the feature table will not be assembled."
    exit 1
fi

if [[ -z "$RBIOM_CONTAINER" ]]; then
    warn "RBIOM_CONTAINER is not set; the feature table will not be assembled." \
         "Build it from nix/rbiom.nix - see docs/operations/nix.md - and set" \
         "RBIOM_CONTAINER in .env to the image."
    exit 1
fi

# A path that names nothing is the ordinary way this is wrong: .env points at
# opt/rbiom.sif, and the image has not been built on this host yet. Said here
# rather than left to apptainer, which reports it as a failure to pull.
if [[ "$RBIOM_CONTAINER" == /* && ! -e "$RBIOM_CONTAINER" ]]; then
    warn "There is no image at $RBIOM_CONTAINER; the feature table will not be" \
         "assembled. Build it from nix/rbiom.nix - see docs/operations/nix.md."
    exit 1
fi

if [[ ! -r "$TABLES_SCRIPT" ]]; then
    warn "The table builder is missing from the server ($TABLES_SCRIPT)."
    exit 1
fi

# 1. The feature table, and everything read off it. A run whose ASVs could not
#    be assembled leaves the Overview on its empty state rather than failing the
#    upload: the pipeline's own outputs are still worth publishing.
EXCLUDE_TAXA=$(state_get "manifest.params.exclude_taxa") || true
: "${EXCLUDE_TAXA:=none}"

#    How the numbers were made, for the caption under the composition chart.
#    Passed in rather than edited into the rendered file afterwards: a database
#    title is free to contain the characters sed reads as syntax.
if ! METHOD=$(composition_method); then
    warn "The classification database could not be named; the Overview will not state it."
    METHOD=""
fi

if ! R_OUTPUT=$(apptainer exec -B /data "$RBIOM_CONTAINER" \
        Rscript --vanilla "$TABLES_SCRIPT" \
            "$RESULTS_DIR" "$PLOT_DATA" "$TABLE_STATS" \
            "$EXCLUDE_TAXA" "$METHOD" 2>&1); then
    warn "The feature table could not be assembled; the Overview will show no plots:"$'\n'"$R_OUTPUT"
    rm -f "$PLOT_DATA"
    exit 0
fi

[[ -n "$R_OUTPUT" ]] && log "$R_OUTPUT"

if [[ ! -s "$PLOT_DATA" ]]; then
    warn "No plot data was written; the Overview will show no plots."
    rm -f "$PLOT_DATA"
    exit 0
fi

# 2. The counts the sidebar reports, from the R script and from the summary
if [[ -s "$TABLE_STATS" ]]; then
    if ! write_run_statistics; then
        warn "The run statistics could not be counted; the dashboard will show fewer numbers."
        state_unset "$STATS_KEY" || true
    fi
fi

log "Wrote $PLOT_DATA and the feature table under $RESULTS_DIR."
