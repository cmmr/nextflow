#!/bin/bash
#
# taxprofiler_composition.sh - Work out what a shotgun run found, for the dashboard to plot.
#
# Author: Daniel Smith
# Date:   August 28th, 2026
#
# The counterpart of ampliseq_composition.sh, writing the same two files in the
# same shapes so both pipelines are read through the same Overview. What a
# requester wants out of a WGS run is what they want out of a 16S run: what was
# in each sample, and how varied each sample was. taxprofiler answers the first
# only as Krona sunbursts - one page per classifier, with no way to read one
# sample against another - and the second not at all.
#
# Composition is worked out from the kraken2-style reports the run publishes:
#
#   bracken/<db>/<sample>_<db>.bracken.kraken2.report_bracken.txt   preferred
#   kraken2/<db>/<sample>_<db>.kraken2.kraken2.report.txt           fallback
#
# Either carries a clade count at every rank, so a rank is read straight off the
# report rather than rolled up from a species table. Bracken's is preferred
# because it redistributes the reads kraken2 stranded at internal nodes down to
# the species they came from, which is what makes a stacked bar mean what it
# looks like it means.
#
# The kraken2 reports are read whichever of the two is plotted. They are the only
# place the unclassified reads are counted, and the only honest account of how
# far the classifier got, since bracken renormalises over what it placed. So
# every share here is a share of every read that reached the classifier, and the
# sidebar reports how many of them were resolved to phylum, genus and species.
#
# The unclassified reads are counted as a taxon of their own and written out
# with the rest, so the file records what the run actually found. The Overview
# does not draw that taxon: on a shotgun run it is routinely the largest share of
# the sample, and a slab that says only how much went unnamed buried the taxa
# under it. Its share is what the columns there fall short of 100% by.
#
# The rest of the sidebar's read funnel is counted in the same pass, out of the
# reports each step of the run wrote about itself: fastp's say how many reads
# quality filtering was given and how many came through, bowtie2's say what the
# host took, and the kraken2 reports say what reached the classifier. fastp also
# names the chemistry it read off the files, which is what the funnel is headed
# with.
#
# Only the eleven most abundant taxa of each rank are kept, the rest summed into
# "Other": past that fill no reader can tell one colour from the next, and the
# merged taxpasta tables are published for anyone who needs every row.
#
# Diversity is not computed from those reports at all. Half the reads of a WGS
# sample routinely reach no taxon, and Shannon, Simpson and Pielou over the half
# a database happens to name describe the database as much as they describe the
# sample. Two tools that do not depend on one answer instead:
#
#   nonpareil/nonpareil_all_samples.tsv   how much of the community was covered
#   motus/<db>/<sample>_<db>.out          how many species-level clusters there were
#
# Nonpareil reads redundancy straight off the reads - how often the same sequence
# turns up - so the unclassified half counts too, and reports the diversity index
# Nd, the share of the community the reads cover, and the sequencing it would
# take to cover 95% of it. mOTUs counts the species-level clusters it finds in
# universal marker genes, which is a count of what was there rather than of what
# a taxonomy carries a name for. The depth each was measured at is published in
# the same table for the reader to judge them against.
#
# Nonpareil's curves are fitted per run rather than per sample, on the reads
# fastp left and before the host was taken out - that is where taxprofiler wires
# it - so a sample sequenced twice keeps its deepest run rather than an average.
#
# The feature tables a requester loads are built here too, by
# scripts/R/taxprofiler_tables.R in the rbiom container: the merged profile as a
# BIOM with a tree in it, so that UniFrac and Faith's PD can be computed from a
# shotgun run the way they can from a 16S one. Two trees carry that - the NCBI
# taxonomy over the taxa the run saw, built by taxprofiler_taxonomy_tree.sh, and
# the phylogeny MetaPhlAn publishes with its own database - and Faith's PD comes
# back from both into the table below, with the share of the run's reads each
# reading covers beside it.
#
# Usage:     taxprofiler_composition.sh [results_dir]
#            defaults to ./results, the outdir set in the taxprofiler params file
# Called by: taxprofiler_upload.sh, before it indexes and uploads the results
# Requires:  GNU awk; jq, for the fastp reports; apptainer and the rbiom
#            container, for the feature tables
# Runs:      taxprofiler_taxonomy_tree.sh and scripts/R/taxprofiler_tables.R
# Outputs:   <results_dir>/alpha_diversity.tsv
#            <results_dir>/feature_table/
#            ./composition_data.json
#            the "statistics" of ./run_state.json
# Env:       NEXTFLOW_DIR, RBIOM_CONTAINER, the log/warn/fail helpers and the run
#            state helpers, sourced from .env

set -euo pipefail

source /data/prod/nextflow/.env

RESULTS_DIR="${1:-results}"
RESULTS_DIR="${RESULTS_DIR%/}"

# One folder per database, holding one report per sample
readonly BRACKEN_DIR="$RESULTS_DIR/bracken"
readonly KRAKEN2_DIR="$RESULTS_DIR/kraken2"

# Host removal's own accounting, one log per sample, for a run that depleted
# anything at all
readonly BOWTIE2_DIR="$RESULTS_DIR/bowtie2/align"

# Quality filtering's own accounting, one report per run of every sample, for a
# run that took the short-read path
readonly FASTP_DIR="$RESULTS_DIR/fastp"

# What the diversity half is read from. Nonpareil writes one summary over every
# curve in the run; mOTUs writes one profile per sample, under a folder named
# for the database, like every other profiler here.
readonly NONPAREIL_DIR="$RESULTS_DIR/nonpareil"
readonly NONPAREIL_SUMMARY="nonpareil_all_samples.tsv"
readonly MOTUS_DIR="$RESULTS_DIR/motus"
readonly MOTUS_SUFFIX=".out"

readonly ALPHA_TABLE="$RESULTS_DIR/alpha_diversity.tsv"

# What the feature tables are built from and by. The database sheet is looked
# for in the results first, where taxprofiler_upload.sh copies it, so a rerun
# over a finished results folder finds the databases that run actually used.
readonly TAXPASTA_DIR="$RESULTS_DIR/taxpasta"
readonly METAPHLAN_DIR="$RESULTS_DIR/metaphlan"
readonly DB_SHEET="taxprofiler_database.csv"

