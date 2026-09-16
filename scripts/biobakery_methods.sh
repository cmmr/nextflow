#!/bin/bash
#
# biobakery_methods.sh - Write the methods text a biobakery run's Methods page shows.
#
# Author: Daniel Smith
# Date:   September 16th, 2026
#
# One paragraph for the methods section of a manuscript, saying how this run's
# taxonomic and functional profiles were made from the reads it was given: the
# steps the workflow took, the tools that took them, and the databases it read.
# Nothing before the reads arrived is described.
#
# Versions are the BioContainers images the modules pin, which the text names in
# full: KneadData, MetaPhlAn, HUMAnN and MultiQC by the version in the tag, and
# the tools inside those images - Trimmomatic, Bowtie2, DIAMOND and the rest - by
# the image that carries them.
#
# KneadData's steps are described as each sample's log recorded them, not as its
# defaults read: the Trimmomatic steps it ran, with the minimum length it set
# from each sample's read length; the Tandem Repeats Finder parameters, and the
# Bowtie2 options and pair handling. A run whose logs are gone is described by
# KneadData 0.12.4's defaults instead, without the read length.
#
# Databases are the paths the run's manifest records, described by their entry in
# config/databases.json: a release, the genomes a host reference was built from,
# a dataset DOI, and the references to cite. A path with no entry is named by its
# directory.
#
# Citations are written [@id], for ids of config/references.json. A tool named a
# second time, or a database whose citation is its tool's, is not cited again.
# publish_dashboard.sh renders them as author-year citations.
#
# Usage:     biobakery_methods.sh [results_dir]
#            defaults to ./results, the outdir set in the biobakery params file
# Called by: biobakery_upload.sh, before it prunes the KneadData logs and renders
#            the dashboard
# Requires:  jq
# Reads:     <results_dir>/kneaddata/logs/*.log, the samplesheet, the manifest
#            and statistics in ./run_state.json, config/databases.json,
#            config/references.json and modules/*.nf
# Outputs:   ./methods_data.json - {paragraphs: [...], references: {id: {...}}}
# Env:       NEXTFLOW_DIR, NEXTFLOW_DB_DIR, the log/warn/fail helpers and the run
#            state helpers, sourced from .env

set -euo pipefail

source /data/prod/nextflow/.env

RESULTS_DIR="${1:-results}"
RESULTS_DIR="${RESULTS_DIR%/}"

readonly DATABASES="$NEXTFLOW_DIR/config/databases.json"
readonly REFERENCES="$NEXTFLOW_DIR/config/references.json"
readonly METHODS_DATA="methods_data.json"

state_has manifest.params \
    || fail "This run recorded no parameters, so its methods cannot be described."

for file in "$DATABASES" "$REFERENCES"; do
    [[ -r "$file" ]] || fail "Cannot read $file."
done

