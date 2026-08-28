#!/bin/bash
#
# ampliseq_detect_region.sh - Work out what a run's reads are, from the reads.
#
# Author: Daniel Smith
# Date:   August 25th, 2026
#
# The requester names neither a sequencing platform nor a 16S region. Both are
# measured here: a sample of reads is aligned to the landmark 16S genes
# build_16s_reference.sh assembled, each hit is translated into E. coli
# numbering, and the amplicon's ends are compared against the regions this system
# supports.
#
# Read layout comes from the samplesheet ampliseq_samplesheet.sh just wrote - a
# sheet with no fastq_2 column is single-end - and platform from how many reads
# are longer than 1000 bases, the same line taxprofiler_samplesheet.sh draws.
# Together they give ampliseq's sequencing_type:
#
#   paired + short   illumina_pe      single + short   illumina_se
#   paired + long    refused          single + long    nanopore
#
# PacBio HiFi is also single and long, and read length cannot tell it from ONT.
# Long single-end reads are called nanopore because that is what the lab runs;
# a PacBio run needs "sequencing_type: pacbio" in the request's arguments.
#
# How the amplicon's ends are found depends on what the reads are:
#
#   paired         mate 1 aligns to one strand of the gene and mate 2 to the
#                  other, so the median 5' end of each mate is one end of the
#                  amplicon. Reads are cut to PROBE_LENGTH first, since the 5'
#                  end is set by where the primer bound while the 3' end moves
#                  with read length, quality trimming and adapter read-through.
#   single, long    one read spans the whole amplicon, so its own two ends are
#                  the amplicon's. vsearch reports target coordinates ascending
#                  whichever way the read aligned, so ONT's mixed orientation
#                  needs no untangling. The read is aligned whole, barcodes and
#                  adapters included, so it is asked to cover the gene rather
#                  than to be covered by it.
#   single, short   only the end the reads start at can be measured, and the
#                  region has to be identified from that one coordinate.
#
# Each region is scored in four variants - either end may still carry its primer,
# or may have had it trimmed off before the reads arrived - so one measurement
# gives both the region and whether cutadapt has anything left to remove.
# Neighbouring regions sit at least 157 bases apart on the gene and the variants
# of a single region within 39, so the variants never blur the choice of region.
#
# Writes ./detected_params.yaml, which wrike_job.sh layers over the pipeline's
# defaults: sequencing_type, the two primers, skip_cutadapt, and for ONT the
# Savont settings that go with it.
#
# Does nothing when PIPELINE_RERUN_UID is set. A rerun's parameters come from the
# run it reproduces, so measuring this run's reads could only disagree with them.
#
# Usage:     ampliseq_detect_region.sh [ampliseq_samplesheet.tsv]
# Called by: wrike_job.sh, as one of the PRE_PROCESS_CMDS of the ampliseq pipeline,
#            after ampliseq_samplesheet.sh has normalized the reads
# Requires:  pigz, awk, sort, apptainer
# Reads:     db/16s/landmarks.fasta and db/16s/ecoli_positions.tsv, from
#            build_16s_reference.sh
# Env:       NEXTFLOW_DIR and the log/warn/fail helpers, sourced from .env;
#            PIPELINE_RERUN_UID, set by wrike_job.sh for a rerun;
#            VSEARCH_CONTAINER, optionally, to override the pinned image
# Outputs:   ./detected_params.yaml, ./region.txt, ./region_detection.txt, a line
#            appended to ./notes.txt, and ./message.out on error. The working
#            files it measured from - detect_sample.fasta, detect_reads.fasta,
#            detect_lengths.txt and detect_hits.tsv - are left in place.

set -euo pipefail

source /data/prod/nextflow/.env

# The regions a request may turn out to be, as
# id | label | FW primer | its 5' position | RV primer | the 3' position of its
# binding site - all in E. coli K-12 MG1655 16S numbering, which is what
# db/16s/ecoli_positions.tsv translates an alignment into.
readonly REGIONS=(
    "16SV1V3|16S V1-V3|AGAGTTTGATCCTGGCTCAG|8|ATTACCGCGGCTGCTGG|534"
    "16SV3V5|16S V3-V5|CCTACGGGAGGCAGCAG|341|CCGTCAATTCMTTTRAGT|926"
    "16SV4|16S V4|GTGCCAGCMGCCGCGGTAA|515|GGACTACHVGGGTWTCTAAT|806"
    "16SV5V6|16S V5-V6|GGATTAGATACCCBDGTAGTCC|785|ACGARCTGRCGRCRRCCRTGC|1073"
    "16SFULL|16S full length|AGAGTTTGATYMTGGCTCAG|8|TACGGYTACCTTGTTACGACTT|1513"
)