readonly TABLES_SCRIPT="$NEXTFLOW_DIR/scripts/R/taxprofiler_tables.R"
readonly TREE_SCRIPT="$NEXTFLOW_DIR/scripts/taxprofiler_taxonomy_tree.sh"

# R with rbiom and h5lite, built from nix/rbiom.nix. Set in .env; a path to a
# .sif, or any address apptainer can pull.
readonly RBIOM_CONTAINER="${RBIOM_CONTAINER:-}"

# What the Overview's two plots are drawn from, in the run directory rather than
# in the results: it is that page's own data, and every number in it comes from
# a report that is published
readonly PLOT_DATA="composition_data.json"

# Where the run's headline numbers go, in the run's state file rather than in
# the results: they are the dashboard's sidebar, not an output of the analysis
readonly STATS_KEY="statistics"

# How many named taxa of each rank are drawn in their own colour before the tail
# is summed into "Other". Eleven is what the palette carries. The unclassified
# share is not one of them - the page does not draw it - so a rank is written out
# as these eleven, that share, and "Other".
readonly TOP_TAXA=11

# The ranks a stacked bar is offered at, as the letter a kraken2-style report
# codes each one with, and the numbers the Overview knows them by. A code
# carrying a digit - S1, G2 - names a rank between two of these and is left out:
# its reads are already counted inside the clade above it.
readonly RANK_CODES=(P C O F G S)
readonly RANK_NUMBERS=(2 3 4 5 6 7)
readonly RANK_NAMES=(Phylum Class Order Family Genus Species)

# The suffix each kind of report is named with, after the sample and database
readonly BRACKEN_SUFFIX=".bracken.kraken2.report_bracken.txt"
readonly KRAKEN2_SUFFIX=".kraken2.kraken2.report.txt"

if [[ ! -d "$RESULTS_DIR" ]]; then
    fail "There is no '$RESULTS_DIR' directory to summarise."
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# sample <TAB> report, one line per sample, for each of the two sets of reports.
# The plotted set decides the sample order everything else is built in.
PROFILE_SET="$WORK/profiles.tsv"
KRAKEN2_SET="$WORK/kraken2.tsv"

# Every read that reached the classifier, as sample, unclassified and classified
READ_TOTALS="$WORK/reads.tsv"

# Reads a sample lost to the host, or empty for a run that depleted nothing
HOST_TABLE="$WORK/host.tsv"

# What nonpareil measured and how many clusters mOTUs found, one line per
# sample, or empty for a run that produced neither
NONPAREIL_TABLE="$WORK/nonpareil.tsv"
MOTUS_TABLE="$WORK/motus.tsv"

# mOTUs profiles as "sample <TAB> path", the same shape the classifier reports
# are collected in
MOTUS_SET="$WORK/motus_reports.tsv"

# Faith's PD off each of the two trees, as scripts/R/taxprofiler_tables.R
# returns it: sample, the index, and the abundance it was computed over
FAITH_TABLE="$WORK/faith.tsv"

# All five are opened by name inside awk, by passes that are already reading
# other files
export PROFILE_SET READ_TOTALS NONPAREIL_TABLE MOTUS_TABLE FAITH_TABLE

# Which tool and database the plots are drawn from, as the sidebar names them
PROFILE_TOOL=""
PROFILE_DB=""

# A report is named "<sample>_<db><suffix>" under a folder named "<db>", which is
# the only place the sample's own name survives.
report_sample_name() {
    local path="$1" suffix="$2"
    local name database

    name=${path##*/}
    database=${path%/*}
    database=${database##*/}

    name=${name%"$suffix"}

    printf '%s' "${name%"_$database"}"
}

# Every report of one kind as "sample <TAB> path", in sample order, written where
# the caller says. Fails for a run that produced none.
#
# One database's worth. A run given two databases for the same tool profiles
# every sample against each of them, and the two are not one measurement to
# average or to stack - so the first by name is the one summarised, and the rest
# are published without being plotted. Whichever it is, it is named on the page
# beside the numbers it produced.
collect_reports() {
    local root="$1" suffix="$2" out="$3"
    local path

    for path in "$root"/*/*"$suffix"; do
        [[ -r "$path" ]] || continue

        printf '%s\t%s\n' "$(report_sample_name "$path" "$suffix")" "$path"
    done | LC_ALL=C sort -k1,1 > "$out"

    [[ -s "$out" ]] || return 1

    LC_ALL=C awk -F'\t' '
        function database(path) {
            sub(/\/[^\/]*$/, "", path)
            sub(/.*\//, "", path)
            return path
        }

        NR == FNR {
            name = database($2)
            if (first == "" || name < first) first = name
            next
        }

        database($2) == first
    ' "$out" "$out" > "$out.one" && mv "$out.one" "$out"

    [[ -s "$out" ]]
}

# The database a set of reports was found under, off the folder holding the first
# of them
reports_database() {
    local path

    path=$(head -n 1 "$1" | cut -f2)
    path=${path%/*}

    printf '%s' "${path##*/}"
}

# Reads that never reached a taxon, and reads that did, per sample. Only the
# kraken2 report carries the first: bracken drops the unclassified line and
# renormalises over what it placed.
#
# The two together are every read that reached the classifier, which is the depth
# everything else here is a share of.
read_totals() {
    local -a reports=("$@")

    LC_ALL=C awk -F'\t' '
        NR == FNR { sample[$2] = $1; next }

        FNR == 1 { name = sample[FILENAME] }

        # The rank code and the taxon id sit at the end of the row, since a
        # report written with minimizer counts carries two more columns than one
        # without
        $(NF - 2) == "U"                   { unclassified[name] += $2 }
        $(NF - 2) == "R" && $(NF - 1) == 1 { classified[name] += $2 }

        END {
            for (name in classified)
                printf "%s\t%d\t%d\n", name, unclassified[name] + 0, classified[name]
        }
    ' "$KRAKEN2_SET" "${reports[@]}" | LC_ALL=C sort -k1,1
}

# Reads a sample lost to the host, off bowtie2's own summary. The first line
# counts what went in - pairs for a paired run, which is what the classifier
# counts too - and the rate at the end is the share of them that was host.
host_removal() {
    local path name

    for path in "$BOWTIE2_DIR"/*.bowtie2.log; do
        [[ -r "$path" ]] || continue

        name=${path##*/}
        name=${name%.bowtie2.log}

        LC_ALL=C awk -v name="$name" '
            /reads; of these:/ && !total     { total = $1 + 0 }
            /overall alignment rate/         { rate = $1 + 0 }

            END {
                if (total > 0)
                    printf "%s\t%d\t%d\n", name, total, int(total * rate / 100 + 0.5)
            }
        ' "$path"
    done
}

