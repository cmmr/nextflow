#!/bin/bash
#
# ampliseq_composition.sh - Work out what a run found, for the dashboard to plot.
#
# Author: Daniel Smith
# Date:   August 27th, 2026
#
# What a requester wants out of a 16S run is usually two things: what was in each
# sample, and how varied each sample was. ampliseq answers neither in a form
# worth showing a client. Its barplot is a QIIME 2 visualisation - a page in
# QIIME's own dress, drawn with one SVG rectangle per sample per taxon, which a
# run of a few thousand samples will not render. Alpha diversity it does not
# compute at all unless the run was given a sample metadata sheet, which these
# runs are not; see docs/results/composition.md.
#
# So both are worked out here, from two tables the pipeline does produce:
#
#   qiime2/rel_abundance_tables/rel-table-<rank>.tsv   composition per rank
#   qiime2/abundance_tables/feature-table.tsv          ASV counts, for diversity
#
# and left in ./composition_data.json, which publish_dashboard.sh writes into the
# Overview page for its two plots to draw. Only the eleven most abundant taxa of
# each rank are kept, the rest summed into "Other": past that fills no reader can
# tell one colour from the next, and the full tables are published for anyone who
# needs every row.
#
# A run publishes agglomerated tables only for the ranks tax_agglom_min..
# tax_agglom_max covered, which stops at genus by default. Species is read out of
# QIIME 2's barplot instead, which carries every rank the taxonomy names.
#
# Diversity is reported per sample as observed ASVs, Shannon, Simpson and
# Pielou's evenness, computed on the unrarefied counts. Nothing is rarefied
# because nothing is being compared between groups - these runs have no metadata
# to group by - and the read depth each index was computed at is published in the
# same table for the reader to judge them against.
#
# Either half is skipped when the table behind it was not produced, and nothing
# is written at all if neither was - which is what leaves the Overview's panel on
# its empty state for a run with nothing to plot.
#
# The same tables answer what the Overview's sidebar reports, so the run's
# headline numbers - samples, ASVs, reads in and reads kept, and how deep the
# classifier got - are counted here as well and recorded under "statistics" in
# ./run_state.json for ampliseq_upload.sh to read.
#
# Usage:     ampliseq_composition.sh [results_dir]
#            defaults to ./results, the outdir set in the ampliseq params file
# Called by: ampliseq_upload.sh, before it indexes and uploads the results
# Requires:  GNU awk
# Outputs:   <results_dir>/alpha_diversity.tsv
#            ./composition_data.json
#            the "statistics" of ./run_state.json
# Env:       NEXTFLOW_DIR, the log/warn/fail helpers and the run state helpers,
#            sourced from .env

set -euo pipefail

source /data/prod/nextflow/.env

RESULTS_DIR="${1:-results}"
RESULTS_DIR="${RESULTS_DIR%/}"

# The ASV counts every diversity index here is computed from
readonly FEATURE_TABLE="$RESULTS_DIR/qiime2/abundance_tables/feature-table.tsv"

# One table per taxonomic rank, of which a run publishes whichever ranks
# tax_agglom_min..tax_agglom_max covered
readonly REL_TABLE_DIR="$RESULTS_DIR/qiime2/rel_abundance_tables"

# QIIME 2's barplot data, one level-<n>.csv per rank the taxonomy carries, as
# counts per sample. It reaches the ranks the tables above stop short of.
readonly BARPLOT_DIR="$RESULTS_DIR/qiime2/barplot"

# One row per ASV with a column per rank, which is what the classification
# counts are read off. Named for the database the run used, so it is matched
# rather than spelled out.
readonly TAXONOMY_DIR="$RESULTS_DIR/dada2"

readonly ALPHA_TABLE="$RESULTS_DIR/alpha_diversity.tsv"

# What the Overview's two plots are drawn from, in the run directory rather than
# in the results: it is that page's own data, and every number in it comes from
# a table that is published
readonly PLOT_DATA="composition_data.json"

# Reads surviving each stage of the pipeline, one row per sample, which is the
# only place the reads that went in are counted
readonly OVERALL_SUMMARY="$RESULTS_DIR/overall_summary.tsv"

# Where the run's headline numbers go, in the run's state file rather than in
# the results: they are the dashboard's sidebar, not an output of the analysis
readonly STATS_KEY="statistics"

