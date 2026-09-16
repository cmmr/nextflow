#!/bin/bash
#
# biobakery_composition.sh - Work out what a biobakery run found, for the dashboard to plot.
#
# Author: Daniel Smith
# Date:   September 15th, 2026
#
# Writes the composition_data.json the Overview draws, in the shape
# taxprofiler_composition.sh writes it, from MetaPhlAn's per-sample profiles. No
# diversity is computed, so the Overview shows composition alone.
#
# MetaPhlAn runs with --unclassified_estimation, so a clade's relative abundance
# is a share of every read it processed, and what a rank's clades leave of 100%
# is that rank's unclassified share. The eleven most abundant taxa of each rank
# are kept and the rest summed into "Other".
#
# The sidebar's numbers go to the "statistics" of the state file: KneadData's
# read counts after each step, the share of reads MetaPhlAn mapped to a known
# clade, and the share HUMAnN aligned.
#
# Usage:     biobakery_composition.sh [results_dir]
#            defaults to ./results, the outdir set in the biobakery params file
# Called by: biobakery_upload.sh, before it prunes, indexes and uploads the results
# Requires:  GNU awk
# Reads:     <results_dir>/metaphlan/profiles/, <results_dir>/kneaddata/read-counts.tsv
#            and <results_dir>/humann/alignment-summary.tsv, each optional; and
#            the HUMAnN database directories the manifest in ./run_state.json
#            records
# Outputs:   ./composition_data.json, and the "statistics" of ./run_state.json
# Env:       the log/warn/fail helpers and the run state helpers, sourced from .env

set -euo pipefail

source /data/prod/nextflow/.env

RESULTS_DIR="${1:-results}"
RESULTS_DIR="${RESULTS_DIR%/}"

readonly PROFILE_DIR="$RESULTS_DIR/metaphlan/profiles"
readonly PROFILE_SUFFIX=".metaphlan_profile.txt"
readonly READ_COUNTS="$RESULTS_DIR/kneaddata/read-counts.tsv"
readonly HUMANN_SUMMARY="$RESULTS_DIR/humann/alignment-summary.tsv"

readonly PLOT_DATA="composition_data.json"
readonly STATS_KEY="statistics"

# Taxa of each rank drawn in their own colour; the palette carries eleven
readonly TOP_TAXA=11

# MetaPhlAn's clade prefixes for the ranks the Overview offers, and the numbers
# and names it knows them by
readonly RANK_CODES=(p c o f g s)
readonly RANK_NUMBERS=(2 3 4 5 6 7)
readonly RANK_NAMES=(Phylum Class Order Family Genus Species)

[[ -d "$RESULTS_DIR" ]] || fail "There is no '$RESULTS_DIR' directory to summarise."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# sample <TAB> profile, in sample order
PROFILE_SET="$WORK/profiles.tsv"

# sample <TAB> reads MetaPhlAn processed <TAB> reads it mapped to a known clade
DEPTHS="$WORK/depths.tsv"

# Every profile as "sample <TAB> path". Fails for a run that wrote none.
collect_profiles() {
    local path name

    for path in "$PROFILE_DIR"/*"$PROFILE_SUFFIX"; do
        [[ -r "$path" ]] || continue

        name=${path##*/}
        printf '%s\t%s\n' "${name%"$PROFILE_SUFFIX"}" "$path"
    done | LC_ALL=C sort -k1,1 > "$PROFILE_SET"

    [[ -s "$PROFILE_SET" ]]
}

# The reads each profile's header says MetaPhlAn processed and mapped
profile_depths() {
    local -a profiles=()

    mapfile -t profiles < <(cut -f2 "$PROFILE_SET")

    LC_ALL=C awk -F'\t' '
        NR == FNR { sample[$2] = $1; order[++n] = $1; next }

        FNR == 1 { name = sample[FILENAME] }

        /^#[0-9]+ reads processed/                  { reads[name] = substr($1, 2) + 0 }
        /^#estimated_reads_mapped_to_known_clades:/ { mapped[name] = substr($0, index($0, ":") + 1) + 0 }

        END {
            for (i = 1; i <= n; i++)
                printf "%s\t%d\t%d\n", order[i], reads[order[i]], mapped[order[i]]
        }
    ' "$PROFILE_SET" "${profiles[@]}"
}

