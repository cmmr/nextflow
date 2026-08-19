#!/bin/bash
#
# ampliseq_samplesheet.sh - Convert the lab samplesheet into nf-core/ampliseq format.
#
# Author: Daniel Smith
# Date:   August 12th, 2026
#
# Reads the lab's standard whitespace-delimited samplesheet (sample, fastq_1,
# fastq_2 per line, no header) and writes ./ampliseq_samplesheet.tsv, doing the
# three things ampliseq will not do for itself:
#
#  - Recompresses .bz2 and uncompressed FASTQ files to .gz, which is all ampliseq reads.
#  - Merges FASTQ files that share a sample name into one pair of files, since
#    ampliseq requires sample names to be unique.
#  - Renames samples that ampliseq would reject: names must be alphanumeric or
#    underscore, and must not start with a digit.
#
# Every sample ends up as exactly one pair of files in ./raw-sequences/, named
# <sample>_1.fq.gz and <sample>_2.fq.gz, and the samplesheet points there.
# Already-gzipped inputs are symlinked rather than copied; only merged and
# non-gzip inputs are written out. ampliseq_upload.sh archives this directory for
# clients, and zip stores what a symlink points at, so the archive holds real data.
#
# Failures here are caused by the user's samplesheet, which is what fail is for:
# it writes the explanation to ./message.out, and wrike_followup.sh posts that
# back to the requester once the job ends.
#
# Usage:     ampliseq_samplesheet.sh [input_samplesheet]
#            defaults to ./original_samplesheet.tsv, as downloaded by wrike_job.sh
# Called by: wrike_job.sh, as the PRE_PROCESS_CMD of the ampliseq pipelines
# Requires:  pigz and md5sum from PATH; $NEXTFLOW_DIR/bin/lbzip2 additionally
#            for .bz2 inputs
# Env:       the log and fail helpers, sourced from .env
# Outputs:   ./ampliseq_samplesheet.tsv, ./raw-sequences/, ./sample_count.txt, and
#            ./message.out on error
#
# Because the samplesheet is whitespace-delimited, FASTQ paths cannot contain spaces.

set -euo pipefail

source /data/prod/nextflow/.env

INPUT_SAMPLESHEET="${1:-original_samplesheet.tsv}"
OUT_TSV="ampliseq_samplesheet.tsv"

# Written in the run directory, beside the other files a run leaves for the
# scripts that come after it
SAMPLE_COUNT_FILE="sample_count.txt"

# Client-facing archive directory. ampliseq_upload.sh zips this by the same name.
FASTQ_DIR="raw-sequences"

# The cluster's own build rather than a system package, so it is named by absolute
# path. pigz and md5sum below are system tools and stay bare.
LBZIP2="$NEXTFLOW_DIR/bin/lbzip2"

for tool in pigz md5sum; do
    command -v "$tool" > /dev/null || fail "Required tool '$tool' is not installed."
done

[[ -r "$INPUT_SAMPLESHEET" ]] || fail "Samplesheet '$INPUT_SAMPLESHEET' is not readable."

mkdir -p "$FASTQ_DIR"

# Use every CPU Slurm gave us, falling back to 1 when run outside of Slurm
THREADS="${SLURM_CPUS_PER_TASK:-${SLURM_CPUS_ON_NODE:-1}}"

# Decompress any mix of .bz2, .gz, and raw FASTQ inputs into one .gz file,
# streaming throughout so merging large runs never needs scratch space.
stream_to_gz() {
    local outfile="$1"
    local file
    shift

    for file in "$@"; do
        if [[ "$file" == *.bz2 ]]; then
            "$LBZIP2" -n "$THREADS" -dc "$file"
        elif [[ "$file" == *.gz ]]; then
            pigz -p "$THREADS" -dc "$file"
        else
            cat "$file"
        fi
    done | pigz -p "$THREADS" -c > "$outfile"
}

# Place one input file at its destination in FASTQ_DIR: gzipped files are
# symlinked, anything else recompressed. The link target must be absolute, since
# the link resolves from inside FASTQ_DIR rather than from here.
link_or_compress() {
    local src="$1"
    local dest="$2"

    if [[ "$src" == *.gz ]]; then
        ln -sfn "$(readlink -e "$src")" "$dest"
    else
        log "Compressing '$src'..."
        stream_to_gz "$dest" "$src"
    fi
}