# How many taxa of each rank are drawn in their own colour before the tail is
# summed into "Other". Eleven is what the palette carries, and a rank's list is
# usually seven or eight named taxa plus the unclassified and unassigned shares.
readonly TOP_TAXA=11

# The rank each rank-<n> table is agglomerated to, indexed by that number
RANK_NAMES=(Domain Phylum Class Order Family Genus Species)

if [[ ! -d "$RESULTS_DIR" ]]; then
    fail "There is no '$RESULTS_DIR' directory to summarise."
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Every sample of the run, in the order the ASV table names them. This is the
# order everything below is built in: the composition of a sample and its
# diversity have to line up column for column, and only one of the two tables
# can decide that.
readonly SAMPLE_ORDER="$WORK/samples.txt"

# Per-sample diversity, as the table published with the results. Read depth is
# part of it: an index computed on 50 reads is not the same measurement as one
# computed on 50,000, and a reader can only see that if the depth is there.
#
# No Chao1. It estimates the unseen species from the ones seen exactly once and
# twice, and DADA2 has already dropped most of the singletons - so on an ASV
# table it is not a richness a reader should act on.
#
# Two passes over the counts. The first totals each sample, which the second
# needs to turn counts into the proportions Shannon and Simpson are computed
# from.
write_alpha_table() {
    LC_ALL=C awk -F'\t' '
        # The header naming the samples, seen once per pass
        /^#OTU ID/ {
            for (i = 2; i <= NF; i++) sample[i] = $i
            columns = NF
            next
        }

        # Anything else opening with # is the comment biom writes above it
        /^#/ { next }

        NR == FNR {
            for (i = 2; i <= columns; i++) {
                count = $i + 0

                if (count <= 0) continue

                total[i] += count
                observed[i]++
            }
            next
        }

        {
            for (i = 2; i <= columns; i++) {
                count = $i + 0

                if (count <= 0 || total[i] <= 0) continue

                p = count / total[i]
                shannon[i] -= p * log(p)
                concentration[i] += p * p
            }
        }

        END {
            print "sample\treads\tobserved_asvs\tshannon\tsimpson\tevenness"

            for (i = 2; i <= columns; i++) {
                reads = total[i] + 0
                species = observed[i] + 0

                # Pielou divides by the diversity of a sample in which every ASV
                # is equally common, which is undefined for a sample holding one
                evenness = species > 1 ? shannon[i] / log(species) : 0

                # A sample with no reads has no composition to describe, rather
                # than a perfectly even one
                simpson = reads > 0 ? 1 - concentration[i] : 0

                printf "%s\t%d\t%d\t%.4f\t%.4f\t%.4f\n", \
                    sample[i], reads, species, shannon[i] + 0, simpson, evenness
            }
        }
    ' "$FEATURE_TABLE" "$FEATURE_TABLE"
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

        function series(name, column,   i, out) {
            out = "\"" name "\":["

            for (i = 1; i <= n; i++) out = out (i > 1 ? "," : "") value[i, column]

            return out "]"
        }

        FNR == 1 { next }

        {
            n++
            name[n] = $1
            for (i = 2; i <= NF; i++) value[n, i] = $i + 0
        }

        END {
            out = "\"samples\":["

            for (i = 1; i <= n; i++) out = out (i > 1 ? "," : "") json_string(name[i])

            printf "%s],%s,\"alpha\":{%s,%s,%s,%s}", out, series("reads", 2), \
                series("observed", 3), series("shannon", 4), series("simpson", 5), \
                series("evenness", 6)
        }
    ' "$ALPHA_TABLE"
}

