#!/bin/bash
#
# taxprofiler_samplesheet.sh - Convert the lab samplesheet into nf-core/taxprofiler format.
#
# Author: Daniel Smith
# Date:   August 19th, 2026
#
# Reads the lab's standard whitespace-delimited samplesheet and writes
# ./taxprofiler_samplesheet.csv with the six columns taxprofiler requires:
# sample, run_accession, instrument_platform, fastq_1, fastq_2, fasta.
#
# Input lines are "sample fastq_1 fastq_2" for paired reads or "sample fastq_1"
# for single-end. A sample's runs must all be one or the other, which is what
# taxprofiler's own cross-row check enforces.
#
# Lines sharing a sample name become separate rows numbered run_1, run_2, ...
# rather than being merged; taxprofiler concatenates a sample's runs itself after
# per-run QC.
#
# taxprofiler reads gzipped FASTQ only, so every read ends up in ./raw-sequences/
# as <sample>_<run>_{1,2}.fq.gz: already-gzipped inputs are symlinked, .bz2 and
# plain FASTQ recompressed. taxprofiler_upload.sh archives that directory for the
# requester, and zip stores what a symlink points at, so the archive holds real
# data.
#
# instrument_platform is measured rather than assumed. taxprofiler uses it for
# one decision - whether reads take the short-read or the long-read path - and
# read length answers that directly, where a header format would not survive a
# tool that renames reads. Reads longer than LONG_READ_THRESHOLD are called
# OXFORD_NANOPORE and everything else ILLUMINA. Setting INSTRUMENT_PLATFORM in
# the environment overrides the measurement, e.g. for PACBIO_SMRT.
#
# It also writes ./taxprofiler_database.csv, a per-run copy of the database sheet
# with Bracken's read length set from the data. Bracken's -r must name a
# databaseNNNmers.kmer_distrib the Kraken2 database actually carries, and the
# right one depends on the reads rather than on the pipeline.
#
# Failures here are caused by the user's samplesheet: fail writes the explanation
# to ./message.out, and wrike_followup.sh posts it back to the requester.
#
# Usage:     taxprofiler_samplesheet.sh [input_samplesheet]
#            defaults to ./original_samplesheet.tsv, as downloaded by wrike_job.sh
# Called by: wrike_job.sh, as the PRE_PROCESS_CMD of the taxprofiler pipelines
# Requires:  pigz, awk, sort and uniq from PATH; $NEXTFLOW_DIR/bin/lbzip2
#            additionally for .bz2 inputs
# Reads:     config/taxprofiler/database.csv, the database sheet it specializes
# Env:       the log and fail helpers, sourced from .env; INSTRUMENT_PLATFORM,
#            optionally set to override the measurement
# Outputs:   ./taxprofiler_samplesheet.csv, ./taxprofiler_database.csv,
#            ./raw-sequences/, ./sample_count.txt, ./read_length.txt, and
#            ./message.out on error
#
# Because the samplesheet is whitespace-delimited, FASTQ paths cannot contain spaces.

set -euo pipefail

source /data/prod/nextflow/.env

INPUT_SAMPLESHEET="${1:-original_samplesheet.tsv}"
OUT_CSV="taxprofiler_samplesheet.csv"

# Read by taxprofiler_upload.sh for the published page's header
SAMPLE_COUNT_FILE="sample_count.txt"

# The database sheet the pipeline definition names, written per run, and the
# static one it is derived from
OUT_DB_SHEET="taxprofiler_database.csv"
STATIC_DB_SHEET="$NEXTFLOW_DIR/config/taxprofiler/database.csv"

# The measured read length, kept beside the other run metadata
READ_LENGTH_FILE="read_length.txt"

# Reads per file to sample when measuring read length
READ_LENGTH_SAMPLE=10000

# Median read length above which a run is treated as long-read. No Illumina
# instrument reaches 1000bp; nanopore and PacBio runs are far above it.
LONG_READ_THRESHOLD=1000

# How far the nearest available Bracken distribution may sit from the measured
# read length before it is worth mentioning, as a percentage of that length.
# Relative rather than absolute: 15bp off matters at 35bp and does not at 250bp.
READ_LENGTH_TOLERANCE_PCT=15

# Client-facing archive directory. taxprofiler_upload.sh zips this by the same name.
FASTQ_DIR="raw-sequences"

LBZIP2="$NEXTFLOW_DIR/bin/lbzip2"

for tool in pigz awk sort uniq; do
    command -v "$tool" > /dev/null || fail "Required tool '$tool' is not installed."
done

[[ -r "$INPUT_SAMPLESHEET" ]] || fail "Samplesheet '$INPUT_SAMPLESHEET' is not readable."