# The image a module pins for a tool, e.g.
# "quay.io/biocontainers/humann:3.9--py312hdfd78af_0"; empty when none does
container_image() {
    grep -ho "container '[^']*/$1:[^']*'" "$NEXTFLOW_DIR"/modules/*.nf \
        | head -n 1 | sed "s/^container '//; s/'\$//"
}

# The tool version in that image's tag, e.g. "3.9"
tool_version() {
    local image

    image=$(container_image "$1")
    image=${image##*:}

    printf '%s' "${image%%--*}"
}

# A tool as the text names it: "HUMAnN v3.9", or "HUMAnN" with no version
named() {
    printf '%s%s' "$1" "${2:+ v$2}"
}

# Words joined as a sentence lists them: "a", "a and b", "a, b, and c"
and_list() {
    local last

    case $# in
        0) ;;
        1) printf '%s' "$1" ;;
        2) printf '%s and %s' "$1" "$2" ;;
        *) last="${!#}"
           printf '%s, ' "${@:1:$#-1}"
           printf 'and %s' "$last" ;;
    esac
}

# " [@a; @b]" for the ids given, into CITATION, marking them cited. cite_new
# leaves out the ids already cited, for a tool named again or a database whose
# citation is its tool's.
declare -A CITED=()
CITATION=""

cite() {
    local id

    CITATION=""

    for id in "$@"; do
        [[ -n "$id" ]] || continue

        CITED[$id]=1
        CITATION+="${CITATION:+; }@$id"
    done

    [[ -z "$CITATION" ]] || CITATION=" [$CITATION]"
}

cite_new() {
    local id
    local -a ids=()

    for id in "$@"; do
        [[ -n "$id" && -z "${CITED[$id]:-}" ]] && ids+=("$id")
    done

    cite ${ids[@]+"${ids[@]}"}
}

# The config/databases.json entry for a database path, as compact JSON, into
# ENTRY: the entry whose path it is, or the component it names inside one. Empty
# for a path outside NEXTFLOW_DB_DIR or one the file does not describe.
database_entry() {
    local path="${1%/}" root="${NEXTFLOW_DB_DIR%/}"

    ENTRY=""

    [[ -n "$path" && "$path" == "$root"/* ]] || return 0

    ENTRY=$(jq -c --arg path "${path#"$root"/}" '
        [.databases[] as $db
         | if $db.path == $path then $db
           elif ($path | startswith($db.path + "/"))
           then $db.components[$path[($db.path | length) + 1:]] // empty
           else empty end][0] // empty' "$DATABASES")

    [[ -n "$ENTRY" ]] \
        || warn "config/databases.json does not describe $path; the methods name it by its directory."
}

# One field of ENTRY, empty when it has none
entry_get() {
    jq -r "$1 // empty" <<< "$ENTRY"
}

# A database as the text names it, into PHRASE - "the UniRef90 database
# (v201901b)", with the dataset DOI beside the release where there is one - and
# its citations into CITATION
database_phrase() {
    local path="$1"
    local name release doi details=""
    local -a ids=()

    database_entry "$path"

    if [[ -z "$ENTRY" ]]; then
        PHRASE="the ${path##*/} database"
        CITATION=""
        return 0
    fi

    name=$(entry_get .name)
    release=$(entry_get .release)
    doi=$(entry_get .doi)
    mapfile -t ids < <(entry_get '.cite[]?')

    if [[ -n "$release" && "$name" == *"$release"* ]]; then
        name="$release"
    elif [[ -n "$release" ]]; then
        details="$release"
    fi

    [[ -n "$doi" ]] && details+="${details:+, }doi:$doi"

    PHRASE="the $name database${details:+ ($details)}"
    cite_new ${ids[@]+"${ids[@]}"}
}

# The genomes a host reference was built from, into PHRASE - "the human
# T2T-CHM13v2.0 (GCF_009914755.1) and bacteriophage phiX174 (GCF_000819615.1)
# genomes" - each followed by its own citations, and the citations of the
# reference as a whole into CITATION
host_phrase() {
    local path="$1"
    local count i label accession
    local -a ids=() parts=()

    database_entry "$path"

    if [[ -z "$ENTRY" ]]; then
        PHRASE="the ${path##*/} reference"
        CITATION=""
        return 0
    fi

    count=$(entry_get '.sources | length')

    for (( i = 0; i < count; i++ )); do
        label=$(entry_get ".sources[$i].label")
        accession=$(entry_get ".sources[$i].accession")
        mapfile -t ids < <(entry_get ".sources[$i].cite[]?")

        cite_new ${ids[@]+"${ids[@]}"}
        parts+=("$label${accession:+ ($accession)}$CITATION")
    done

    PHRASE="the $(and_list ${parts[@]+"${parts[@]}"}) genome"
    (( count > 1 )) && PHRASE+="s"

    mapfile -t ids < <(entry_get '.cite[]?')
    cite_new ${ids[@]+"${ids[@]}"}
}

# The options a run added to a tool, as a clause of the sentence naming it
extra_options() {
    [[ -z "$1" ]] || printf ', with the additional options %s' "$1"
}