# One taxonomic rank as the object the page stacks its bars from.
#
# Two passes again. The first sums each taxon across every sample, which is what
# decides the eight that are drawn; the second emits only those eight, in the
# canonical sample order, with everything else left to "Other". Only nine rows
# of sample-wide data are ever held, so the width of the table does not matter.
#
# Shares are emitted as ten-thousandths, and "Other" is what is left of ten
# thousand rather than a sum of its own - so a stack always closes exactly.
level_json() {
    local file="$1" rank="$2" rank_name="$3"

    LC_ALL=C awk -F'\t' -v rank="$rank" -v rank_name="$rank_name" \
            -v orderfile="$SAMPLE_ORDER" -v top="$TOP_TAXA" '
        # The deepest rank the classifier named, and whether it got that far.
        # "Bacteria;;;" is a sequence placed in a domain and nowhere below it.
        # A species is named by its epithet alone, which only reads as a species
        # beside the genus above it.
        function label(taxon,   parts, count, i, name) {
            count = split(taxon, parts, ";")

            for (i = count; i >= 1; i--) {
                if (parts[i] == "") continue

                name = (i == SPECIES && parts[GENUS] != "") \
                     ? parts[GENUS] " " parts[i] : parts[i]

                return i == count ? name : "Unclassified " name
            }

            return "Unassigned"
        }

        # What sits above that rank, for the line under the name in the legend.
        # The rank the label already names is left off, and so are the empty
        # ones a partial classification trails behind it.
        function lineage(taxon,   parts, count, i, deepest, out) {
            count = split(taxon, parts, ";")
            deepest = 0

            for (i = count; i >= 1; i--) {
                if (parts[i] == "") continue
                deepest = i
                break
            }

            # The genus belongs to the species name rather than the path above it
            if (deepest == SPECIES && parts[GENUS] != "") deepest = GENUS

            out = ""

            for (i = 1; i < deepest; i++) {
                if (parts[i] == "") continue
                out = out (out == "" ? "" : " > ") parts[i]
            }

            return out
        }

        function json_string(s) {
            gsub(/\\/, "\\\\", s)
            gsub(/"/, "\\\"", s)
            return "\"" s "\""
        }

        # Mean share of a sample, in ten-thousandths
        function mean(name) {
            return int(total[name] / samples * 10000 + 0.5)
        }

        # The head of the taxa ranked by that mean, kept by insertion so the
        # tail never has to be sorted. Ties go to the name that sorts first, or
        # the page would come out differently on two runs of the same data.
        function choose(   name, place) {
            for (name in total) {
                place = drawn < top ? drawn + 1 : top + 1

                while (place > 1 && (total[taxon[place - 1]] < total[name] || \
                       (total[taxon[place - 1]] == total[name] && taxon[place - 1] > name))) {
                    taxon[place] = taxon[place - 1]
                    place--
                }

                if (place > top) continue

                taxon[place] = name
                if (drawn < top) drawn++
            }

            for (place = 1; place <= drawn; place++) chosen[taxon[place]] = place
        }

        BEGIN {
            # Where the genus and species sit in a Silva-style taxonomy string
            GENUS = 6
            SPECIES = 7

            while ((getline line < orderfile) > 0) position[line] = ++samples
        }

        /^#OTU ID/ {
            for (i = 2; i <= NF; i++) column[i] = position[$i]
            columns = NF
            next
        }

        /^#/ { next }

        NR == FNR {
            for (i = 2; i <= columns; i++) {
                if (column[i]) total[$1] += $i + 0
            }
            next
        }

        !ranked { choose(); ranked = 1 }

        $1 in chosen {
            for (i = 2; i <= columns; i++) {
                if (!column[i]) continue

                share = int(($i + 0) * 10000 + 0.5)

                value[chosen[$1], column[i]] = share
                if (share > 0) present[chosen[$1]]++
            }
        }

        END {
            printf "{\"rank\":%d,\"name\":%s,\"taxa\":[", rank, json_string(rank_name)

            for (t = 1; t <= drawn; t++) {
                printf "%s{\"label\":%s,\"lineage\":%s,\"mean\":%d,\"prevalence\":%d}", \
                    (t > 1 ? "," : ""), json_string(label(taxon[t])), \
                    json_string(lineage(taxon[t])), mean(taxon[t]), \
                    int((present[t] + 0) / samples * 100 + 0.5)
            }

            rest = 10000
            for (t = 1; t <= drawn; t++) rest -= mean(taxon[t])

            printf "%s{\"label\":\"Other\",\"lineage\":\"\",\"mean\":%d,\"prevalence\":0}],", \
                (drawn > 0 ? "," : ""), (rest > 0 ? rest : 0)

            printf "\"values\":["

            for (t = 1; t <= drawn; t++) {
                printf "%s[", (t > 1 ? "," : "")
                for (s = 1; s <= samples; s++) printf "%s%d", (s > 1 ? "," : ""), value[t, s] + 0
                printf "]"
            }

            printf "%s[", (drawn > 0 ? "," : "")

            for (s = 1; s <= samples; s++) {
                rest = 10000
                for (t = 1; t <= drawn; t++) rest -= value[t, s] + 0
                printf "%s%d", (s > 1 ? "," : ""), (rest > 0 ? rest : 0)
            }

            printf "]]}"
        }
    ' "$file" "$file"
}