# Every fastp report the run wrote, or nothing for a run that filtered no short
# reads
fastp_reports() {
    local path

    for path in "$FASTP_DIR"/*.fastp.json; do
        [[ -r "$path" ]] || continue

        printf '%s\n' "$path"
    done
}

# Reads that reached quality filtering and reads that came through it, summed
# over every report.
#
# Counted in pairs where the reads are paired, because that is what host removal
# and the classifier count: fastp counts each mate of a pair as a read of its
# own, and a funnel whose first two bars count halves of what the bars under
# them count is not a funnel.
fastp_totals() {
    jq -s -r '
        map({
            mates:  (if (.summary.sequencing // "") | startswith("paired end")
                     then 2 else 1 end),
            before: (.summary.before_filtering.total_reads // 0),
            passed: (.filtering_result.passed_filter_reads // 0)
        })
        | "qc_total\t\(map(.before / .mates) | add | floor)\n"
          + "qc_passed\t\(map(.passed / .mates) | add | floor)"
    ' "$@"
}

# The chemistry fastp read off the files, as a reader says it: "2 × 151 bp" for
# a paired run, "151 bp" for a single-ended one. fastp states it as "paired end
# (151 cycles + 151 cycles)", so the cycle counts are what is read out of it.
#
# The commonest reading across the run's files, since one file sequenced
# differently does not rename the run. Ties go to the reading that sorts first,
# or the page would come out differently on two runs of the same data.
read_chemistry() {
    jq -r '.summary.sequencing // empty' "$@" | LC_ALL=C awk '
        { seen[$0]++ }

        END {
            for (line in seen) {
                if (seen[line] < best || (seen[line] == best && line >= text)) continue

                best = seen[line]
                text = line
            }

            while (match(text, /[0-9]+/)) {
                cycles[++n] = substr(text, RSTART, RLENGTH) + 0
                text = substr(text, RSTART + RLENGTH)
            }

            if (n == 1)                                printf "%d bp", cycles[1]
            else if (n >= 2 && cycles[1] == cycles[2]) printf "2 × %d bp", cycles[1]
            else if (n >= 2)                           printf "%d + %d bp", cycles[1], cycles[2]
        }'
}

# What the reads were, as the note the read totals are headed with: the platform
# the samplesheet measured them into, and the chemistry fastp read off them.
#
# A run from before the platform was recorded is read off its own reports
# instead - fastp writes for the short-read path only - which is right for every
# such run, since the long-read path has only ever been taken by nanopore.
sequencing_summary() {
    local platform chemistry=""

    platform=$(state_get samples.platform)

    if [[ -z "$platform" ]]; then
        if (( ${#FASTP_REPORTS[@]} > 0 )); then
            platform="ILLUMINA"
        else
            platform="OXFORD_NANOPORE"
        fi
    fi

    case "$platform" in
        ILLUMINA)        platform="Illumina" ;;
        OXFORD_NANOPORE) platform="Nanopore" ;;
        PACBIO_SMRT)     platform="PacBio" ;;
    esac

    if (( ${#FASTP_REPORTS[@]} > 0 )); then
        chemistry=$(read_chemistry "${FASTP_REPORTS[@]}")
    fi

    printf '%s%s' "$platform" "${chemistry:+, $chemistry}"
}

# What nonpareil measured, one line per sample, or nothing for a run without it.
#
# NonpareilCurves.R writes one row per curve, labelled as the run it was fitted
# to, and R leaves that table's header one field short - the row names have no
# column of their own - so the header is matched to the data rather than
# assumed. A label is matched back to the sample whose name it starts with,
# since a sample name is free to hold an underscore of its own.
#
# A sample sequenced over several runs keeps its deepest run rather than an
# average of them: every one of these readings saturates with sequencing effort,
# so the run that saw the most reads is the best supported estimate of the same
# community.
#
# Coverage and redundancy are written as percentages and the two efforts in Gbp,
# which is how they are read; nonpareil reports the first two as fractions and
# the second two in base pairs. A reading nonpareil could not fit is written NA
# rather than zero.
nonpareil_table() {
    local summary="" path

    for path in "$NONPAREIL_DIR/$NONPAREIL_SUMMARY" "$NONPAREIL_DIR"/*.tsv; do
        [[ -r "$path" ]] || continue

        summary="$path"
        break
    done

    [[ -n "$summary" ]] || return 0

    LC_ALL=C awk -F'\t' '
        function numeric(v) {
            return v ~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/
        }

        function reading(v, scale) {
            return numeric(v) ? sprintf("%.4f", v * scale) : "NA"
        }

        # The sample a curve belongs to: the longest sample name its label
        # starts with, or the label itself for a run that was never split
        function sample_of(label,   name, best) {
            if (label in known) return label

            best = ""
            for (name in known)
                if (index(label, name "_") == 1 && length(name) > length(best))
                    best = name

            return best
        }

        BEGIN {
            while ((getline line < ENVIRON["PROFILE_SET"]) > 0) {
                split(line, field, "\t")
                known[field[1]] = 1
            }
        }

        FNR == 1 {
            for (i = 1; i <= NF; i++) head[i] = $i
            columns = NF
            next
        }

        # Where the header is a field short, every column named in it sits one
        # field to the right of where it was named
        FNR == 2 {
            shift = (NF == columns + 1) ? 1 : 0
            for (i = 1; i <= columns; i++) column[head[i]] = i + shift
        }

        {
            name = sample_of($1)
            if (name == "") next

            effort = numeric($(column["LR"])) ? $(column["LR"]) + 0 : 0
            if (name in depth && depth[name] >= effort) next

            depth[name]      = effort
            diversity[name]  = reading($(column["diversity"]), 1)
            coverage[name]   = reading($(column["C"]), 100)
            redundancy[name] = reading($(column["kappa"]), 100)
            fit[name]        = reading($(column["modelR"]), 1)
            spent[name]      = reading($(column["LR"]), 1 / 1000000000)
            needed[name]     = reading($(column["LRstar"]), 1 / 1000000000)
        }

        END {
            for (name in diversity)
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", name, diversity[name], \
                    coverage[name], redundancy[name], fit[name], spent[name], needed[name]
        }
    ' "$summary" | LC_ALL=C sort -k1,1
}

# How many mOTUs each sample carried, off its own profile.
#
# A profile names every cluster in the database and gives most of them a zero,
# so what is counted is the rows that were not zero. The unassigned row is not a
# cluster and is left out. The count is the last field of a row whichever flags
# mOTUs was given: the NCBI id it prints by default sits between the name and
# the number.
motus_table() {
    local -a reports=("$@")

    LC_ALL=C awk -F'\t' '
        NR == FNR { sample[$2] = $1; observed[$1] = 0; next }

        FNR == 1 { name = sample[FILENAME] }

        /^#/               { next }
        $1 == "unassigned" { next }

        $NF + 0 > 0 { observed[name]++ }

        END {
            for (name in observed) printf "%s\t%d\n", name, observed[name]
        }
    ' "$MOTUS_SET" "${reports[@]}" | LC_ALL=C sort -k1,1
}

# -- The feature tables, and the phylogenetic diversity read off them ---------

# The first file a glob matches, or nothing
first_match() {
    local path

    for path in "$@"; do
        [[ -r "$path" ]] || continue

        printf '%s' "$path"
        return 0
    done

    return 1
}

# One column of one tool's row in the database sheet this run was given
database_field() {
    local tool="$1" want="$2"
    local sheet

    sheet=$(first_match "$RESULTS_DIR/$DB_SHEET" "$DB_SHEET") || return 1

    LC_ALL=C awk -F, -v tool="$tool" -v want="$want" '
        NR == 1 { for (i = 1; i <= NF; i++) idx[$i] = i; next }
        idx["tool"] && idx[want] && $idx["tool"] == tool { print $idx[want]; exit }
    ' "$sheet"
}

# The taxon ids of a merged taxpasta table, one per line. A kraken2 table
# carries a row at every rank, and a clade count plus the counts inside it is
# the same read twice, so only its species rows are taken.
profile_taxon_ids() {
    local path="$1" species_only="$2"

    LC_ALL=C awk -F'\t' -v species_only="$species_only" '
        NR == 1 {
            for (i = 1; i <= NF; i++) idx[$i] = i
            if (!idx["taxonomy_id"]) exit 1
            next
        }

        species_only == 1 && idx["rank"] && $idx["rank"] != "species" { next }

        $idx["taxonomy_id"] ~ /^[0-9]+$/ && $idx["taxonomy_id"] != "0" \
            && $idx["taxonomy_id"] != "1" { print $idx["taxonomy_id"] }
    ' "$path"
}

# Whether the server can run the table builder at all. A server that cannot is
# our problem rather than the requester's, so it warns: the run still publishes
# everything the pipeline wrote and every plot on the Overview.
can_build_tables() {
    if ! command -v apptainer > /dev/null; then
        warn "apptainer is not installed; no feature table will be built."
        return 1
    fi

    if [[ -z "$RBIOM_CONTAINER" ]]; then
        warn "RBIOM_CONTAINER is not set; no feature table will be built." \
             "Build it from nix/rbiom.nix - see docs/operations/nix.md - and set" \
             "RBIOM_CONTAINER in .env to the image."
        return 1
    fi

    if [[ "$RBIOM_CONTAINER" == /* && ! -e "$RBIOM_CONTAINER" ]]; then
        warn "There is no image at $RBIOM_CONTAINER; no feature table will be" \
             "built. Build it from nix/rbiom.nix - see docs/operations/nix.md."
        return 1
    fi

    if [[ ! -r "$TABLES_SCRIPT" ]]; then
        warn "The table builder is missing from the server ($TABLES_SCRIPT)."
        return 1
    fi

    return 0
}

# The BIOM files a requester loads, and Faith's PD off each tree into
# $FAITH_TABLE. Everything here is optional: a run missing a profile, a
# taxonomy dump or the MetaPhlAn phylogeny publishes the tables it can and
# leaves those columns empty.
build_feature_tables() {
    local profile species_only=0
    local taxonomy_dir metaphlan_db metaphlan_name metaphlan_tree=""
    local metaphlan_profile="" tree="" lineage=""
    local ids="$WORK/taxon_ids.txt"

    can_build_tables || return 1

    if profile=$(first_match "$TAXPASTA_DIR"/bracken_*.tsv); then
        :
    elif profile=$(first_match "$TAXPASTA_DIR"/kraken2_*.tsv); then
        species_only=1
    else
        profile=""
        log "No merged taxpasta profile under $TAXPASTA_DIR; no feature table will be built."
    fi

    # The taxonomy dump the profile's own taxon ids come from. The Kraken2
    # database carries nodes.dmp and names.dmp, which is why taxpasta is pointed
    # at it too.
    taxonomy_dir=$(database_field kraken2 db_path) || taxonomy_dir=""

    if [[ -n "$profile" && -r "$taxonomy_dir/nodes.dmp" ]]; then
        if ! profile_taxon_ids "$profile" "$species_only" > "$ids"; then
            warn "The taxon ids could not be read from ${profile##*/}."
            : > "$ids"
        fi

        if [[ -s "$ids" ]]; then
            tree="$WORK/taxonomy.newick"
            lineage="$WORK/lineage.tsv"

            log "Building the taxonomy tree for $(wc -l < "$ids") taxa..."

            if ! "$TREE_SCRIPT" "$taxonomy_dir" "$ids" "$lineage" > "$tree"; then
                warn "The taxonomy tree could not be built; the feature table will carry none."
                tree=""
                lineage=""
            fi
        fi
    elif [[ -n "$profile" ]]; then
        warn "No nodes.dmp under \"$taxonomy_dir\"; the feature table will carry no tree."
    fi

    # MetaPhlAn's own phylogeny, fetched into its database directory by
    # fetch_taxprofiler_db.sh and named after the release
    metaphlan_db=$(database_field metaphlan db_path) || metaphlan_db=""
    metaphlan_name=$(database_field metaphlan db_name) || metaphlan_name=""

    if [[ -n "$metaphlan_db" && -n "$metaphlan_name" \
          && -r "$metaphlan_db/$metaphlan_name.nwk" ]]; then
        metaphlan_tree="$metaphlan_db/$metaphlan_name.nwk"
        metaphlan_profile=$(first_match "$METAPHLAN_DIR"/metaphlan_*_combined_reports.txt) \
            || metaphlan_profile=""
    else
        log "No MetaPhlAn phylogeny beside its database; no SGB table will be built."
    fi

    if [[ -z "$profile" && -z "$metaphlan_profile" ]]; then
        return 1
    fi

    local output

    # $WORK holds the tree and the lineage table, and is outside /data
    if ! output=$(apptainer exec -B /data -B "$WORK" "$RBIOM_CONTAINER" \
            Rscript --vanilla "$TABLES_SCRIPT" \
                "$RESULTS_DIR" "$FAITH_TABLE" "$profile" "$species_only" \
                "$tree" "$lineage" "$metaphlan_profile" "$metaphlan_tree" 2>&1); then
        warn "The feature tables could not be assembled:"$'\n'"$output"
        return 1
    fi

    [[ -n "$output" ]] && log "$output"

    return 0
}