# Paired Illumina reads cannot overlap across an amplicon this long, so DADA2
# cannot merge them. Long reads span it in one piece, which is the point of
# sequencing it that way.
readonly UNMERGEABLE_REGIONS="16SFULL"

readonly REFERENCE_DIR="$NEXTFLOW_DIR/db/16s"
readonly LANDMARKS="$REFERENCE_DIR/landmarks.fasta"
readonly POSITIONS="$REFERENCE_DIR/ecoli_positions.tsv"

readonly VSEARCH_CONTAINER="${VSEARCH_CONTAINER:-docker://quay.io/biocontainers/vsearch:2.31.0--hd2be7a0_0}"

# How much of the run to look at. The platform and region are properties of the
# library rather than of a sample, so this is about outvoting noise, not coverage.
# Every read of a chosen sample is measured for length, and the reads that go on
# to the aligner are drawn uniformly from the whole file rather than from its
# head: an ONT run writes its shortest reads first, and they are not the library.
readonly MAX_SAMPLES=8
readonly MAX_READS_SHORT=2000
readonly MAX_READS_LONG=40000
readonly MIN_READ_LENGTH=100
readonly PROBE_LENGTH=150
readonly MAX_AMBIGUOUS=3

# A read longer than this came off a long-read instrument, since no Illumina one
# reaches it - the same line taxprofiler_samplesheet.sh draws. The run is called
# long-read when at least LONG_READ_FRACTION of its reads are that long. The
# fraction is read rather than the median because an ONT run's lengths are
# bimodal, unusable short reads on one side and amplicons on the other, and its
# median sits in the trough between them.
readonly LONG_READ_THRESHOLD=1000
readonly LONG_READ_FRACTION=0.05

# What the alignment has to produce before its answer is trusted. Only a few
# percent of an ONT amplicon run aligns - the rest is off-target product, reads
# too short to cover the gene, and the adapters and barcodes still on them - so
# the count is reached by looking at a wide sample rather than by asking much of
# it. A run that produced too few reads to reach it and one that sequenced
# something other than 16S both end up here, and they are told apart by what
# share of the sample aligned rather than by how much of it did.
readonly MIN_ALIGNED_READS=200
readonly MIN_ALIGNED_FRACTION=0.02
readonly MIN_STRAND_FRACTION=0.8

# How far into a landmark to look for a base that has an E. coli position, when
# the end of a hit is in a stretch with none. Bases inserted relative to E. coli,
# and the ragged ends soft-clipped when the landmark was aligned to it, are
# absent from ecoli_positions.tsv, and a full-length amplicon ends in exactly
# those. Snapping inward shortens the measured amplicon by up to this much.
readonly MAX_POSITION_SNAP=25

# How far the measured ends may sit from a region's expected coordinates, and how
# much worse the runner-up region has to be. A run with only one measurable end
# is held to half the drift, since it has half the evidence.
readonly MAX_DRIFT=60
readonly MAX_DRIFT_ONE_END=30
readonly MIN_MARGIN=120

readonly SAMPLESHEET="${1:-ampliseq_samplesheet.tsv}"
readonly SAMPLE_FASTA="detect_sample.fasta"
readonly READS_FASTA="detect_reads.fasta"
readonly LENGTHS_TXT="detect_lengths.txt"
readonly HITS_TSV="detect_hits.tsv"
readonly REPORT="region_detection.txt"
readonly PARAMS_OUT="detected_params.yaml"
readonly REGION_OUT="region.txt"

if [[ -n "${PIPELINE_RERUN_UID:-}" ]]; then
    log "Reproducing run $PIPELINE_RERUN_UID; its recorded parameters replace anything measured here."
    exit 0
fi

