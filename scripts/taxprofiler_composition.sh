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
# Both are worked out from the kraken2-style reports the run publishes:
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
# far the classifier got, since bracken renormalises over what it placed. So the
# plots stack over every read that reached the classifier - unclassified
# included, as a taxon of its own, because on a shotgun run it is often the
# largest share of the sample - and the sidebar reports the classified share
# alongside the share resolved to phylum, genus and species.
#
# Only the eleven most abundant taxa of each rank are kept, the rest summed into
# "Other": past that fill no reader can tell one colour from the next, and the
# merged taxpasta tables are published for anyone who needs every row.
#
# Diversity is reported per sample as observed species, Shannon, Simpson and
# Pielou's evenness, computed on the species-level clade counts. Nothing is
# rarefied because nothing is being compared between groups - these runs have no
# metadata to group by - and the depth each index was computed at is published in
# the same table for the reader to judge them against.
#
# Usage:     taxprofiler_composition.sh [results_dir]
#            defaults to ./results, the outdir set in the taxprofiler params file
# Called by: taxprofiler_upload.sh, before it indexes and uploads the results
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

# One folder per database, holding one report per sample
readonly BRACKEN_DIR="$RESULTS_DIR/bracken"
readonly KRAKEN2_DIR="$RESULTS_DIR/kraken2"

# Host removal's own accounting, one log per sample, for a run that depleted
# anything at all
readonly BOWTIE2_DIR="$RESULTS_DIR/bowtie2/align"

readonly ALPHA_TABLE="$RESULTS_DIR/alpha_diversity.tsv"

# What the Overview's two plots are drawn from, in the run directory rather than
# in the results: it is that page's own data, and every number in it comes from
# a report that is published
readonly PLOT_DATA="composition_data.json"

# Where the run's headline numbers go, in the run's state file rather than in
# the results: they are the dashboard's sidebar, not an output of the analysis
readonly STATS_KEY="statistics"

# How many taxa of each rank are drawn in their own colour before the tail is
# summed into "Other". Eleven is what the palette carries.
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

# Both are opened by name inside awk, by passes that are already reading the
# reports themselves
export PROFILE_SET READ_TOTALS

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