# Per-sample diversity, as the table published with the results, in the sample
# order everything else on the page follows.
#
# Read depth is part of it: an estimate computed on 50,000 reads is not the same
# measurement as one computed on 5,000,000, and a reader can only see that if the
# depth is there. So is the model fit nonpareil reported, which is what says
# whether its estimate for that sample is worth reading at all.
#
# Nothing is rarefied. Rarefaction exists to make counts comparable between
# groups, and there are no groups here - and nonpareil's readings are estimates
# of the whole community rather than counts to be levelled.
write_alpha_table() {
    LC_ALL=C awk -F'\t' '
        function reading(v) {
            return v == "" ? "NA" : v
        }

        BEGIN {
            # Every read that reached the classifier, which is the depth the
            # readings beside it were measured at
            while ((getline line < ENVIRON["READ_TOTALS"]) > 0) {
                split(line, field, "\t")
                depth[field[1]] = field[2] + field[3]
            }

            while ((getline line < ENVIRON["NONPAREIL_TABLE"]) > 0) {
                split(line, field, "\t")
                diversity[field[1]]  = field[2]
                coverage[field[1]]   = field[3]
                redundancy[field[1]] = field[4]
                fit[field[1]]        = field[5]
                spent[field[1]]      = field[6]
                needed[field[1]]     = field[7]
            }

            while ((getline line < ENVIRON["MOTUS_TABLE"]) > 0) {
                split(line, field, "\t")
                motus[field[1]] = field[2]
            }

            # sample, Faith's PD on the taxonomy, the reads it covered, Faith's
            # PD on the MetaPhlAn phylogeny, and the abundance that one covered
            while ((getline line < ENVIRON["FAITH_TABLE"]) > 0) {
                split(line, field, "\t")
                if (field[1] == "sample") continue

                faith[field[1]]     = field[2]
                placed[field[1]]    = field[3]
                faith_sgb[field[1]] = field[4]
                sgb_pct[field[1]]   = field[5]
            }

            print "sample\treads\tnonpareil_diversity\tcoverage_pct\tredundancy_pct" \
                  "\tmodel_fit\teffort_gbp\teffort_95_gbp\tobserved_motus" \
                  "\tfaith_pd\tfaith_pd_basis_pct\tfaith_pd_sgb\tfaith_pd_sgb_basis_pct"
        }

        # What share of the reads that reached the classifier ended up on the
        # tree the index was computed over. A phylogenetic diversity over half a
        # sample is a different reading from one over all of it, and this is
        # what lets a reader tell them apart.
        function basis(name,   total) {
            total = depth[name] + 0

            if (!(name in placed) || placed[name] == "NA" || total <= 0) return "NA"

            return sprintf("%.2f", placed[name] * 100 / total)
        }

        {
            name = $1

            printf "%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                name, depth[name] + 0, \
                reading(diversity[name]), reading(coverage[name]), \
                reading(redundancy[name]), reading(fit[name]), reading(spent[name]), \
                reading(needed[name]), reading(motus[name]), \
                reading(faith[name]), basis(name), \
                reading(faith_sgb[name]), reading(sgb_pct[name])
        }
    ' "$PROFILE_SET"
}