# SAMPLE_ORDER preserves the samplesheet's ordering, which the associative
# arrays do not; the maps hold space-separated file lists per sanitized name.
declare -a SAMPLE_ORDER=()
declare -A SAMPLE_FQ1_MAP=()
declare -A SAMPLE_FQ2_MAP=()

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

    # read splits on whitespace and ignores leading and trailing padding
    read -r sample fq1 fq2 <<< "$line"
    [[ -z "$sample" ]] && continue

    # Skip comment lines and a header row, which a spreadsheet export often has
    [[ "$sample" == \#* ]] && continue
    [[ $line_number -eq 1 && "${sample,,}" == "sample" ]] && continue

    if [[ -z "$fq1" || -z "$fq2" ]]; then
        fail "Invalid line format in samplesheet: '$line'"
    fi

    # lbzip2 is only needed when a .bz2 input turns up, so it is checked here
    # rather than with the unconditional tools above. -x, not command -v: a
    # specific file rather than a PATH lookup.
    if [[ "$fq1" == *.bz2 || "$fq2" == *.bz2 ]]; then
        [[ -x "$LBZIP2" ]] \
            || fail "Samplesheet line $line_number has bzip2 inputs, but '$LBZIP2' is not installed."
    fi

    [[ -r "$fq1" ]] || fail "Input FASTQ file '$fq1' does not exist or is not readable."
    [[ -r "$fq2" ]] || fail "Input FASTQ file '$fq2' does not exist or is not readable."

    # Sanitize the sample name into what ampliseq accepts
    clean_sample=${sample//[^a-zA-Z0-9_]/_}
    if [[ "$clean_sample" != [a-zA-Z]* ]]; then
        clean_sample="S_$clean_sample"
    fi

    # Group by sanitized name so duplicate samples accumulate for merging.
    # Sanitizing first means names that differ only in punctuation merge too.
    if [[ -z "${SAMPLE_FQ1_MAP[$clean_sample]+set}" ]]; then
        SAMPLE_ORDER+=("$clean_sample")
        SAMPLE_FQ1_MAP["$clean_sample"]="$fq1"
        SAMPLE_FQ2_MAP["$clean_sample"]="$fq2"
    else
        SAMPLE_FQ1_MAP["$clean_sample"]+=" $fq1"
        SAMPLE_FQ2_MAP["$clean_sample"]+=" $fq2"
    fi

done < "$INPUT_SAMPLESHEET"

[[ ${#SAMPLE_ORDER[@]} -gt 0 ]] || fail "No samples found in '$INPUT_SAMPLESHEET'."

# 2. Generate the ampliseq TSV
printf "sample\tfastq_1\tfastq_2\trun\n" > "$OUT_TSV"

for clean_sample in "${SAMPLE_ORDER[@]}"; do
    read -ra fq1_list <<< "${SAMPLE_FQ1_MAP[$clean_sample]}"
    read -ra fq2_list <<< "${SAMPLE_FQ2_MAP[$clean_sample]}"

    num_files=${#fq1_list[@]}

    # Every sample lands at the same predictable pair of paths, whether its files
    # were merged, recompressed, or linked
    final_fq1="$FASTQ_DIR/${clean_sample}_1.fq.gz"
    final_fq2="$FASTQ_DIR/${clean_sample}_2.fq.gz"

    # 2a. Populate the archive directory
    if [[ "$num_files" -gt 1 ]]; then
        log "Merging $num_files duplicate entries for sample '$clean_sample'..."
        stream_to_gz "$final_fq1" "${fq1_list[@]}"
        stream_to_gz "$final_fq2" "${fq2_list[@]}"
    else
        link_or_compress "${fq1_list[0]}" "$final_fq1"
        link_or_compress "${fq2_list[0]}" "$final_fq2"
    fi

    # 2b. Derive the 'run' ID ampliseq uses to batch samples for error-model
    # training. Samples sequenced together share a source directory, so hashing
    # that directory list groups them; md5sum just shortens it to a safe token.
    # Must read the *original* paths - every sample shares FASTQ_DIR, so hashing
    # the destinations would collapse every run into one batch.
    dir_concat=""
    for fq in "${fq1_list[@]}"; do
        dir_concat+="$(dirname "$fq");"
    done
    run_hash=$(echo -n "$dir_concat" | md5sum | cut -c1-8)

    printf "%s\t%s\t%s\t%s\n" "$clean_sample" "$final_fq1" "$final_fq2" "run_$run_hash" >> "$OUT_TSV"
done

# The count after merging, which is the number of samples the run actually
# analyses. ampliseq_upload.sh puts it in the published page's header, and the
# page simply omits the figure if this file is missing.
printf '%s\n' "${#SAMPLE_ORDER[@]}" > "$SAMPLE_COUNT_FILE"

log "Successfully generated ampliseq samplesheet: $OUT_TSV (${#SAMPLE_ORDER[@]} samples)"