mkdir -p "$FASTQ_DIR"

THREADS="${SLURM_CPUS_PER_TASK:-${SLURM_CPUS_ON_NODE:-1}}"

# Decompress one .bz2 or plain FASTQ into a .gz, streaming throughout
to_gz() {
    local src="$1"
    local outfile="$2"

    log "Compressing '$src'..."
    if [[ "$src" == *.bz2 ]]; then
        "$LBZIP2" -n "$THREADS" -dc "$src"
    else
        cat "$src"
    fi | pigz -p "$THREADS" -c > "$outfile"
}

# Place one input file at its destination in FASTQ_DIR and set STAGED_PATH to it:
# gzipped files are symlinked, anything else recompressed. The link target must
# be absolute, since the link resolves from inside FASTQ_DIR rather than here.
#
# Sets STAGED_PATH rather than printing it. set -e does not reach a function
# called inside a command substitution, so a failed recompression there would
# leave an empty file and carry on.
stage_read() {
    local src="$1"
    local dest="$FASTQ_DIR/$2"

    if [[ "$src" == *.gz ]]; then
        ln -sfn "$(readlink -e "$src")" "$dest"
    else
        to_gz "$src" "$dest"
    fi

    STAGED_PATH="$PWD/$dest"
}

# Modal and median read length across the staged R1 files, as "mode median".
# The mode picks Bracken's distribution, which is right for the fixed-length
# reads that use it; the median decides the platform, being the more stable of
# the two across the long tail of a nanopore run.
#
# awk exits once it has seen enough of a file, which closes the pipe on pigz, so
# its status is discarded.
read_length_stats() {
    local file

    for file in "$@"; do
        { pigz -dc "$file" 2> /dev/null || true; } \
            | awk -v n="$READ_LENGTH_SAMPLE" 'NR % 4 == 2 { print length; if (++seen >= n) exit }'
    done | sort -n | uniq -c | awk '
        {
            count[NR] = $1
            value[NR] = $2
            total += $1
            if ($1 > best) {
                best = $1
                mode = $2
            }
        }
        END {
            if (NR == 0) exit
            for (i = 1; i <= NR; i++) {
                seen += count[i]
                if (seen >= total / 2) {
                    median = value[i]
                    break
                }
            }
            print mode, median
        }'
}