# The regions a requester's reads could have turned out to be, for the messages
# that report not finding one
supported_regions() {
    local entry
    for entry in "${REGIONS[@]}"; do
        entry=${entry#*|}
        printf '  %s\n' "${entry%%|*}"
    done
}

for tool in pigz awk sort apptainer; do
    command -v "$tool" > /dev/null || fail "Required tool '$tool' is not installed."
done

if [[ ! -r "$LANDMARKS" || ! -r "$POSITIONS" ]]; then
    REASON="What this run sequenced could not be determined:"
    REASON+=" the reference the detector needs is missing from the server."
    fail "$REASON ($REFERENCE_DIR; run scripts/build_16s_reference.sh)"
fi

[[ -r "$SAMPLESHEET" ]] || fail "Samplesheet '$SAMPLESHEET' is not readable."

THREADS="${SLURM_CPUS_PER_TASK:-${SLURM_CPUS_ON_NODE:-1}}"

report_stage "Measuring which 16S region was sequenced."

# 1. Read layout, from the sheet ampliseq_samplesheet.sh wrote: it leaves the
#    fastq_2 column off entirely for a single-end run.
IFS=$'\t' read -r -a SHEET_HEADER < "$SAMPLESHEET"

READ_LAYOUT="single"
if [[ " ${SHEET_HEADER[*]} " == *" fastq_2 "* ]]; then
    READ_LAYOUT="paired"
fi

# 2. Take a spread of samples rather than the first few, so a plate sequenced
#    late in the sheet is represented too.
mapfile -t CHOSEN < <(awk -F'\t' -v max="$MAX_SAMPLES" -v layout="$READ_LAYOUT" '
    # n starts at 0 explicitly: an uninitialized awk variable subscripts an array
    # as "" rather than as 0, so the first sample would be stored out of reach
    BEGIN { n = 0; taken = 0 }
    NR > 1 { fq1[n] = $2; fq2[n] = (layout == "paired" ? $3 : ""); n++ }
    END {
        if (n == 0) exit
        if (max > n) max = n
        # Evenly spaced positions rather than a fixed stride, which collapses to
        # the first max samples whenever the sheet is shorter than twice max
        for (taken = 0; taken < max; taken++) {
            i = int(taken * n / max)
            print fq1[i] "\t" fq2[i]
        }
    }' "$SAMPLESHEET")

[[ ${#CHOSEN[@]} -gt 0 ]] || fail "No samples found in '$SAMPLESHEET'."

READS_PER_SAMPLE=$(( (MAX_READS_LONG + ${#CHOSEN[@]} - 1) / ${#CHOSEN[@]} ))

log "Scanning ${#CHOSEN[@]} $READ_LAYOUT-end samples for $READS_PER_SAMPLE reads each..."

# Read one FASTQ end to end: record every read's length for the platform call,
# and keep a uniform sample of READS_PER_SAMPLE reads as FASTA named
# "<mate>_<sample>_<n>", so the hit table can be split by mate again. The sample
# is held in a reservoir rather than taken from the file's head, which on ONT is
# its short reads. rand() is seeded so a second run measures the same reads.
sample_reads() {
    local file="$1" mate="$2" index="$3"

    pigz -p "$THREADS" -dc "$file" | awk \
        -v mate="$mate" -v sample_index="$index" -v want="$READS_PER_SAMPLE" \
        -v minlen="$MIN_READ_LENGTH" -v maxn="$MAX_AMBIGUOUS" \
        -v lengths="$LENGTHS_TXT" '
        BEGIN { srand(1) }
        NR % 4 != 2 { next }
        {
            if (length($0) < minlen) next
            print length($0) >> lengths

            seq = toupper($0)
            if (gsub(/N/, "N", seq) > maxn) next

            seen++
            if (seen <= want) {
                reservoir[seen] = seq
            } else {
                slot = int(rand() * seen) + 1
                if (slot <= want) reservoir[slot] = seq
            }
        }
        END {
            kept = (seen < want) ? seen : want
            for (i = 1; i <= kept; i++)
                printf ">%s_%s_%s\n%s\n", mate, sample_index, i, reservoir[i]
        }' >> "$SAMPLE_FASTA"
}

: > "$SAMPLE_FASTA"
: > "$LENGTHS_TXT"

INDEX=0
for pair in "${CHOSEN[@]}"; do
    FQ1=${pair%%$'\t'*}
    FQ2=${pair##*$'\t'}

    [[ -r "$FQ1" ]] || fail "Cannot read the FASTQ file for sampling: $FQ1"

    sample_reads "$FQ1" 1 "$INDEX"

    if [[ "$READ_LAYOUT" == "paired" ]]; then
        [[ -r "$FQ2" ]] || fail "Cannot read the FASTQ file for sampling: $FQ2"
        sample_reads "$FQ2" 2 "$INDEX"
    fi

    INDEX=$((INDEX + 1))
done

SCANNED_READS=$(wc -l < "$LENGTHS_TXT")

# 3. The platform, from how many of the run's reads are longer than any Illumina
#    instrument produces, and then the queries that follow from it.
read -r MEDIAN_LENGTH LONG_FRACTION < <(sort -n "$LENGTHS_TXT" \
    | awk -v threshold="$LONG_READ_THRESHOLD" '
        { length_of[NR] = $1; if ($1 > threshold) long++ }
        END {
            if (NR == 0) { print "0 0"; exit }
            printf "%d %.3f\n", length_of[int((NR + 1) / 2)], long / NR
        }')

if awk -v f="$LONG_FRACTION" -v m="$LONG_READ_FRACTION" 'BEGIN { exit !(f >= m) }'; then
    READ_SPAN="long"
else
    READ_SPAN="short"
fi

if [[ "$READ_LAYOUT" == "paired" && "$READ_SPAN" == "long" ]]; then
    REASON="What this run sequenced could not be determined: its reads are paired,"
    REASON+=" but $LONG_FRACTION of them are longer than $LONG_READ_THRESHOLD bases,"
    REASON+=" which no paired-end instrument produces."
    fail "$REASON"
fi

if [[ "$READ_LAYOUT" == "paired" ]]; then
    SEQUENCING_TYPE="illumina_pe"
elif [[ "$READ_SPAN" == "short" ]]; then
    SEQUENCING_TYPE="illumina_se"
else
    SEQUENCING_TYPE="nanopore"
fi

log "Reads are $READ_LAYOUT-end, median $MEDIAN_LENGTH bases, $LONG_FRACTION of them over $LONG_READ_THRESHOLD; calling them $SEQUENCING_TYPE."

#    Cut the aligner's queries out of that sample. A paired mate is cut to its
#    5' PROBE_LENGTH bases, since the 5' end is set by where the primer bound
#    while the 3' end moves with read length, quality trimming and adapter
#    read-through. Every other read is kept whole, since its far end is the only
#    account of where the amplicon stops. A long-read run puts more of the
#    sample in front of the aligner than a short-read one: it carries more
#    off-target material, so a wider sample is needed to find MIN_ALIGNED_READS
#    of 16S inside it.
QUERIES_PER_SAMPLE=$(( (MAX_READS_SHORT + ${#CHOSEN[@]} - 1) / ${#CHOSEN[@]} ))
[[ "$READ_SPAN" == "long" ]] && QUERIES_PER_SAMPLE=$READS_PER_SAMPLE

PROBE=0
[[ "$READ_LAYOUT" == "paired" ]] && PROBE=$PROBE_LENGTH

awk -v probe="$PROBE" -v want="$QUERIES_PER_SAMPLE" '
    /^>/ { name = $0; next }
    {
        split(substr(name, 2), part, "_")
        if (++taken[part[1] SUBSEP part[2]] > want) next
        print name
        print probe ? substr($0, 1, probe) : $0
    }' "$SAMPLE_FASTA" > "$READS_FASTA"

SAMPLED_READS=$(grep -c '^>' "$READS_FASTA" || true)

MINIMUM_SAMPLED=$MIN_ALIGNED_READS
[[ "$READ_LAYOUT" == "paired" ]] && MINIMUM_SAMPLED=$((MIN_ALIGNED_READS * 2))

if [[ "$SAMPLED_READS" -lt "$MINIMUM_SAMPLED" ]]; then
    REASON="What this run sequenced could not be determined: of the $SCANNED_READS"
    REASON+=" reads scanned, only $SAMPLED_READS were long enough to look at."
    fail "$REASON"
fi

# 4. Align the reads to the landmarks. --strand both, since which way a read
#    aligns is a property of the library rather than of the region.
#
#    A short query is a probe cut from inside the amplicon, so nearly all of it
#    is 16S and --query_cov can be strict. A long read is not: it still carries
#    its barcode and adapters, and often more than one copy of the amplicon, so
#    what is asked of it instead is that it cover a third of the gene. The
#    host-DNA products a 16S primer pair also amplifies carry the primer but not
#    the gene, and never reach that.
VSEARCH_COVERAGE="--query_cov 0.80"
[[ "$READ_SPAN" == "long" ]] && VSEARCH_COVERAGE="--query_cov 0.30 --target_cov 0.30"

VSEARCH_COMMAND="vsearch --usearch_global $PWD/$READS_FASTA --db $LANDMARKS"
VSEARCH_COMMAND+=" --id 0.60 $VSEARCH_COVERAGE --strand both"
VSEARCH_COMMAND+=" --maxaccepts 4 --maxrejects 64 --top_hits_only --maxhits 1"
VSEARCH_COMMAND+=" --threads $THREADS --quiet"
VSEARCH_COMMAND+=" --userout $PWD/$HITS_TSV --userfields query+target+qstrand+tilo+tihi+id"

log "Aligning $SAMPLED_READS reads to the 16S landmarks..."
if ! apptainer exec -B /data "$VSEARCH_CONTAINER" $VSEARCH_COMMAND; then
    fail "What this run sequenced could not be determined: the aligner failed."
fi

# 5. Translate every hit into E. coli numbering, and reduce each mate to four
#    medians: where its reads start and stop on the gene, and the same again for
#    only the reads on each strand. Which of those the amplicon's ends are read
#    from is decided below, since that depends on the layout.
MEASUREMENT=$(awk -F'\t' -v OFS='\t' -v snap="$MAX_POSITION_SNAP" '
    function sort_numeric(a, n,   i, j, t) {
        for (i = 2; i <= n; i++) {
            t = a[i]
            for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]
            a[j + 1] = t
        }
    }

    # The median of one of the four per-mate series, which are held flat in
    # series[mate, name, index] with their lengths in count[mate, name]
    function median(m, name,   values, i, n) {
        n = count[m, name]
        if (n == 0) return 0
        for (i = 1; i <= n; i++) values[i] = series[m, name, i]
        sort_numeric(values, n)
        return values[int((n + 1) / 2)]
    }

    function record(m, name, value) {
        series[m, name, ++count[m, name]] = value
    }

    # The E. coli position of one end of a hit, walking "step" bases at a time
    # into the landmark until a base with one is found. Bases inserted relative
    # to E. coli, and the ends soft-clipped when the landmark was aligned to it,
    # have no row in ecoli_positions.tsv, and a full-length amplicon ends in
    # exactly those. Returns 0 when there is none within snap bases.
    function ecoli(target, pos, step,   i) {
        for (i = 0; i <= snap; i++)
            if ((target SUBSEP (pos + i * step)) in position)
                return position[target SUBSEP (pos + i * step)]
        return 0
    }

    FILENAME == ARGV[1] { position[$1 SUBSEP $2] = $3; next }

    {
        target = $2; strand = $3; tilo = $4 + 0; tihi = $5 + 0

        lo = (tilo < tihi) ? tilo : tihi
        hi = (tilo < tihi) ? tihi : tilo

        lo = ecoli(target, lo, 1)
        hi = ecoli(target, hi, -1)

        if (lo == 0 || hi == 0 || lo >= hi) next

        mate = substr($1, 1, 1)
        aligned[mate]++

        # Target coordinates ascend whichever way the read aligned, so these two
        # are the amplicon-facing ends of every read regardless of strand
        record(mate, "lo", lo)
        record(mate, "hi", hi)

        # The end a read begins at on each strand, for telling paired mates apart
        if (strand == "+") { plus[mate]++;  record(mate, "start", lo) }
        else               { minus[mate]++; record(mate, "end", hi) }
    }

    END {
        for (m = 1; m <= 2; m++) {
            if (aligned[m] == 0) continue

            if (plus[m] >= minus[m]) {
                orientation[m] = "+"
                fraction[m] = plus[m] / aligned[m]
            } else {
                orientation[m] = "-"
                fraction[m] = minus[m] / aligned[m]
            }
        }

        for (m = 1; m <= 2; m++) {
            print "aligned_" m, aligned[m] + 0
            print "orientation_" m, orientation[m]
            print "strand_fraction_" m, fraction[m] + 0
            print "lo_" m, median(m, "lo")
            print "hi_" m, median(m, "hi")
            print "start_" m, median(m, "start")
            print "end_" m, median(m, "end")
        }
    }' "$POSITIONS" "$HITS_TSV")

declare -A M=()
while IFS=$'\t' read -r key value; do
    M["$key"]="$value"
done <<< "$MEASUREMENT"

ALIGNED_TOTAL=$(( ${M[aligned_1]:-0} + ${M[aligned_2]:-0} ))

log "Aligned $ALIGNED_TOTAL of $SAMPLED_READS reads."

# Why the alignment came up short, which is either that the run is too small to
# measure or that what it amplified is not 16S. Reported apart because they ask
# the requester for different things - more sequencing, or a look at the PCR.
report_too_few_aligned() {
    local scanned="Only $ALIGNED_TOTAL of $SAMPLED_READS reads, sampled evenly from the"
    scanned+=" $SCANNED_READS reads of ${#CHOSEN[@]} of this run's samples, align to 16S"

    REASON="The 16S region of this run's reads could not be determined."

    if awk -v a="$ALIGNED_TOTAL" -v s="$SAMPLED_READS" -v m="$MIN_ALIGNED_FRACTION" \
            'BEGIN { exit !(s > 0 && a / s >= m) }'; then
        REASON+=" $scanned, which is too few to measure an amplicon from even though"
        REASON+=" they are the share of 16S a run of this kind carries. This run is"
        REASON+=" too small to place: it needs to be sequenced deeper."
    else
        REASON+=" $scanned at all. That usually means most of what was amplified is"
        REASON+=" not 16S: a 16S primer pair also amplifies host DNA, and those"
        REASON+=" products carry the primers without the gene."
    fi

    fail "$REASON"
}

# 6. Read the amplicon's ends out of those medians, which is where the layout
#    stops being incidental. END_KNOWN is 0 for a run that can only measure the
#    end its reads begin at.
END_KNOWN=1

if [[ "$READ_LAYOUT" == "paired" ]]; then
    if [[ ${M[aligned_1]:-0} -lt $MIN_ALIGNED_READS || ${M[aligned_2]:-0} -lt $MIN_ALIGNED_READS ]]; then
        report_too_few_aligned
    fi

    # Both mates reading the same strand is not an amplicon library
    if [[ "${M[orientation_1]}" == "${M[orientation_2]}" ]]; then
        REASON="The 16S region of this run's reads could not be determined:"
        REASON+=" both mates align to the same strand of the gene, so the amplicon has no two ends."
        fail "$REASON"
    fi

    for mate in 1 2; do
        if ! awk -v f="${M[strand_fraction_$mate]}" -v m="$MIN_STRAND_FRACTION" \
                'BEGIN { exit !(f >= m) }'; then
            REASON="The 16S region of this run's reads could not be determined:"
            REASON+=" only ${M[strand_fraction_$mate]} of the R$mate reads agree on a strand,"
            REASON+=" so this looks like more than one library mixed together."
            fail "$REASON"
        fi
    done

    if [[ "${M[orientation_1]}" == "+" ]]; then
        OBSERVED_START=${M[start_1]}
        OBSERVED_END=${M[end_2]}
    else
        OBSERVED_START=${M[start_2]}
        OBSERVED_END=${M[end_1]}
    fi
else
    [[ ${M[aligned_1]:-0} -ge $MIN_ALIGNED_READS ]] || report_too_few_aligned

    if [[ "$READ_SPAN" == "long" ]]; then
        #    One read covers the whole amplicon, so its own ends are the answer
        OBSERVED_START=${M[lo_1]}
        OBSERVED_END=${M[hi_1]}
    elif [[ "${M[orientation_1]}" == "+" ]]; then
        #    Short single-end reads only reach the end they start at
        OBSERVED_START=${M[start_1]}
        OBSERVED_END=0
        END_KNOWN=0
    else
        OBSERVED_START=0
        OBSERVED_END=${M[end_1]}
        END_KNOWN=0
    fi
fi

if [[ "$END_KNOWN" -eq 1 ]]; then
    log "The amplicon runs from E. coli 16S position $OBSERVED_START to $OBSERVED_END."
    DRIFT_ALLOWED=$MAX_DRIFT
else
    log "The reads reach only one end of the amplicon, at E. coli 16S position $((OBSERVED_START + OBSERVED_END))."
    DRIFT_ALLOWED=$MAX_DRIFT_ONE_END
fi

# 7. Score every region in each of its four primer-trimming variants. A run with
#    one measurable end scores on that end alone.
BEST_REGION=""
BEST_LABEL=""
BEST_DISTANCE=0
RUNNERUP_LABEL=""
RUNNERUP_DISTANCE=0
SCORES=""

for entry in "${REGIONS[@]}"; do
    IFS='|' read -r id label fw_primer fw_position rv_primer rv_position <<< "$entry"

    region_distance=""
    region_fw=0
    region_rv=0

    for fw_present in 1 0; do
        for rv_present in 1 0; do
            expected_start=$fw_position
            expected_end=$rv_position

            [[ "$fw_present" -eq 0 ]] && expected_start=$((fw_position + ${#fw_primer}))
            [[ "$rv_present" -eq 0 ]] && expected_end=$((rv_position - ${#rv_primer}))

            distance=0

            if [[ "$END_KNOWN" -eq 1 || "$OBSERVED_START" -ne 0 ]]; then
                start_drift=$((OBSERVED_START - expected_start))
                distance=$((distance + ${start_drift#-}))
            fi

            if [[ "$END_KNOWN" -eq 1 || "$OBSERVED_END" -ne 0 ]]; then
                end_drift=$((OBSERVED_END - expected_end))
                distance=$((distance + ${end_drift#-}))
            fi

            if [[ -z "$region_distance" || "$distance" -lt "$region_distance" ]]; then
                region_distance=$distance
                region_fw=$fw_present
                region_rv=$rv_present
            fi
        done
    done

    SCORES+=$(printf '    %-18s %s..%s   off by %s' "$label" "$fw_position" "$rv_position" "$region_distance")
    SCORES+=$'\n'

    if [[ -z "$BEST_REGION" || "$region_distance" -lt "$BEST_DISTANCE" ]]; then
        RUNNERUP_LABEL=$BEST_LABEL
        RUNNERUP_DISTANCE=$BEST_DISTANCE
        BEST_REGION=$id
        BEST_LABEL=$label
        BEST_FW_PRIMER=$fw_primer
        BEST_RV_PRIMER=$rv_primer
        BEST_DISTANCE=$region_distance
        BEST_FW_PRESENT=$region_fw
        BEST_RV_PRESENT=$region_rv
    elif [[ -z "$RUNNERUP_LABEL" || "$region_distance" -lt "$RUNNERUP_DISTANCE" ]]; then
        RUNNERUP_LABEL=$label
        RUNNERUP_DISTANCE=$region_distance
    fi
done

# Where the amplicon was measured to be, for the messages below
if [[ "$END_KNOWN" -eq 1 ]]; then
    MEASURED="from position $OBSERVED_START to $OBSERVED_END of the 16S gene"
elif [[ "$OBSERVED_START" -ne 0 ]]; then
    MEASURED="from position $OBSERVED_START of the 16S gene, with its far end out of reach"
else
    MEASURED="to position $OBSERVED_END of the 16S gene, with its near end out of reach"
fi

if [[ "$BEST_DISTANCE" -gt "$DRIFT_ALLOWED" ]]; then
    REASON="The 16S region of this run's reads could not be determined."
    REASON+=" Its amplicon runs $MEASURED, which is not one of the regions this system supports:"
    REASON+=$'\n'"$(supported_regions)"
    fail "$REASON"
fi

if [[ $((RUNNERUP_DISTANCE - BEST_DISTANCE)) -lt "$MIN_MARGIN" ]]; then
    REASON="The 16S region of this run's reads could not be determined."
    REASON+=" Its amplicon, $MEASURED, fits $BEST_LABEL and $RUNNERUP_LABEL about equally well."

    if [[ "$END_KNOWN" -eq 0 ]]; then
        REASON+=$'\n'"Single-end reads this short only reach one end of the amplicon, which is not"
        REASON+=" always enough to tell two regions apart. Naming primer_fwd and primer_rev in"
        REASON+=" the request's pipeline arguments settles it."
    fi

    fail "$REASON"
fi

# 8. With only one end measured, both states of the far primer scored the same
#    and the winner is whichever the loop reached first. A library is trimmed at
#    both ends or at neither, so the end that was measured answers for both.
if [[ "$END_KNOWN" -eq 0 ]]; then
    if [[ "$OBSERVED_START" -ne 0 ]]; then
        BEST_RV_PRESENT=$BEST_FW_PRESENT
    else
        BEST_FW_PRESENT=$BEST_RV_PRESENT
    fi
fi

#    Both primers still on the reads means cutadapt has work to do; neither means
#    they were removed before the reads arrived.
if [[ "$BEST_FW_PRESENT" -eq 1 && "$BEST_RV_PRESENT" -eq 1 ]]; then
    SKIP_CUTADAPT="false"
    PRIMER_STATE="still on the reads, and are trimmed by the pipeline"
elif [[ "$BEST_FW_PRESENT" -eq 0 && "$BEST_RV_PRESENT" -eq 0 ]]; then
    SKIP_CUTADAPT="true"
    PRIMER_STATE="already removed before the reads arrived"
else
    SKIP_CUTADAPT="true"
    PRIMER_STATE="removed from one end only, which is unusual - check the reads"
    warn "Only one of the two primers appears to have been trimmed from these reads."
fi

printf '%s\n' "$BEST_REGION" > "$REGION_OUT"

{
    printf 'sequencing_type: "%s"\n' "$SEQUENCING_TYPE"
    printf 'primer_fwd: "%s"\n' "$BEST_FW_PRIMER"
    printf 'primer_rev: "%s"\n' "$BEST_RV_PRIMER"
    printf 'skip_cutadapt: %s\n' "$SKIP_CUTADAPT"

    # ampliseq would reach both of these from sequencing_type alone, since
    # asv_calling defaults to auto and savont_options to --fl-16s. Written out so
    # the run's record names them rather than relying on a default holding still.
    if [[ "$SEQUENCING_TYPE" == "nanopore" ]]; then
        printf 'asv_calling: "savont"\n'
        printf 'savont_options: "--fl-16s"\n'
    fi
} > "$PARAMS_OUT"

{
    printf 'What this run sequenced\n\n'
    printf '  Platform:   %s (%s-end, median read %s bases, %s of them over %s)\n' \
        "$SEQUENCING_TYPE" "$READ_LAYOUT" "$MEDIAN_LENGTH" \
        "$LONG_FRACTION" "$LONG_READ_THRESHOLD"
    printf '  Region:     %s (%s)\n' "$BEST_LABEL" "$BEST_REGION"
    printf '  Amplicon:   E. coli 16S, %s\n' "$MEASURED"
    printf '  Primers:    %s\n' "$PRIMER_STATE"
    printf '  primer_fwd: %s\n' "$BEST_FW_PRIMER"
    printf '  primer_rev: %s\n' "$BEST_RV_PRIMER"
    printf '\n'
    printf '  Reads scanned: %s across %s samples\n' "$SCANNED_READS" "${#CHOSEN[@]}"
    printf '  Reads sampled: %s, of which %s aligned to the 16S landmarks\n' \
        "$SAMPLED_READS" "$ALIGNED_TOTAL"
    printf '  R1 on the %s strand: %s of them\n' "${M[orientation_1]}" "${M[strand_fraction_1]}"

    if [[ "$READ_LAYOUT" == "paired" ]]; then
        printf '  R2 on the %s strand: %s of them\n' "${M[orientation_2]}" "${M[strand_fraction_2]}"
    fi

    printf '\n'
    printf '  Distance from each supported region, in bases:\n'
    printf '%s' "$SCORES"
} > "$REPORT"

NOTE="Measured from the reads: $BEST_LABEL on $SEQUENCING_TYPE, spanning E. coli 16S"
NOTE+=" $MEASURED. The primers were $PRIMER_STATE."

if [[ " $UNMERGEABLE_REGIONS " == *" $BEST_REGION "* && "$SEQUENCING_TYPE" == "illumina_pe" ]]; then
    NOTE+=$'\n'"Paired Illumina reads do not overlap across an amplicon this long, so DADA2"
    NOTE+=" will not be able to merge them."
fi

printf '%s\n' "$NOTE" >> notes.txt

log "Detected $BEST_LABEL ($BEST_REGION) on $SEQUENCING_TYPE, $BEST_DISTANCE bases from its expected coordinates."
