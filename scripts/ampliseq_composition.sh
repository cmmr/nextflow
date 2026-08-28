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
# Overview page for its two plots to draw. Only the ten most abundant taxa of
# each rank are kept, the rest summed into "Other": past ten fills no reader can
# tell one colour from the next, and the full tables are published for anyone who
# needs every row.
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
# classifier got - are counted here as well and left in ./run_statistics.tsv for
# ampliseq_upload.sh to read.
#
# Usage:     ampliseq_composition.sh [results_dir]
#            defaults to ./results, the outdir set in the ampliseq params file
# Called by: ampliseq_upload.sh, before it indexes and uploads the results
# Requires:  GNU awk
# Outputs:   <results_dir>/alpha_diversity.tsv
#            ./composition_data.json
#            ./run_statistics.tsv
# Env:       NEXTFLOW_DIR and the log/warn/fail helpers, sourced from .env

set -euo pipefail

source /data/prod/nextflow/.env

RESULTS_DIR="${1:-results}"
RESULTS_DIR="${RESULTS_DIR%/}"

# The ASV counts every diversity index here is computed from
readonly FEATURE_TABLE="$RESULTS_DIR/qiime2/abundance_tables/feature-table.tsv"

# One table per taxonomic rank, of which a run publishes whichever ranks
# tax_agglom_min..tax_agglom_max covered
readonly REL_TABLE_DIR="$RESULTS_DIR/qiime2/rel_abundance_tables"

readonly ALPHA_TABLE="$RESULTS_DIR/alpha_diversity.tsv"

# What the Overview's two plots are drawn from, in the run directory rather than
# in the results: it is that page's own data, and every number in it comes from
# a table that is published
readonly PLOT_DATA="composition_data.json"

# Reads surviving each stage of the pipeline, one row per sample, which is the
# only place the reads that went in are counted
readonly OVERALL_SUMMARY="$RESULTS_DIR/overall_summary.tsv"

# The run's headline numbers, in the run directory rather than in the results:
# they are the dashboard's sidebar, not an output of the analysis
readonly STATS_FILE="run_statistics.tsv"

# How many taxa of each rank are drawn in their own colour before the tail is
# summed into "Other". Ten is what the palette carries, and a rank's list is
# usually seven or eight named taxa plus the unclassified and unassigned shares.
readonly TOP_TAXA=10

# The rank each rel-table-<n>.tsv is agglomerated to, indexed by that number
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
        function label(taxon,   parts, count, i) {
            count = split(taxon, parts, ";")

            for (i = count; i >= 1; i--) {
                if (parts[i] == "") continue
                return i == count ? parts[i] : "Unclassified " parts[i]
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
# depends on what the run did: cutadapt reports everything it processed, and a
# run that skipped primer trimming starts at DADA2's input instead.
total_input_reads() {
    LC_ALL=C awk -F'\t' '
        NR == 1 {
            for (i = 1; i <= NF; i++) at[$i] = i

            split("cutadapt_total_processed DADA2_input input_reads input", want, " ")

            for (i = 1; i in want; i++) {
                if (want[i] in at) { pick = at[want[i]]; break }
            }
            next
        }

        pick { total += $pick + 0 }

        END { print total + 0 }
    ' "$OVERALL_SUMMARY"
}

# What share of the reads a rank's table places at that rank, as a percentage to
# one decimal - two neighbouring ranks are often within a point of each other,
# and rounding them to the same whole number reads as a mistake. A sequence the
# classifier could not take that deep carries an empty field, or a bare rank
# prefix, where the name would be.
rank_classified_pct() {
    local file="$1" rank="$2"

    LC_ALL=C awk -F'\t' -v rank="$rank" '
        function classified(taxon,   parts) {
            split(taxon, parts, ";")
            return parts[rank] != "" && parts[rank] !~ /^[A-Za-z]__$/
        }

        /^#OTU ID/ { columns = NF; next }
        /^#/ { next }

        {
            named = classified($1)

            for (i = 2; i <= columns; i++) {
                total += $i + 0
                if (named) placed += $i + 0
            }
        }

        END { printf "%.1f\n", (total > 0 ? placed / total * 100 : 0) }
    ' "$file"
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

# The run's headline numbers, as key and value, for the dashboard's sidebar.
# Each is left out rather than guessed at when the table behind it is missing.
write_run_statistics() {
    local family_table="$REL_TABLE_DIR/rel-table-5.tsv"
    local genus_table="$REL_TABLE_DIR/rel-table-6.tsv"
    local species_table="$REL_TABLE_DIR/rel-table-7.tsv"

    {
        printf 'samples\t%s\n' "$(wc -l < "$SAMPLE_ORDER")"
        printf 'asvs\t%s\n' "$(count_asvs)"

        read_depth_stats

        if [[ -r "$OVERALL_SUMMARY" ]]; then
            printf 'reads_total\t%s\n' "$(total_input_reads)"
        fi

        if [[ -r "$family_table" ]]; then
            printf 'family_pct\t%s\n' "$(rank_classified_pct "$family_table" 5)"
        fi

        if [[ -r "$genus_table" ]]; then
            printf 'genus_pct\t%s\n' "$(rank_classified_pct "$genus_table" 6)"
        fi

        if [[ -r "$species_table" ]]; then
            printf 'species_pct\t%s\n' "$(rank_classified_pct "$species_table" 7)"
        fi
    } > "$STATS_FILE"
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
        REL_TABLE="$REL_TABLE_DIR/rel-table-$RANK.tsv"

        [[ -r "$REL_TABLE" ]] || continue

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
        rm -f "$STATS_FILE"
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