# The read length of the closest databaseNNNmers.kmer_distrib in a Kraken2
# database directory
nearest_distrib() {
    local db_path="$1"
    local target="$2"
    local file base len gap best="" best_gap=""

    for file in "$db_path"/database*mers.kmer_distrib; do
        [[ -r "$file" ]] || continue

        base=${file##*/}
        len=${base#database}
        len=${len%mers.kmer_distrib}
        [[ "$len" =~ ^[0-9]+$ ]] || continue

        gap=$(( len > target ? len - target : target - len ))
        if [[ -z "$best_gap" || "$gap" -lt "$best_gap" ]]; then
            best_gap="$gap"
            best="$len"
        fi
    done

    [[ -n "$best" ]] || return 1
    printf '%s' "$best"
}

# Copy the static database sheet, rewriting the bracken row's -r. Columns are
# located by header name rather than by position. Anything before the semicolon
# in db_params is kraken2's and is left alone.
write_database_sheet() {
    local length="$1"

    awk -F, -v OFS=, -v len="$length" '
        NR == 1 {
            for (i = 1; i <= NF; i++) idx[$i] = i
            print
            next
        }
        NF < 2 { next }
        {
            if (idx["tool"] && $idx["tool"] == "bracken") {
                params = $idx["db_params"]
                semi = index(params, ";")
                kraken = semi ? substr(params, 1, semi - 1) : params
                bracken = semi ? substr(params, semi + 1) : ""

                gsub(/(^| )-r +[0-9]+/, "", bracken)
                gsub(/^ +| +$/, "", bracken)

                $idx["db_params"] = kraken ";-r " len (bracken == "" ? "" : " " bracken)
            }
            print
        }
    ' "$STATIC_DB_SHEET"
}

# Rows in samplesheet order; RUN_COUNT numbers the runs within each sample and
# SAMPLE_LAYOUT records whether a sample is paired, so its runs can be checked
# against each other
declare -a ROW_SAMPLE=() ROW_FQ1=() ROW_FQ2=()
declare -A RUN_COUNT=() SAMPLE_LAYOUT=()

# Staged files, in row order. STAGED_R2 holds an empty string for single-end rows.
declare -a STAGED_R1=() STAGED_R2=()

# 1. Read and validate the samplesheet line by line.
# The || clause picks up a final line that is missing its trailing newline.
line=""
line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))

    # Strip carriage returns from Windows-edited sheets and convert the
    # non-breaking spaces that come from pasting out of a spreadsheet
    line=${line//$'\r'/}
    line=${line//$'\xc2\xa0'/ }

    # A fourth field would silently vanish into fq2, so catch it
    read -r sample fq1 fq2 extra <<< "$line"
    [[ -z "$sample" ]] && continue

    [[ "$sample" == \#* ]] && continue
    [[ $line_number -eq 1 && "${sample,,}" == "sample" ]] && continue

    if [[ -z "$fq1" ]]; then
        fail "Samplesheet line $line_number names no FASTQ file: '$line'"
    fi

    if [[ -n "$extra" ]]; then
        fail "Samplesheet line $line_number has more than three columns: '$line'"
    fi

    if [[ "$fq1" == *.bz2 || "$fq2" == *.bz2 ]]; then
        [[ -x "$LBZIP2" ]] \
            || fail "Samplesheet line $line_number has bzip2 inputs, but '$LBZIP2' is not installed."
    fi

    [[ -r "$fq1" ]] || fail "Input FASTQ file '$fq1' does not exist or is not readable."
    if [[ -n "$fq2" ]]; then
        [[ -r "$fq2" ]] || fail "Input FASTQ file '$fq2' does not exist or is not readable."
    fi

    # The samplesheet is a CSV, so an unquoted comma in a path would split a field
    if [[ "$fq1" == *,* || "$fq2" == *,* ]]; then
        fail "Input FASTQ paths may not contain commas: '$line'"
    fi

    # taxprofiler itself only forbids whitespace in a sample name, but the name
    # becomes part of output filenames that reach unquoted shell contexts in the
    # nf-core modules, so keep it to characters that are safe there. Dots and
    # dashes survive, which is what most sample names actually use.
    clean_sample=${sample//[^A-Za-z0-9._-]/_}

    # A leading dash reads as an option to whatever the name is handed to
    [[ "$clean_sample" == -* ]] && clean_sample="_$clean_sample"

    if [[ "$clean_sample" != "$sample" ]]; then
        log "Renamed sample '$sample' to '$clean_sample'."
    fi

    # taxprofiler rejects a sample whose runs disagree, so say so here instead
    layout="single"
    [[ -n "$fq2" ]] && layout="paired"

    if [[ -n "${SAMPLE_LAYOUT[$clean_sample]:-}" && "${SAMPLE_LAYOUT[$clean_sample]}" != "$layout" ]]; then
        fail "Sample '$clean_sample' mixes paired and single-end runs; taxprofiler needs one or the other."
    fi
    SAMPLE_LAYOUT["$clean_sample"]="$layout"

    ROW_SAMPLE+=("$clean_sample")
    ROW_FQ1+=("$fq1")
    ROW_FQ2+=("$fq2")

done < "$INPUT_SAMPLESHEET"

[[ ${#ROW_SAMPLE[@]} -gt 0 ]] || fail "No samples found in '$INPUT_SAMPLESHEET'."

# 2. Stage every read into FASTQ_DIR. Done before the CSV is written because the
#    platform column is measured from the staged files.
declare -a ROW_RUN=()

for i in "${!ROW_SAMPLE[@]}"; do
    sample=${ROW_SAMPLE[$i]}

    RUN_COUNT[$sample]=$(( ${RUN_COUNT[$sample]:-0} + 1 ))
    run="run_${RUN_COUNT[$sample]}"
    ROW_RUN+=("$run")

    stage_read "${ROW_FQ1[$i]}" "${sample}_${run}_1.fq.gz"
    STAGED_R1+=("$STAGED_PATH")

    if [[ -n "${ROW_FQ2[$i]}" ]]; then
        stage_read "${ROW_FQ2[$i]}" "${sample}_${run}_2.fq.gz"
        STAGED_R2+=("$STAGED_PATH")
    else
        STAGED_R2+=("")
    fi
done

# 3. Measure the reads, which decides both the platform and Bracken's -r.
READ_STATS=$(read_length_stats "${STAGED_R1[@]}") || READ_STATS=""
read -r READ_MODE READ_MEDIAN <<< "$READ_STATS"

if [[ -z "${READ_MEDIAN:-}" ]]; then
    warn "Could not measure a read length; assuming ILLUMINA."
    READ_MODE=""
    READ_MEDIAN=0
else
    printf '%s\n' "$READ_MODE" > "$READ_LENGTH_FILE"
fi

if [[ -n "${INSTRUMENT_PLATFORM:-}" ]]; then
    log "instrument_platform pinned to $INSTRUMENT_PLATFORM; skipping detection."
elif [[ "$READ_MEDIAN" -gt "$LONG_READ_THRESHOLD" ]]; then
    INSTRUMENT_PLATFORM="OXFORD_NANOPORE"
    log "Median read length is ${READ_MEDIAN}bp; treating this run as $INSTRUMENT_PLATFORM."
else
    INSTRUMENT_PLATFORM="ILLUMINA"
    log "Median read length is ${READ_MEDIAN}bp; treating this run as $INSTRUMENT_PLATFORM."
fi

# taxprofiler rejects a long-read row that names a second FASTQ, and paired
# long reads do not exist, so this is a mislabelled or mis-built samplesheet
if [[ "$INSTRUMENT_PLATFORM" == "OXFORD_NANOPORE" || "$INSTRUMENT_PLATFORM" == "PACBIO_SMRT" ]]; then
    for i in "${!ROW_SAMPLE[@]}"; do
        if [[ -n "${ROW_FQ2[$i]}" ]]; then
            REASON="These reads are long (median ${READ_MEDIAN}bp), but sample"
            REASON+=" '${ROW_SAMPLE[$i]}' names two FASTQ files."
            REASON+=" Long-read samples take one file per line."
            fail "$REASON"
        fi
    done
fi

# 4. Generate the taxprofiler CSV. fastq_2 is empty for single-end rows and the
#    fasta column is always empty.
printf 'sample,run_accession,instrument_platform,fastq_1,fastq_2,fasta\n' > "$OUT_CSV"

for i in "${!ROW_SAMPLE[@]}"; do
    printf '%s,%s,%s,%s,%s,\n' \
        "${ROW_SAMPLE[$i]}" "${ROW_RUN[$i]}" "$INSTRUMENT_PLATFORM" \
        "${STAGED_R1[$i]}" "${STAGED_R2[$i]}" >> "$OUT_CSV"
done

# Distinct samples, not rows: a sample sequenced over several runs is one sample
SAMPLE_COUNT=${#RUN_COUNT[@]}
printf '%s\n' "$SAMPLE_COUNT" > "$SAMPLE_COUNT_FILE"

log "Successfully generated taxprofiler samplesheet: $OUT_CSV ($SAMPLE_COUNT samples, ${#ROW_SAMPLE[@]} runs)"

# 5. Specialize the database sheet to these reads. Bracken's -r must name a
#    distribution the Kraken2 database ships, and a mismatch biases its
#    abundance estimates silently, so it is measured rather than assumed.
#
#    Every failure here falls back to the static sheet: a run is still worth
#    doing with Bracken's recorded default.
[[ -r "$STATIC_DB_SHEET" ]] || fail "The database sheet '$STATIC_DB_SHEET' is not readable."

if [[ -z "$READ_MODE" ]]; then
    warn "No read length measured; using the database sheet as written."
    cp "$STATIC_DB_SHEET" "$OUT_DB_SHEET"
elif [[ "$INSTRUMENT_PLATFORM" != "ILLUMINA" ]]; then
    # taxprofiler skips Bracken on long reads, so there is nothing to tune
    log "Long-read run; Bracken does not apply and the database sheet is used as written."
    cp "$STATIC_DB_SHEET" "$OUT_DB_SHEET"
else
    #    The bracken row names the Kraken2 database it reads its distributions from
    BRACKEN_DB=$(awk -F, '
        NR == 1 { for (i = 1; i <= NF; i++) idx[$i] = i; next }
        idx["tool"] && $idx["tool"] == "bracken" { print $idx["db_path"]; exit }
    ' "$STATIC_DB_SHEET")

    if [[ -z "$BRACKEN_DB" ]]; then
        log "No bracken row in the database sheet; using it as written."
        cp "$STATIC_DB_SHEET" "$OUT_DB_SHEET"
    elif ! DISTRIB=$(nearest_distrib "$BRACKEN_DB" "$READ_MODE"); then
        warn "No databaseNNNmers.kmer_distrib in '$BRACKEN_DB'; using the database sheet as written."
        cp "$STATIC_DB_SHEET" "$OUT_DB_SHEET"
    else
        GAP=$(( DISTRIB > READ_MODE ? DISTRIB - READ_MODE : READ_MODE - DISTRIB ))
        if (( GAP * 100 > READ_LENGTH_TOLERANCE_PCT * READ_MODE )); then
            warn "Reads are ${READ_MODE}bp but the closest Bracken distribution is ${DISTRIB}bp;"
            warn "abundance estimates may be biased. Build a ${READ_MODE}mer distribution to fix this."
        fi

        write_database_sheet "$DISTRIB" > "$OUT_DB_SHEET"
        log "Reads are ${READ_MODE}bp; Bracken set to -r $DISTRIB in $OUT_DB_SHEET"
    fi
fi