# Every distinct value KneadData logged for one of its arguments, over all the
# samples, one per line
kneaddata_setting() {
    if (( ${#KNEADDATA_LOGS[@]} == 0 )); then
        printf '%s\n' "${KNEADDATA_DEFAULTS[$1]:-}"
        return 0
    fi

    sed -n "s/^$1 = //p" "${KNEADDATA_LOGS[@]}" | LC_ALL=C sort -u
}

# What KneadData 0.12.4 logs for the settings read here when nothing overrides
# them, for a run whose logs are gone
declare -A KNEADDATA_DEFAULTS=(
    [bypass_trim]=False [bypass_trf]=False [trimmomatic_options]=None
    [match]=2 [mismatch]=7 [delta]=7 [pm]=80 [pi]=10 [minscore]=50 [maxperiod]=500
    [bowtie2_options]="--very-sensitive-local --phred33" [decontaminate_pairs]=strict
)

# Each sample's Trimmomatic steps as KneadData ran them, one distinct set per
# line, with the adapter file named without its directory, e.g.
# "MINLEN:60 ILLUMINACLIP:NexteraPE-PE.fa:2:30:10:8:TRUE SLIDINGWINDOW:4:20 MINLEN:75"
trimmomatic_runs() {
    local log

    if (( ${#KNEADDATA_LOGS[@]} == 0 )); then
        if [[ "${SEQUENCER_SOURCE,,}" == none ]]; then
            printf 'SLIDINGWINDOW:4:20 MINLEN:half\n'
        else
            printf 'MINLEN:60 ILLUMINACLIP:%s-PE.fa:2:30:10%s SLIDINGWINDOW:4:20 MINLEN:half\n' \
                "$SEQUENCER_SOURCE" "$( [[ "$LAYOUT" == single-end ]] || printf ':8:TRUE')"
        fi
        return 0
    fi

    for log in ${KNEADDATA_LOGS[@]+"${KNEADDATA_LOGS[@]}"}; do
        { grep -m 1 "Execute command: .*trimmomatic" "$log" || true; } \
            | grep -oE ' [A-Z]+:[^ ]+' \
            | sed 's#^ ##; s#^ILLUMINACLIP:.*/#ILLUMINACLIP:#' \
            | paste -sd ' ' -
    done | sed '/^$/d' | LC_ALL=C sort -u
}

# What one Trimmomatic step did, given its name, every value it took over the
# samples (one per line), and whether it is the first step. A value that differed
# between samples - the final MINLEN, which KneadData sets to half of each
# sample's read length - is given as the range it took.
trimmomatic_step() {
    local name="$1" values="$2" first="$3"
    local low high value setting

    low=$(sort -n <<< "$values" | head -n 1)
    high=$(sort -n <<< "$values" | tail -n 1)
    value="$low"
    [[ "$low" == "$high" ]] || value="$low–$high"

    setting="$name:$value"
    [[ "$name" == ILLUMINACLIP ]] && setting="$name:$(paste -sd '|' - <<< "$values" | sed 's/|/ or /g')"

    case "$name" in
        MINLEN)
            if [[ "$value" == half ]]; then
                printf 'discarded reads left shorter than half of the input read length'
            elif [[ -n "$first" ]]; then
                printf 'discarded reads shorter than %s bp (%s)' "$value" "$setting"
            elif [[ "$low" != "$high" && "$DEFAULT_TRIMMING" == true ]]; then
                printf 'discarded reads left shorter than half of each sample'"'"'s read length (%s)' "$setting"
            elif [[ "$low" != "$high" ]]; then
                printf 'discarded reads left shorter than %s bp, depending on the sample (%s)' "$value" "$setting"
            elif [[ "$DEFAULT_TRIMMING" == true ]]; then
                printf 'discarded reads left shorter than %s bp, half of the input read length (%s)' "$value" "$setting"
            else
                printf 'discarded reads left shorter than %s bp (%s)' "$value" "$setting"
            fi ;;
        ILLUMINACLIP)
            printf 'clipped adapter sequences (%s)' "$setting" ;;
        SLIDINGWINDOW)
            printf 'cut each read at the first %s-base window whose mean quality fell below %s (%s)' \
                "${value%%:*}" "${value#*:}" "$setting" ;;
        LEADING)  printf 'removed leading bases of quality below %s (%s)' "$value" "$setting" ;;
        TRAILING) printf 'removed trailing bases of quality below %s (%s)' "$value" "$setting" ;;
        HEADCROP) printf 'removed the first %s bases of each read (%s)' "$value" "$setting" ;;
        CROP)     printf 'cut each read to %s bases (%s)' "$value" "$setting" ;;
        AVGQUAL)  printf 'discarded reads of mean quality below %s (%s)' "$value" "$setting" ;;
        *)        printf 'applied %s' "$setting" ;;
    esac
}