# Per-sample diversity, as the table published with the results. Read depth is
# part of it: an index computed on 50,000 reads is not the same measurement as
# one computed on 5,000,000, and a reader can only see that if the depth is
# there.
#
# The indices are computed on the species-level clade counts, the finest rank
# every one of these reports names. No Chao1: a shotgun profile's rare tail is
# the classifier's error rate as much as it is biology, and an estimator built on
# the taxa seen once and twice reads that noise as richness.
#
# Two passes over the reports, which is why they are given twice. The first
# totals each sample, which the second needs to turn counts into the proportions
# Shannon and Simpson are computed from.
write_alpha_table() {
    local -a reports=("$@")

    LC_ALL=C awk -F'\t' -v nfiles="$#" '
        BEGIN {
            # Every read that reached the classifier, which is the depth the
            # indices beside it were computed at
            while ((getline line < ENVIRON["READ_TOTALS"]) > 0) {
                split(line, field, "\t")
                depth[field[1]] = field[2] + field[3]
            }
        }

        NR == FNR { sample[$2] = $1; next }

        FNR == 1 { seen++; name = sample[FILENAME] }

        $(NF - 2) != "S" { next }

        seen <= nfiles {
            total[name] += $2
            if ($2 + 0 > 0) observed[name]++
            next
        }

        {
            if (total[name] <= 0 || $2 + 0 <= 0) next

            p = $2 / total[name]
            shannon[name] -= p * log(p)
            concentration[name] += p * p
        }

        END {
            print "sample\treads\tspecies_reads\tobserved_species\tshannon\tsimpson\tevenness"

            while ((getline line < ENVIRON["PROFILE_SET"]) > 0) {
                split(line, field, "\t")
                name = field[1]
                species = observed[name] + 0

                # Pielou divides by the diversity of a sample in which every
                # species is equally common, which is undefined for a sample
                # holding one
                evenness = species > 1 ? shannon[name] / log(species) : 0

                # A sample nothing was placed in has no composition to describe,
                # rather than a perfectly even one
                simpson = total[name] > 0 ? 1 - concentration[name] : 0

                printf "%s\t%d\t%d\t%d\t%.4f\t%.4f\t%.4f\n", name, depth[name] + 0, \
                    total[name] + 0, species, shannon[name] + 0, simpson, evenness
            }
        }
    ' "$PROFILE_SET" "${reports[@]}" "${reports[@]}"
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
                series("observed", 4), series("shannon", 5), series("simpson", 6), \
                series("evenness", 7)
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
        function choose(rank,   combined, part, key, place) {
            for (combined in total) {
                split(combined, part, SUBSEP)

                if (part[1] != rank) continue

                key = part[2]
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

# How many distinct taxa the run named at one rank, counted over the whole run
# rather than in any one sample
count_taxa() {
    local rank="$1"
    shift

    LC_ALL=C awk -F'\t' -v rank="$rank" '
        $(NF - 2) == rank && $2 + 0 > 0 { seen[$(NF - 1)] = 1 }
        END { print length(seen) }
    ' "$@"
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

# The run's headline numbers, keyed for the dashboard's sidebar. Each is left out
# rather than guessed at when the reports behind it are missing.
write_run_statistics() {
    local -a profiles=("$@")
    local -a kraken2=()

    mapfile -t kraken2 < <(cut -f2 "$KRAKEN2_SET")

    {
        printf 'profiler\t%s\n' "$PROFILE_TOOL"
        printf 'database\t%s\n' "$PROFILE_DB"
        printf 'samples\t%s\n'  "$(wc -l < "$PROFILE_SET")"

        read_depth_stats

        printf 'phylum_reads\t%s\n'  "$(rank_resolved_reads P "${kraken2[@]}")"
        printf 'genus_reads\t%s\n'   "$(rank_resolved_reads G "${kraken2[@]}")"
        printf 'species_reads\t%s\n' "$(rank_resolved_reads S "${kraken2[@]}")"

        printf 'phyla\t%s\n'   "$(count_taxa P "${profiles[@]}")"
        printf 'genera\t%s\n'  "$(count_taxa G "${profiles[@]}")"
        printf 'species\t%s\n' "$(count_taxa S "${profiles[@]}")"

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

# 2. Diversity, over the species the plotted reports name, and with it the sample
#    order everything else follows
if ! write_alpha_table "${PROFILES[@]}" > "$ALPHA_TABLE"; then
    warn "The diversity indices could not be computed; the Overview will show no plots."
    rm -f "$ALPHA_TABLE"
    exit 0
fi

DATA=$(alpha_json)

# What the reader is being shown a count of, so the page says species where the
# 16S page says ASV
DATA="\"feature\":{\"one\":\"species\",\"many\":\"species\",\"depth\":\"reads that reached the classifier\"},$DATA"

# 3. Composition, every rank in the order a reader reads them
LEVELS=""

if ! LEVELS=$(levels_json "${PROFILES[@]}"); then
    warn "The abundance counts could not be summarised; composition is left unplotted."
    LEVELS=""
fi

DATA+=",\"levels\":[$LEVELS]"

# 4. The same reports, counted for the dashboard's sidebar
if ! write_run_statistics "${PROFILES[@]}"; then
    warn "The run statistics could not be counted; the dashboard will show fewer numbers."
    state_unset "$STATS_KEY" || true
fi

if ! printf '{%s}\n' "$DATA" > "$PLOT_DATA"; then
    rm -f "$PLOT_DATA"
    fail "The composition and diversity data could not be written."
fi

log "Wrote $PLOT_DATA for $(wc -l < "$PROFILE_SET") samples."