# The sample names, and the reads each was profiled at, in sample order
samples_json() {
    LC_ALL=C awk -F'\t' '
        function json_string(s) {
            gsub(/\\/, "\\\\", s)
            gsub(/"/, "\\\"", s)
            return "\"" s "\""
        }

        {
            names = names (NR > 1 ? "," : "") json_string($1)
            reads = reads (NR > 1 ? "," : "") ($2 + 0)
        }

        END { printf "\"samples\":[%s],\"reads\":[%s]", names, reads }
    ' "$DEPTHS"
}

# Every rank as the object the Overview stacks its bars from: the eleven most
# abundant taxa by mean share, then "Unclassified", then "Other", each with one
# value per sample in ten-thousandths. A taxon is keyed by its lineage as well
# as its name.
levels_json() {
    local -a profiles=()

    mapfile -t profiles < <(cut -f2 "$PROFILE_SET")

    LC_ALL=C awk -F'\t' -v codes="${RANK_CODES[*]}" -v numbers="${RANK_NUMBERS[*]}" \
            -v names="${RANK_NAMES[*]}" -v top="$TOP_TAXA" '
        function json_string(s) {
            gsub(/\\/, "\\\\", s)
            gsub(/"/, "\\\"", s)
            return "\"" s "\""
        }

        # "s__Blautia_obeum" as "Blautia obeum"
        function readable(clade) {
            clade = substr(clade, 4)
            gsub(/_/, " ", clade)
            return clade
        }

        # Most abundant first, and ties to the key that sorts first
        function by_total(i1, v1, i2, v2) {
            if (v1 != v2) return v1 > v2 ? -1 : 1
            return i1 < i2 ? -1 : (i1 > i2 ? 1 : 0)
        }

        BEGIN {
            ranks = split(codes, code_of, " ")
            split(numbers, number_of, " ")
            split(names, name_of, " ")

            for (r = 1; r <= ranks; r++) rank_of[code_of[r]] = r
        }

        NR == FNR { position[$2] = ++samples; next }

        FNR == 1 { column = position[FILENAME]; abundance = 0 }

        /^#clade_name/ {
            for (i = 1; i <= NF; i++) if ($i == "relative_abundance") abundance = i
            next
        }

        /^#/ || !abundance { next }

        {
            depth = split($1, part, "|")
            code = substr(part[depth], 1, 1)

            if (!(code in rank_of) || substr(part[depth], 2, 2) != "__") next

            r = rank_of[code]

            lineage = ""
            for (i = 1; i < depth; i++) lineage = lineage (i > 1 ? " > " : "") readable(part[i])

            key = lineage "\t" readable(part[depth])
            share = int($abundance * 100 + 0.5)

            total[r, key] += $abundance
            value[r, key, column] = share
            named[r, column] += share
        }

        END {
            for (r = 1; r <= ranks; r++) {
                delete score
                delete sorted

                for (combined in total) {
                    split(combined, piece, SUBSEP)
                    if (piece[1] == r) score[piece[2]] = total[combined]
                }

                drawn = asorti(score, sorted, "by_total")
                if (drawn > top) drawn = top

                missed_mean = 0

                for (s = 1; s <= samples; s++) {
                    missed[s] = 10000 - named[r, s]
                    if (missed[s] < 0) missed[s] = 0
                    missed_mean += missed[s]
                }

                missed_mean = int(missed_mean / samples + 0.5)

                printf "%s{\"rank\":%d,\"name\":%s,\"taxa\":[", (r > 1 ? "," : ""), \
                    number_of[r], json_string(name_of[r])

                used = missed_mean

                for (t = 1; t <= drawn; t++) {
                    key = sorted[t]
                    split(key, field, "\t")

                    present = 0
                    for (s = 1; s <= samples; s++) if (value[r, key, s] > 0) present++

                    mean = int(total[r, key] * 100 / samples + 0.5)
                    used += mean

                    printf "{\"label\":%s,\"lineage\":%s,\"mean\":%d,\"prevalence\":%d},", \
                        json_string(field[2]), json_string(field[1]), mean, \
                        int(present / samples * 100 + 0.5)
                }

                printf "{\"label\":\"Unclassified\",\"lineage\":\"\",\"mean\":%d,\"prevalence\":0},", missed_mean
                printf "{\"label\":\"Other\",\"lineage\":\"\",\"mean\":%d,\"prevalence\":0}],", \
                    (used < 10000 ? 10000 - used : 0)

                printf "\"values\":["

                for (t = 1; t <= drawn; t++) {
                    printf "["
                    for (s = 1; s <= samples; s++) printf "%s%d", (s > 1 ? "," : ""), value[r, sorted[t], s]
                    printf "],"
                }

                printf "["
                for (s = 1; s <= samples; s++) printf "%s%d", (s > 1 ? "," : ""), missed[s]
                printf "],["

                for (s = 1; s <= samples; s++) {
                    rest = 10000 - missed[s]
                    for (t = 1; t <= drawn; t++) rest -= value[r, sorted[t], s]
                    printf "%s%d", (s > 1 ? "," : ""), (rest > 0 ? rest : 0)
                }

                printf "]]}"
            }
        }
    ' "$PROFILE_SET" "${profiles[@]}"
}