# Whether the table carries a reading for at least one sample in one of its
# columns, which is what decides whether the chart offers it
alpha_has_column() {
    LC_ALL=C awk -F'\t' -v want="$1" '
        NR == 1 {
            for (i = 1; i <= NF; i++) if ($i == want) column = i
            next
        }

        column && $column ~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/ {
            found = 1
            exit
        }

        END { exit !found }
    ' "$ALPHA_TABLE"
}

# What the Overview offers on its diversity chart, and how to write each
# reading. Only this script knows which of them the run produced, so it names
# them rather than the page assuming a set. The first is the one the chart opens
# on, and the one the samples can be sorted by.
#
# Estimated coverage leads them. It is the reading that says whether the rest of
# this run is worth reading at all - a sample the reads only reached a third of
# has a diversity and a cluster count that describe the sequencing rather than
# the community - and it is the one a requester asks about first.
#
# Each names the tool it came from, which the page prints under the chart. The
# readings come off two tools that answer different questions, and a reader
# comparing two of them is owed which is which. Each column is offered on its
# own rather than on the table's, since a run can produce one of a tool's
# readings and not another.
#
# Two of them carry their axis with them. A coverage is a share of a whole, so
# its scale tops out at 100 rather than at the best sample in the run. A read
# depth is a count, and a run holding a sample that failed beside one sequenced
# a hundred times as deep draws every column but the deepest as a hairline, so
# it is plotted on a square root.
#
# Fails for a run that measured no diversity at all, which leaves the page to
# hide that half rather than draw a chart of read depth and call it diversity.
composition_metrics() {
    local -a metrics=()

    if alpha_has_column coverage_pct; then
        metrics+=('{"key":"coverage","title":"Estimated coverage","note":"how much of the community the reads reached","places":1,"unit":"%","max":100,"source":"Nonpareil"}')
    fi

    if alpha_has_column nonpareil_diversity; then
        metrics+=('{"key":"diversity","title":"Nonpareil diversity","note":"how varied the community is, read off how often the same sequence recurs rather than off a database","places":2,"source":"Nonpareil"}')
    fi

    if alpha_has_column observed_motus; then
        metrics+=('{"key":"motus","title":"Observed mOTUs","note":"species-level clusters found in universal marker genes","integer":true,"source":"mOTUs"}')
    fi

    if alpha_has_column effort_95_gbp; then
        metrics+=('{"key":"effort95","title":"Effort for 95% coverage","note":"the sequencing this sample would take to reach 95% coverage","places":1,"unit":" Gbp","source":"Nonpareil"}')
    fi

    # The two that do read a classification database, so they come after the
    # three that do not. Each describes only the classified part of the sample;
    # alpha_diversity.tsv carries the share it was computed over beside it.
    if alpha_has_column faith_pd_sgb; then
        metrics+=('{"key":"faithsgb","title":"Faith'"'"'s PD (phylogeny)","note":"branch length of the published species phylogeny this sample covers, over the species MetaPhlAn detected","places":2,"source":"MetaPhlAn"}')
    fi

    if alpha_has_column faith_pd; then
        metrics+=('{"key":"faith","title":"Faith'"'"'s PD (taxonomy)","note":"branch length of the NCBI taxonomy this sample covers, over the reads that were classified - a taxonomic diversity rather than an evolutionary one","places":2,"source":"'"$PROFILE_TOOL"'"}')
    fi

    (( ${#metrics[@]} > 0 )) || return 1

    metrics+=('{"key":"reads","title":"Read depth","note":"reads that reached the classifier","integer":true,"scale":"sqrt","source":"the Kraken2 reports"}')

    local IFS=,
    printf '%s' "${metrics[*]}"
}

# The same table as the arrays the plots read, plus the sample names every other
# array is ordered by
alpha_json() {
    LC_ALL=C awk -F'\t' '
        function json_string(s) {
            gsub(/\\/, "\\\\", s)
            gsub(/"/, "\\\"", s)
            return "\"" s "\""
        }

        # A reading nothing produced is emitted as null rather than as a zero: a
        # sample nonpareil could not fit a model for has no diversity to report,
        # which is not the same as no diversity
        function number(v) {
            return v ~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/ \
                ? v + 0 : "null"
        }

        function series(name, column,   i, out) {
            out = "\"" name "\":["

            for (i = 1; i <= n; i++) out = out (i > 1 ? "," : "") value[i, column]

            return out "]"
        }

        FNR == 1 { next }

        {
            n++
            name[n] = $1
            for (i = 2; i <= NF; i++) value[n, i] = number($i)
        }

        END {
            out = "\"samples\":["

            for (i = 1; i <= n; i++) out = out (i > 1 ? "," : "") json_string(name[i])

            printf "%s],%s,\"alpha\":{%s,%s,%s,%s,%s,%s}", out, series("reads", 2), \
                series("diversity", 3), series("coverage", 4), \
                series("effort95", 8), series("motus", 9), \
                series("faith", 10), series("faithsgb", 12)
        }
    ' "$ALPHA_TABLE"
}

# Every taxonomic rank as the array of objects the page stacks its bars from.
#
# Two passes over the reports, which is why they are given twice, and every rank
# is worked out in both of them: a WGS report is megabytes per sample, so it is
# read twice rather than twice per rank. The first pass sums each taxon across
# every sample, which is what decides the eleven of its rank that are drawn; the
# second emits only those eleven, in the canonical sample order, with everything
# else left to "Other". Only twelve rows of sample-wide data are ever held per
# rank, so the number of taxa a rank carries does not matter.
#
# A report is indented two spaces per step down the taxonomy, and that is the
# only record of what sits above a taxon - so the ancestors are carried in a
# stack as the file is read, and the major ranks among them become the line under
# the name in the legend. A taxon is keyed by that lineage as well as by its
# name, so two genera of the same name in different families stay apart.
#
# Shares are emitted as ten-thousandths, and "Other" is what is left of ten
# thousand rather than a sum of its own - so a stack always closes exactly.
levels_json() {
    local -a reports=("$@")

    LC_ALL=C awk -F'\t' -v codes="${RANK_CODES[*]}" -v numbers="${RANK_NUMBERS[*]}" \
            -v names="${RANK_NAMES[*]}" -v top="$TOP_TAXA" -v nfiles="$#" '
        function json_string(s) {
            gsub(/\\/, "\\\\", s)
            gsub(/"/, "\\\"", s)
            return "\"" s "\""
        }

        function trim(s) {
            sub(/^ +/, "", s)
            return s
        }

        # What sits above a taxon, at the ranks a reader reads a lineage at
        function ancestry(depth,   i, out) {
            out = ""

            for (i = 0; i < depth; i++) {
                if (code[i] !~ /^[DKPCOFG]$/ && !(id[i] in DOMAIN)) continue

                out = out (out == "" ? "" : " > ") path[i]
            }

            return out
        }

        # Mean share of a sample, in ten-thousandths
        function mean(rank, key) {
            return int(total[rank, key] / samples * 10000 + 0.5)
        }

        # The head of the taxa of one rank, ranked by that mean and kept by
        # insertion so the tail is never sorted. Ties go to the key that sorts
        # first, or the page would come out differently on two runs of the same data.
        #
        # The unclassified share never competes for one of the places. The page
        # does not draw it, so a rank where it ranked high - which on a shotgun
        # run is every rank - came out a taxon short. It is appended after them
        # instead, which keeps it out of the colours and still leaves "Other" as
        # what is left once it is counted.
        function choose(rank,   combined, part, key, place) {
            for (combined in total) {
                split(combined, part, SUBSEP)

                if (part[1] != rank) continue

                key = part[2]

                if (key == UNCLASSIFIED) continue

                place = drawn[rank] < top ? drawn[rank] + 1 : top + 1

                while (place > 1 && \
                       (total[rank, taxon[rank, place - 1]] < total[rank, key] || \
                        (total[rank, taxon[rank, place - 1]] == total[rank, key] && \
                         taxon[rank, place - 1] > key))) {
                    taxon[rank, place] = taxon[rank, place - 1]
                    place--
                }

                if (place > top) continue

                taxon[rank, place] = key
                if (drawn[rank] < top) drawn[rank]++
            }

            if ((rank, UNCLASSIFIED) in total) {
                taxon[rank, ++drawn[rank]] = UNCLASSIFIED
            }

            for (place = 1; place <= drawn[rank]; place++)
                chosen[rank, taxon[rank, place]] = place
        }

        # The reads no taxon was found for, entered at every rank as a taxon of
        # its own once each sample has been totalled, and then drawn like any
        # other. On a shotgun run they are often the largest share of the sample,
        # so a stack that left them out would say the opposite of what it means.
        function rank_unclassified(   r, rank, name, place, share) {
            for (r = 1; r <= ranks; r++) {
                rank = code_of[r]

                for (name in position) {
                    if (depth[name] > 0 && missed[name] > 0)
                        total[rank, UNCLASSIFIED] += missed[name] / depth[name]
                }

                choose(rank)

                place = chosen[rank, UNCLASSIFIED]
                if (!place) continue

                for (name in position) {
                    if (depth[name] <= 0) continue

                    share = int(missed[name] / depth[name] * 10000 + 0.5)

                    value[rank, place, position[name]] = share
                    if (share > 0) present[rank, place]++
                }
            }
        }

        BEGIN {
            ranks = split(codes, code_of, " ")
            split(numbers, number_of, " ")
            split(names, name_of, " ")

            for (i = 1; i <= ranks; i++) plotted[code_of[i]] = 1

            # The top of a taxonomy, which a kraken2 database codes as a rank of
            # its own rather than as one of the ranks a lineage is read at
            split("2 2157 2759 10239 12884", domains, " ")
            for (i in domains) DOMAIN[domains[i]] = 1

            UNCLASSIFIED = "\tUnclassified"

            while ((getline line < ENVIRON["READ_TOTALS"]) > 0) {
                split(line, field, "\t")
                depth[field[1]] = field[2] + field[3]
                missed[field[1]] = field[2] + 0
            }

            while ((getline line < ENVIRON["PROFILE_SET"]) > 0) {
                split(line, field, "\t")
                position[field[1]] = ++samples
                sample[field[2]] = field[1]
            }
        }

        FNR == 1 {
            if (++seen == nfiles + 1) rank_unclassified()

            name = sample[FILENAME]
            column = position[name]

            delete path
            delete code
            delete id
        }

        {
            label = $NF
            here = int((length(label) - length(trim(label))) / 2)
            label = trim(label)

            rank = $(NF - 2)

            path[here] = label
            code[here] = rank
            id[here] = $(NF - 1)

            if (!(rank in plotted) || depth[name] <= 0) next

            key = ancestry(here) "\t" label

            if (seen <= nfiles) {
                total[rank, key] += $2 / depth[name]
                next
            }

            place = chosen[rank, key]
            if (!place) next

            share = int($2 / depth[name] * 10000 + 0.5)

            value[rank, place, column] = share
            if (share > 0) present[rank, place]++
        }

        END {
            for (r = 1; r <= ranks; r++) {
                rank = code_of[r]

                printf "%s{\"rank\":%d,\"name\":%s,\"taxa\":[", (r > 1 ? "," : ""), \
                    number_of[r], json_string(name_of[r])

                for (t = 1; t <= drawn[rank]; t++) {
                    key = taxon[rank, t]
                    split(key, field, "\t")

                    printf "%s{\"label\":%s,\"lineage\":%s,\"mean\":%d,\"prevalence\":%d}", \
                        (t > 1 ? "," : ""), json_string(field[2]), json_string(field[1]), \
                        mean(rank, key), int((present[rank, t] + 0) / samples * 100 + 0.5)
                }

                rest = 10000
                for (t = 1; t <= drawn[rank]; t++) rest -= mean(rank, taxon[rank, t])

                printf "%s{\"label\":\"Other\",\"lineage\":\"\",\"mean\":%d,\"prevalence\":0}],", \
                    (drawn[rank] > 0 ? "," : ""), (rest > 0 ? rest : 0)

                printf "\"values\":["

                for (t = 1; t <= drawn[rank]; t++) {
                    printf "%s[", (t > 1 ? "," : "")
                    for (s = 1; s <= samples; s++)
                        printf "%s%d", (s > 1 ? "," : ""), value[rank, t, s] + 0
                    printf "]"
                }

                printf "%s[", (drawn[rank] > 0 ? "," : "")

                for (s = 1; s <= samples; s++) {
                    rest = 10000
                    for (t = 1; t <= drawn[rank]; t++) rest -= value[rank, t, s] + 0
                    printf "%s%d", (s > 1 ? "," : ""), (rest > 0 ? rest : 0)
                }

                printf "]]}"
            }
        }
    ' "${reports[@]}" "${reports[@]}"
}

# Reads the classifier placed inside some clade of one rank, summed over the run.
# Read off the kraken2 reports whichever set is plotted: bracken pushes every
# read it can down to a species, so its report says nothing about how far the
# classifier itself got.
rank_resolved_reads() {
    local rank="$1"
    shift

    LC_ALL=C awk -F'\t' -v rank="$rank" '
        $(NF - 2) == rank { total += $2 }
        END { print total + 0 }
    ' "$@"
}

# Read depth across the samples, off the totals the kraken2 reports were counted
# for - so what is reported is what the classifier was actually given.
#
# The middle sample rather than the mean: one deeply sequenced sample drags an
# average away from what the run's samples actually look like.
read_depth_stats() {
    LC_ALL=C awk -F'\t' '
        {
            reads = $2 + $3
            sum += reads
            classified += $3 + 0
            depth[++n] = reads
        }

        END {
            if (n) {
                asort(depth)
                median = n % 2 ? depth[(n + 1) / 2] \
                               : (depth[n / 2] + depth[n / 2 + 1]) / 2
            }

            printf "reads_total\t%d\nreads_classified\t%d\n", sum + 0, classified + 0
            printf "reads_median\t%d\nreads_min\t%d\nreads_max\t%d\n", \
                median + 0.5, depth[1] + 0, depth[n] + 0
        }
    ' "$READ_TOTALS"
}

# How the composition numbers were made, as the caption under the chart drawn
# from them. Which classifier and which database produced a bar is a run's own,
# and a reader is owed it beside the bar rather than three pages away. That the
# unclassified reads are left out of the chart is not said here: it is true of
# both pipelines, so the page says it once, above this line.
composition_method() {
    local database

    database=$(reports_database "$KRAKEN2_SET")

    printf 'Reads were classified with Kraken2 against the %s database' "$database"

    if [[ "$PROFILE_TOOL" == "Bracken" ]]; then
        printf ', then re-estimated at every rank by Bracken'
    else
        printf ", and each bar is that report's own clade counts"
    fi

    printf '.'
}

# The run's headline numbers, keyed for the dashboard's sidebar. Each is left out
# rather than guessed at when the reports behind it are missing.
write_run_statistics() {
    local -a kraken2=()

    mapfile -t kraken2 < <(cut -f2 "$KRAKEN2_SET")

    {
        printf 'profiler\t%s\n' "$PROFILE_TOOL"
        printf 'database\t%s\n' "$PROFILE_DB"
        printf 'samples\t%s\n'  "$(wc -l < "$PROFILE_SET")"
        printf 'platform\t%s\n' "$(sequencing_summary)"

        read_depth_stats

        if (( ${#FASTP_REPORTS[@]} > 0 )); then
            fastp_totals "${FASTP_REPORTS[@]}"
        fi

        printf 'phylum_reads\t%s\n'  "$(rank_resolved_reads P "${kraken2[@]}")"
        printf 'genus_reads\t%s\n'   "$(rank_resolved_reads G "${kraken2[@]}")"
        printf 'species_reads\t%s\n' "$(rank_resolved_reads S "${kraken2[@]}")"

        if [[ -s "$HOST_TABLE" ]]; then
            LC_ALL=C awk -F'\t' '
                { total += $2; removed += $3 }
                END { printf "host_total\t%d\nhost_removed\t%d\n", total, removed }
            ' "$HOST_TABLE"
        fi
    } | state_set_tsv "$STATS_KEY"
}

log "Summarising composition and diversity under $RESULTS_DIR..."

# 1. The reports the run published, and which of them the plots are drawn from.
#    Bracken's are preferred; kraken2's are read either way, for the reads no
#    taxon was found for.
if ! collect_reports "$KRAKEN2_DIR" "$KRAKEN2_SUFFIX" "$KRAKEN2_SET"; then
    log "No kraken2 reports under $KRAKEN2_DIR; the Overview will show no plots."
    exit 0
fi

if collect_reports "$BRACKEN_DIR" "$BRACKEN_SUFFIX" "$PROFILE_SET"; then
    PROFILE_TOOL="Bracken"
    PROFILE_DB=$(reports_database "$PROFILE_SET")

    # taxprofiler names a bracken database after the kraken2 one it was built
    # from, which the tool beside it already says
    PROFILE_DB=${PROFILE_DB%_bracken}
else
    cp "$KRAKEN2_SET" "$PROFILE_SET"

    PROFILE_TOOL="Kraken2"
    PROFILE_DB=$(reports_database "$PROFILE_SET")

    log "No bracken reports under $BRACKEN_DIR; plotting kraken2's own counts."
fi

mapfile -t PROFILES < <(cut -f2 "$PROFILE_SET")
mapfile -t KRAKEN2_REPORTS < <(cut -f2 "$KRAKEN2_SET")

read_totals "${KRAKEN2_REPORTS[@]}" > "$READ_TOTALS"
host_removal > "$HOST_TABLE"

# What quality filtering wrote about itself, on a run that filtered short reads
declare -a FASTP_REPORTS=()
mapfile -t FASTP_REPORTS < <(fastp_reports)

# 2. Diversity, as nonpareil and mOTUs measured it, in the sample order the
#    plotted reports set. Neither is required: a run that produced neither still
#    gets its composition plotted and its read depths reported.
if ! nonpareil_table > "$NONPAREIL_TABLE"; then
    warn "The nonpareil summary could not be read; coverage and Nd will be missing."
    : > "$NONPAREIL_TABLE"
elif [[ ! -s "$NONPAREIL_TABLE" ]]; then
    log "No nonpareil summary under $NONPAREIL_DIR; coverage and Nd will be missing."
fi

: > "$MOTUS_TABLE"

if collect_reports "$MOTUS_DIR" "$MOTUS_SUFFIX" "$MOTUS_SET"; then
    mapfile -t MOTUS_REPORTS < <(cut -f2 "$MOTUS_SET")

    if ! motus_table "${MOTUS_REPORTS[@]}" > "$MOTUS_TABLE"; then
        warn "The mOTUs profiles could not be counted; the cluster counts will be missing."
        : > "$MOTUS_TABLE"
    fi
else
    log "No mOTUs profiles under $MOTUS_DIR; the cluster counts will be missing."
fi

# 3. The feature tables, and the phylogenetic diversity read off their trees.
#    Ahead of the diversity table, whose last four columns come back from them.
: > "$FAITH_TABLE"

build_feature_tables \
    || log "No feature table was built; the diversity table keeps its other columns."

[[ -s "$FAITH_TABLE" ]] || log "This run measured no phylogenetic diversity."

if ! write_alpha_table > "$ALPHA_TABLE"; then
    warn "The diversity table could not be built; the Overview will show no plots."
    rm -f "$ALPHA_TABLE"
    exit 0
fi

DATA=$(alpha_json)

# Which readings the run actually produced, and how the page writes each of
# them. A run that measured none leaves the key off, which is what hides that
# half of the panel.
if METRICS=$(composition_metrics); then
    DATA="\"metrics\":[$METRICS],$DATA"
else
    log "This run measured no diversity; the Overview will plot composition only."
fi

# What the reader is being shown a count of, so the page says species where the
# 16S page says ASV
DATA="\"feature\":{\"one\":\"species\",\"many\":\"species\",\"depth\":\"reads that reached the classifier\"},$DATA"

# How those numbers were made, for the caption under the composition chart. jq
# encodes it, since it is a sentence being written into JSON.
DATA="\"method\":$(composition_method | jq -R -s .),$DATA"

# 4. Composition, every rank in the order a reader reads them
LEVELS=""

if ! LEVELS=$(levels_json "${PROFILES[@]}"); then
    warn "The abundance counts could not be summarised; composition is left unplotted."
    LEVELS=""
fi

DATA+=",\"levels\":[$LEVELS]"

# 5. The run's headline numbers: the same reports, and the ones each step of the
#    run wrote about its own reads
if ! write_run_statistics; then
    warn "The run statistics could not be counted; the dashboard will show fewer numbers."
    state_unset "$STATS_KEY" || true
fi

if ! printf '{%s}\n' "$DATA" > "$PLOT_DATA"; then
    rm -f "$PLOT_DATA"
    fail "The composition and diversity data could not be written."
fi

log "Wrote $PLOT_DATA for $(wc -l < "$PROFILE_SET") samples."
