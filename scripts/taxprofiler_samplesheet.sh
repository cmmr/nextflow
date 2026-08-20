#!/bin/bash
#
# taxprofiler_samplesheet.sh - Convert the lab samplesheet into nf-core/taxprofiler format.
#
# Author: Daniel Smith
# Date:   August 19th, 2026
#
# Reads the lab's standard whitespace-delimited samplesheet (sample, fastq_1,
# fastq_2 per line, no header) and writes ./taxprofiler_samplesheet.csv with the
# six columns taxprofiler requires: sample, run_accession, instrument_platform,
# fastq_1, fastq_2, fasta.
#
# Lines sharing a sample name become separate rows numbered run_1, run_2, ...
# rather than being merged; taxprofiler concatenates a sample's runs itself after
# per-run QC.
#
# taxprofiler reads gzipped FASTQ only, so every sample ends up in
# ./raw-sequences/ as <sample>_<run>_{1,2}.fq.gz: already-gzipped inputs are
# symlinked, .bz2 and plain FASTQ recompressed. taxprofiler_upload.sh archives
# that directory for the requester, and zip stores what a symlink points at, so
# the archive holds real data.
#
# Failures here are caused by the user's samplesheet: fail writes the explanation
# to ./message.out, and wrike_followup.sh posts it back to the requester.
#
# Usage:     taxprofiler_samplesheet.sh [input_samplesheet]
#            defaults to ./original_samplesheet.tsv, as downloaded by wrike_job.sh
# Called by: wrike_job.sh, as the PRE_PROCESS_CMD of the taxprofiler pipelines
# Requires:  pigz from PATH; $NEXTFLOW_DIR/bin/lbzip2 additionally for .bz2 inputs
# Env:       the log and fail helpers, sourced from .env; INSTRUMENT_PLATFORM,
#            optionally set by the pipeline definition
# Outputs:   ./taxprofiler_samplesheet.csv, ./raw-sequences/, ./sample_count.txt,
#            and ./message.out on error
#
# Because the samplesheet is whitespace-delimited, FASTQ paths cannot contain spaces.

set -euo pipefail

source /data/prod/nextflow/.env

INPUT_SAMPLESHEET="${1:-original_samplesheet.tsv}"
OUT_CSV="taxprofiler_samplesheet.csv"

# Read by taxprofiler_upload.sh for the published page's header
SAMPLE_COUNT_FILE="sample_count.txt"

# Client-facing archive directory. taxprofiler_upload.sh zips this by the same name.
FASTQ_DIR="raw-sequences"

# An ENA controlled-vocabulary value. A long-read pipeline sets OXFORD_NANOPORE.
INSTRUMENT_PLATFORM="${INSTRUMENT_PLATFORM:-ILLUMINA}"

LBZIP2="$NEXTFLOW_DIR/bin/lbzip2"

command -v pigz > /dev/null || fail "Required tool 'pigz' is not installed."

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

# Rows in samplesheet order; RUN_COUNT numbers the runs within each sample
declare -a ROW_SAMPLE=() ROW_FQ1=() ROW_FQ2=()
declare -A RUN_COUNT=()

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

    read -r sample fq1 fq2 <<< "$line"
    [[ -z "$sample" ]] && continue

    [[ "$sample" == \#* ]] && continue
    [[ $line_number -eq 1 && "${sample,,}" == "sample" ]] && continue

    if [[ -z "$fq1" || -z "$fq2" ]]; then
        fail "Invalid line format in samplesheet: '$line'"
    fi

    if [[ "$fq1" == *.bz2 || "$fq2" == *.bz2 ]]; then
        [[ -x "$LBZIP2" ]] \
            || fail "Samplesheet line $line_number has bzip2 inputs, but '$LBZIP2' is not installed."
    fi

    [[ -r "$fq1" ]] || fail "Input FASTQ file '$fq1' does not exist or is not readable."
    [[ -r "$fq2" ]] || fail "Input FASTQ file '$fq2' does not exist or is not readable."

    # The samplesheet is a CSV, so an unquoted comma in a path would split a field
    if [[ "$fq1" == *,* || "$fq2" == *,* ]]; then
        fail "Input FASTQ paths may not contain commas: '$line'"
    fi

    # taxprofiler builds output filenames from the sample and run names
    clean_sample=${sample//[^a-zA-Z0-9_]/_}
    if [[ "$clean_sample" != [a-zA-Z]* ]]; then
        clean_sample="S_$clean_sample"
    fi

    ROW_SAMPLE+=("$clean_sample")
    ROW_FQ1+=("$fq1")
    ROW_FQ2+=("$fq2")

done < "$INPUT_SAMPLESHEET"

[[ ${#ROW_SAMPLE[@]} -gt 0 ]] || fail "No samples found in '$INPUT_SAMPLESHEET'."

# 2. Generate the taxprofiler CSV. The fasta column is required in the header and
#    left empty for short reads.
printf 'sample,run_accession,instrument_platform,fastq_1,fastq_2,fasta\n' > "$OUT_CSV"

for i in "${!ROW_SAMPLE[@]}"; do
    sample=${ROW_SAMPLE[$i]}

    RUN_COUNT[$sample]=$(( ${RUN_COUNT[$sample]:-0} + 1 ))
    run="run_${RUN_COUNT[$sample]}"

    stage_read "${ROW_FQ1[$i]}" "${sample}_${run}_1.fq.gz"
    final_fq1="$STAGED_PATH"

    stage_read "${ROW_FQ2[$i]}" "${sample}_${run}_2.fq.gz"
    final_fq2="$STAGED_PATH"

    printf '%s,%s,%s,%s,%s,\n' \
        "$sample" "$run" "$INSTRUMENT_PLATFORM" "$final_fq1" "$final_fq2" >> "$OUT_CSV"
done

# Distinct samples, not rows: a sample sequenced over several runs is one sample
SAMPLE_COUNT=${#RUN_COUNT[@]}
printf '%s\n' "$SAMPLE_COUNT" > "$SAMPLE_COUNT_FILE"

log "Successfully generated taxprofiler samplesheet: $OUT_CSV ($SAMPLE_COUNT samples, ${#ROW_SAMPLE[@]} runs)"