# KneadData's read counts summed over the run at each step it logged, the reads
# each sample kept, and whether the reads were paired. A step with no column -
# host depletion on a run that depleted nothing - is left out.
read_count_stats() {
    LC_ALL=C awk -F'\t' '
        NR == 1 {
            for (i = 2; i <= NF; i++) {
                stage[i] = $i
                sub(/ .*/, "", stage[i])

                if ($i ~ / pair[12]$/) paired = 1
                if ($i ~ / single$/)   single = 1
            }
            next
        }

        {
            delete here

            for (i = 2; i <= NF; i++) {
                if ($i == "NA") continue

                here[stage[i]] += $i
                sum[stage[i]] += $i
                seen[stage[i]] = 1
            }

            depth[++n] = ("final" in here) ? here["final"] : \
                         ("decontaminated" in here) ? here["decontaminated"] : here["trimmed"] + 0
        }

        END {
            if (!n) exit

            asort(depth)
            median = n % 2 ? depth[(n + 1) / 2] : (depth[n / 2] + depth[n / 2 + 1]) / 2

            printf "layout\t%s\n", paired && single ? "paired-end and single-end" : \
                                   paired ? "paired-end" : "single-end"

            if ("raw" in seen)            printf "raw_total\t%d\n", sum["raw"]
            if ("trimmed" in seen)        printf "trimmed_total\t%d\n", sum["trimmed"]
            if ("decontaminated" in seen) printf "host_kept\t%d\n", sum["decontaminated"]

            printf "retained_total\t%d\n", ("final" in seen) ? sum["final"] : \
                ("decontaminated" in seen) ? sum["decontaminated"] : sum["trimmed"]

            printf "reads_min\t%d\nreads_median\t%d\nreads_max\t%d\n", \
                depth[1], median + 0.5, depth[n]
        }
    ' "$READ_COUNTS"
}

# The reads MetaPhlAn processed over the run, and how many it mapped
metaphlan_mapping() {
    LC_ALL=C awk -F'\t' '
        { total += $2; mapped += $3 }
        END { if (total > 0) printf "metaphlan_total\t%d\nmetaphlan_mapped\t%d\n", total, mapped }
    ' "$DEPTHS"
}

# The same for HUMAnN, off its alignment summary: a sample is aligned as far as
# its translated search got, or its nucleotide search where no translated search
# ran, weighed by the reads that sample brought
humann_mapping() {
    LC_ALL=C awk -F'\t' '
        NR == FNR { depth[$1] = $2; next }

        FNR == 1 { next }

        {
            unaligned = $4 != "" ? $4 : $3

            if (unaligned == "" || !($1 in depth)) next

            total += depth[$1]
            mapped += depth[$1] * (100 - unaligned) / 100
        }

        END {
            if (total > 0)
                printf "humann_total\t%d\nhumann_mapped\t%d\n", total, mapped + 0.5
        }
    ' "$DEPTHS" "$HUMANN_SUMMARY"
}