# The Trimmomatic steps as a clause - "discarded reads shorter than 60 bp
# (MINLEN:60), clipped adapter sequences (...), ..." - in the order they ran
trimmomatic_clause() {
    local -a runs=() first=() steps=() fields=()
    local i run name values position

    mapfile -t runs < <(trimmomatic_runs)
    (( ${#runs[@]} > 0 )) || return 0

    read -ra first <<< "${runs[0]}"

    for (( i = 0; i < ${#first[@]}; i++ )); do
        name=${first[i]%%:*}
        values=""
        position=""

        (( i > 0 )) || position=first

        for run in "${runs[@]}"; do
            read -ra fields <<< "$run"

            if [[ "${fields[i]:-}" == "$name":* ]]; then
                values+="${fields[i]#*:}"$'\n'
            fi
        done

        values=$(LC_ALL=C sort -u <<< "${values%$'\n'}")
        steps+=("$(trimmomatic_step "$name" "$values" "$position")")
    done

    and_list "${steps[@]}"
}

# 1. What the run was given
NEXTFLOW_VERSION=$(state_get manifest.software.nextflow)
HOST_DB=$(state_get manifest.params.kneaddata_db)
SEQUENCER_SOURCE=$(state_get manifest.params.kneaddata_sequencer_source)
KNEADDATA_ARGS=$(state_get manifest.params.kneaddata_args)
METAPHLAN_DB=$(state_get manifest.params.metaphlan_db)
METAPHLAN_ARGS=$(state_get manifest.params.metaphlan_args)
RUN_HUMANN=$(state_get manifest.params.run_humann)
HUMANN_CHOCOPHLAN=$(state_get manifest.params.humann_chocophlan)
HUMANN_UNIREF=$(state_get manifest.params.humann_uniref)
LAYOUT=$(state_get statistics.layout)

SAMPLESHEET=$(state_get manifest.params.input)

: "${SEQUENCER_SOURCE:=NexteraPE}"

KNEADDATA_LOGS=()

for log in "$RESULTS_DIR"/kneaddata/logs/*.log; do
    if [[ -r "$log" ]]; then
        KNEADDATA_LOGS+=("$log")
    fi
done

#    The samples the samplesheet lists more than one sequencing run for
SAMPLE_RUNS=()

if [[ -r "$SAMPLESHEET" ]]; then
    mapfile -t SAMPLE_RUNS < <(tail -n +2 "$SAMPLESHEET" | cut -d, -f1 | LC_ALL=C sort | uniq -d)
fi

[[ -n "$METAPHLAN_DB" ]] \
    || fail "This run recorded no MetaPhlAn database, so its methods cannot be described."

TOOLS=(kneaddata metaphlan multiqc)
[[ "$RUN_HUMANN" == true ]] && TOOLS=(kneaddata metaphlan humann multiqc)

IMAGES=()

for tool in "${TOOLS[@]}"; do
    image=$(container_image "$tool")

    if [[ -n "$image" ]]; then
        IMAGES+=("$image")
    fi
done

# 2. The workflow, and the images the tools ran from
cite ditommaso2017
TEXT="Sequencing reads were processed with a $(named Nextflow "$NEXTFLOW_VERSION")$CITATION workflow"
cite daveigaleprevost2017
TEXT+=" that ran each tool from a BioContainers image$CITATION"
(( ${#IMAGES[@]} == 0 )) || TEXT+=" ($(and_list "${IMAGES[@]}"))"
TEXT+="."

# 3. KneadData, as its logs recorded it, and the quality reports
if (( ${#KNEADDATA_LOGS[@]} == 0 )); then
    warn "No KneadData logs in $RESULTS_DIR/kneaddata/logs; the methods describe KneadData's defaults."
fi

if (( ${#SAMPLE_RUNS[@]} > 0 )); then
    TEXT+=" Where a sample was sequenced in more than one run, the reads of its runs were concatenated."
fi

cite beghini2021
TEXT+=" Reads were quality controlled with $(named KneadData "$(tool_version kneaddata)")$CITATION"
TEXT+="$(extra_options "$KNEADDATA_ARGS")."

TRIMMED=""
REPEATS=""

if [[ "$(kneaddata_setting bypass_trim)" != True ]]; then
    DEFAULT_TRIMMING=false
    [[ "$(kneaddata_setting trimmomatic_options)" == None ]] && DEFAULT_TRIMMING=true

    TRIMMING=$(trimmomatic_clause)

    if [[ -n "$TRIMMING" ]]; then
        cite bolger2014
        TEXT+=" Trimmomatic$CITATION $TRIMMING."
        TRIMMED=1
    fi
fi

if [[ "$(kneaddata_setting bypass_trf)" != True ]]; then
    cite benson1999
    TEXT+=" Reads in which Tandem Repeats Finder$CITATION detected a tandem repeat were removed"
    TEXT+=" (match $(kneaddata_setting match), mismatch $(kneaddata_setting mismatch),"
    TEXT+=" indel $(kneaddata_setting delta), PM $(kneaddata_setting pm), PI $(kneaddata_setting pi),"
    TEXT+=" minimum score $(kneaddata_setting minscore), maximum period $(kneaddata_setting maxperiod))."
    REPEATS=1
fi

if [[ "$LAYOUT" == *paired* && -n "$TRIMMED$REPEATS" ]]; then
    DISCARDED="${TRIMMED:+Trimmomatic}"
    [[ -n "$REPEATS" ]] && DISCARDED+="${DISCARDED:+ or }Tandem Repeats Finder"

    TEXT+=" A read whose mate was discarded by $DISCARDED"
    TEXT+=" was kept as an unpaired read."
fi

if [[ -n "$HOST_DB" ]]; then
    PAIRING=$(kneaddata_setting decontaminate_pairs)
    [[ -z "${KNEADDATA_LOGS[*]}" && "$LAYOUT" == single-end ]] && PAIRING=unpaired

    BOWTIE2_OPTIONS=$(kneaddata_setting bowtie2_options | head -n 1 | sed -E 's/ ?--phred(33|64)//g')

    host_phrase "$HOST_DB"
    TEXT+=" Reads aligning to $PHRASE"
    [[ -n "$ENTRY" ]] && TEXT+=" from NCBI RefSeq"
    TEXT+="$CITATION"

    cite langmead2012
    TEXT+=" with Bowtie2$CITATION${BOWTIE2_OPTIONS:+ ($BOWTIE2_OPTIONS)} were then removed"

    if grep -qx strict <<< "$PAIRING"; then
        TEXT+=" together with their mates."
    elif grep -qx lenient <<< "$PAIRING"; then
        TEXT+=", a pair only when both mates aligned."
    else
        TEXT+="."
    fi
else
    TEXT+=" Host sequences were not removed."
fi

cite andrews2010
TEXT+=" Read quality before and after processing was assessed with"
TEXT+=" FastQC$CITATION"
cite ewels2016
TEXT+=" and summarized with $(named MultiQC "$(tool_version multiqc)")$CITATION."

# 4. MetaPhlAn
READS="the quality-controlled reads"
[[ "$LAYOUT" == *paired* ]] && READS="the quality-controlled paired and unpaired reads"

cite blancomiguez2023
TEXT+=" Taxonomic profiles were generated from $READS with"
TEXT+=" $(named MetaPhlAn "$(tool_version metaphlan)")$CITATION"

database_phrase "$METAPHLAN_DB"
TEXT+=" and $PHRASE$CITATION"

cite_new langmead2012
TEXT+=", mapping reads with Bowtie2$CITATION"
TEXT+=" and estimating the unclassified fraction (--unclassified_estimation)$(extra_options "$METAPHLAN_ARGS")."

cite mcdonald2012
TEXT+=" Estimated species read counts were written as BIOM tables with biom-format$CITATION."

# 5. HUMAnN
if [[ "$RUN_HUMANN" == true ]]; then
    cite beghini2021
    TEXT+=" Functional profiles were generated from the same reads with"
    TEXT+=" $(named HUMAnN "$(tool_version humann)")$CITATION."

    cite_new langmead2012
    TEXT+=" Guided by each sample's MetaPhlAn profile, reads were mapped with Bowtie2$CITATION"

    database_phrase "$HUMANN_CHOCOPHLAN"
    TEXT+=" to pangenomes of the detected species from $PHRASE$CITATION,"

    cite buchfink2021
    TEXT+=" and reads that did not map were aligned in a translated search with"
    TEXT+=" DIAMOND$CITATION"

    database_phrase "$HUMANN_UNIREF"
    TEXT+=" against $PHRASE$CITATION."

    cite caspi2020
    TEXT+=" Gene family abundances, in reads per kilobase, were summarized as MetaCyc pathways$CITATION"
    cite ye2009
    TEXT+=" with MinPath$CITATION, regrouped to Enzyme Commission numbers and KEGG Orthology groups"
    cite kanehisa2000
    TEXT+="$CITATION, normalized to relative abundance, and split by contributing species with"
    TEXT+=" the HUMAnN utility scripts."
fi

# 6. The paragraph and the references it cites
if ! jq -n --arg text "$TEXT" --slurpfile refs "$REFERENCES" '
        [$text | scan("\\[@[^\\]]*\\]") | scan("@([A-Za-z0-9_]+)") | .[0]] | unique as $ids
        | ($ids - ($refs[0].references | keys)) as $missing
        | if ($missing | length) > 0
          then error("config/references.json has no " + ($missing | join(", ")))
          else {paragraphs: [$text],
                references: ($refs[0].references
                             | with_entries(select(.key as $k | $ids | any(.[]; . == $k))))}
          end' > "$METHODS_DATA.tmp"; then
    rm -f "$METHODS_DATA.tmp"
    fail "The methods text could not be written."
fi

mv "$METHODS_DATA.tmp" "$METHODS_DATA"

log "Wrote the methods text to $METHODS_DATA."