# One row per ASV, under the comment lines biom writes above them
count_asvs() {
    LC_ALL=C awk -F'\t' '!/^#/ && NF > 1 { n++ } END { print n + 0 }' "$FEATURE_TABLE"
}

# Reads as they arrived, summed over every sample. Which column counts them
# depends on what the run did, so the earliest stage the summary carries is the
# one taken: chopper opens a nanopore run, cutadapt an Illumina one that trimmed
# primers, and DADA2 one that did not.
#
# cutadapt writes its counts with thousands separators, so everything that is
# not part of the number is stripped before it is read as one.
total_input_reads() {
    LC_ALL=C awk -F'\t' '
        NR == 1 {
            for (i = 1; i <= NF; i++) at[$i] = i

            split("chopper_input cutadapt_total_processed DADA2_input input_reads input",
                  want, " ")

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

        END { print total + 0 }
    ' "$OVERALL_SUMMARY"
}

# The table for one rank, in the shape level_json reads: taxa down the rows,
# samples across, each cell that sample's share of its own reads.
#
# The agglomerated table is used wherever the run published one. Past
# tax_agglom_max there is none, so the rank is converted out of the barplot's
# counts instead - the same numbers transposed and divided by each sample's
# total. Prints the path to whichever it used, and nothing when the run carries
# neither.
rank_table() {
    local rank="$1"
    local published="$REL_TABLE_DIR/rel-table-$rank.tsv"
    local barplot="$BARPLOT_DIR/level-$rank.csv"
    local converted="$WORK/rel-table-$rank.tsv"

    if [[ -r "$published" ]]; then
        printf '%s' "$published"
        return 0
    fi

    [[ -r "$barplot" ]] || return 1

    LC_ALL=C awk -F',' '
        NR == 1 {
            for (i = 2; i <= NF; i++) taxon[i] = $i
            columns = NF
            next
        }

        {
            sample[++n] = $1

            for (i = 2; i <= columns; i++) {
                count[i, n] = $i + 0
                total[n] += $i + 0
            }
        }

        END {
            printf "# Converted from the barplot\n#OTU ID"

            for (s = 1; s <= n; s++) printf "\t%s", sample[s]

            printf "\n"

            for (i = 2; i <= columns; i++) {
                printf "%s", taxon[i]

                for (s = 1; s <= n; s++) {
                    printf "\t%.17g", (total[s] > 0 ? count[i, s] / total[s] : 0)
                }

                printf "\n"
            }
        }
    ' "$barplot" > "$converted" || return 1

    printf '%s' "$converted"
}

# The per-ASV taxonomy the classification counts are read off, named for the
# database the run classified against. addSpecies writes the longer table; the
# shorter one is what a run that skipped it leaves.
asv_taxonomy_table() {
    local path

    for path in "$TAXONOMY_DIR"/ASV_tax_species.*.tsv "$TAXONOMY_DIR"/ASV_tax.*.tsv; do
        [[ -r "$path" ]] || continue

        printf '%s' "$path"
        return 0
    done

    return 1
}

# How many of the run's ASVs the classifier named at one rank, which is what
# ampliseq's own report counts. Taken over the ASVs the filtered table kept
# rather than everything DADA2 called, so the count is a share of the ASV total
# reported beside it. A sequence the classifier could not take that deep carries
# an empty field, or a bare rank prefix, where the name would be.
rank_classified_asvs() {
    local taxonomy="$1" rank="$2"

    LC_ALL=C awk -F'\t' -v rank="$rank" '
        # The ASVs that survived filtering, under the comments biom writes
        NR == FNR {
            if ($0 !~ /^#/ && NF > 1) kept[$1] = 1
            next
        }

        FNR == 1 { next }

        {
            id = $1
            gsub(/"/, "", id)

            if (!(id in kept)) next

            # ASV_ID opens the row, so a rank sits one column further along
            name = $(rank + 1)
            gsub(/"/, "", name)

            if (name != "" && name !~ /^[A-Za-z]__$/) named++
        }

        END { print named + 0 }
    ' "$FEATURE_TABLE" "$taxonomy"
}

# Read depth across the samples, off the diversity table just written - so what
# is reported as kept is what the analysis actually counted.
#
# The middle sample rather than the mean: one deeply sequenced sample drags an
# average away from what the run's samples actually look like.
read_depth_stats() {
    LC_ALL=C awk -F'\t' '
        FNR == 1 { next }

        {
            reads = $2 + 0
            sum += reads
            depth[++n] = reads
        }

        END {
            if (n) {
                asort(depth)
                median = n % 2 ? depth[(n + 1) / 2] \
                               : (depth[n / 2] + depth[n / 2 + 1]) / 2
            }

            printf "reads_retained\t%d\nreads_median\t%d\nreads_min\t%d\nreads_max\t%d\n", \
                sum + 0, median + 0.5, depth[1] + 0, depth[n] + 0
        }
    ' "$ALPHA_TABLE"
}

# The run's headline numbers, keyed for the dashboard's sidebar. Each is left
# out rather than guessed at when the table behind it is missing.
write_run_statistics() {
    local taxonomy=""

    taxonomy=$(asv_taxonomy_table) || true

    {
        printf 'samples\t%s\n' "$(wc -l < "$SAMPLE_ORDER")"
        printf 'asvs\t%s\n' "$(count_asvs)"

        read_depth_stats

        if [[ -r "$OVERALL_SUMMARY" ]]; then
            printf 'reads_total\t%s\n' "$(total_input_reads)"
        fi

        if [[ -n "$taxonomy" ]]; then
            printf 'phylum_asvs\t%s\n' "$(rank_classified_asvs "$taxonomy" 2)"
            printf 'genus_asvs\t%s\n' "$(rank_classified_asvs "$taxonomy" 6)"
            printf 'species_asvs\t%s\n' "$(rank_classified_asvs "$taxonomy" 7)"
        fi
    } | state_set_tsv "$STATS_KEY"
}

log "Summarising composition and diversity under $RESULTS_DIR..."

DATA=""

# 1. Diversity, and with it the sample order everything else follows
if [[ -r "$FEATURE_TABLE" ]]; then
    if ! write_alpha_table > "$ALPHA_TABLE"; then
        warn "The diversity indices could not be computed; the Overview will not show them."
        rm -f "$ALPHA_TABLE"
    else
        tail -n +2 "$ALPHA_TABLE" | cut -f1 > "$SAMPLE_ORDER"

        # An ASV table naming no samples is a table of nothing, and a plot
        # of nothing is worse than no plot
        if [[ -s "$SAMPLE_ORDER" ]]; then
            DATA=$(alpha_json)
        else
            warn "The ASV table names no samples; nothing will be plotted."
            rm -f "$ALPHA_TABLE"
        fi
    fi
else
    warn "No ASV table at $FEATURE_TABLE; the Overview will not show diversity."
fi

# 2. Composition, one rank at a time, in the order a reader reads them
if [[ -n "$DATA" ]]; then
    LEVELS=""

    for RANK in 2 3 4 5 6 7; do
        REL_TABLE=$(rank_table "$RANK") || continue

        if ! LEVEL=$(level_json "$REL_TABLE" "$RANK" "${RANK_NAMES[$RANK - 1]}"); then
            warn "The rank-$RANK abundance table could not be summarised; skipping it."
            continue
        fi

        LEVELS+="${LEVELS:+,}$LEVEL"
    done

    if [[ -z "$LEVELS" ]]; then
        warn "No relative abundance tables under $REL_TABLE_DIR; composition is left unplotted."
    fi

    DATA+=",\"levels\":[$LEVELS]"
fi

# 3. The same tables, counted for the dashboard's sidebar
if [[ -n "$DATA" ]]; then
    if ! write_run_statistics; then
        warn "The run statistics could not be counted; the dashboard will show fewer numbers."
        state_unset "$STATS_KEY" || true
    fi
fi

if [[ -z "$DATA" ]]; then
    log "Nothing to summarise; the Overview will show no plots."
    exit 0
fi

SAMPLE_COUNT=$(wc -l < "$SAMPLE_ORDER")

if ! printf '{%s}\n' "$DATA" > "$PLOT_DATA"; then
    rm -f "$PLOT_DATA"
    fail "The composition and diversity data could not be written."
fi

log "Wrote $PLOT_DATA for $SAMPLE_COUNT samples."