# The HUMAnN databases this run was given, as wrike_job.sh recorded them in the
# manifest, by the versions their files are named with, e.g.
# "ChocoPhlAn v201901_v31 · UniRef90 v201901b". A database whose directory cannot
# be read is left out.
humann_databases() {
    local directory path name
    local -a names=()

    #    g__<genus>.s__<species>.centroids.<version>.ffn.gz
    directory=$(state_get manifest.params.humann_chocophlan)

    if [[ -d "$directory" ]]; then
        path=$(find -L "$directory" -maxdepth 1 -name '*.centroids.*.ffn.gz' -print -quit)

        if [[ -n "$path" ]]; then
            name=${path##*.centroids.}
            names+=("ChocoPhlAn ${name%%.*}")
        fi
    fi

    #    uniref<identity>_<version>_<subset>.dmnd
    directory=$(state_get manifest.params.humann_uniref)

    if [[ -d "$directory" ]]; then
        path=$(find -L "$directory" -maxdepth 1 -name '*.dmnd' -print -quit)
        name=${path##*/}
        name=${name%.dmnd}

        if [[ "$name" =~ ^uniref([0-9]+)_v?([^_]+) ]]; then
            names+=("UniRef${BASH_REMATCH[1]} v${BASH_REMATCH[2]}")
        elif [[ -n "$name" ]]; then
            names+=("$name")
        fi
    fi

    (( ${#names[@]} > 0 )) || return 0

    printf 'humann_database\t%s' "${names[0]}"
    (( ${#names[@]} > 1 )) && printf ' · %s' "${names[@]:1}"
    printf '\n'
}

write_run_statistics() {
    local platform

    platform=$(state_get samples.platform)
    [[ "$platform" == ILLUMINA ]] && platform="Illumina"

    {
        printf 'platform\t%s\n' "$platform"

        if [[ -s "$READ_COUNTS" ]]; then
            read_count_stats
        fi

        if [[ -s "$DEPTHS" ]]; then
            printf 'samples\t%s\n' "$(wc -l < "$DEPTHS")"
            printf 'metaphlan_database\t%s\n' "$DATABASE"
            metaphlan_mapping
        fi

        if [[ -s "$DEPTHS" && -s "$HUMANN_SUMMARY" ]]; then
            humann_mapping
            humann_databases
        fi
    } | state_set_tsv "$STATS_KEY"
}

log "Summarising composition under $RESULTS_DIR..."

DATABASE=""
: > "$DEPTHS"
rm -f "$PLOT_DATA"

if collect_profiles; then
    DATABASE=$(head -n 1 "$(head -n 1 "$PROFILE_SET" | cut -f2)")
    DATABASE=${DATABASE#\#}

    profile_depths > "$DEPTHS"
else
    log "No MetaPhlAn profiles under $PROFILE_DIR; the Overview will show no plots."
fi

if ! write_run_statistics; then
    warn "The run statistics could not be counted; the dashboard will show fewer numbers."
    state_unset "$STATS_KEY" || true
fi

[[ -s "$DEPTHS" ]] || exit 0

DATA="\"feature\":{\"one\":\"species\",\"many\":\"species\",\"depth\":\"reads MetaPhlAn processed\"}"
DATA+=",$(samples_json)"

if LEVELS=$(levels_json); then
    DATA+=",\"levels\":[$LEVELS]"
else
    warn "The MetaPhlAn profiles could not be summarised; composition is left unplotted."
fi

if ! printf '{%s}\n' "$DATA" > "$PLOT_DATA"; then
    rm -f "$PLOT_DATA"
    fail "The composition data could not be written."
fi

log "Wrote $PLOT_DATA for $(wc -l < "$DEPTHS") samples."
