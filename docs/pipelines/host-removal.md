# Removing human reads

A quick way to remove human reads from paired shotgun reads using KneadData's
method. There are two scripts here that do the same job: one runs KneadData and
the other runs Bowtie2 directly. Both take the same arguments and leave the same
files behind.

| What | Version |
| --- | --- |
| Human reference | **T2T-CHM13v2.0** ([GCF_009914755.1](https://www.ncbi.nlm.nih.gov/datasets/genome/GCF_009914755.1/)) |
| Aligner | Bowtie2 **2.5.4**, `--very-sensitive-local` |
| KneadData (option 1) | **0.12.4** |
| A pair is removed when | either mate aligns to the reference |


## Apptainer

Every tool runs from a container image through
[Apptainer](https://apptainer.org/docs/user/latest/). Most clusters have it
already installed or as a module; check with:

```bash
apptainer --version
```

If it is missing, its [install guide](https://apptainer.org/docs/admin/latest/installation.html)
covers each platform. Apptainer mounts your home directory, the current
directory and `/tmp` inside the container. Reads or a database stored anywhere
else need `-B <path>` on `apptainer exec`, or the same paths in `APPTAINER_BIND`.


## The chm13v2 database

A Bowtie2 index over T2T-CHM13v2.0. It is built once and used by both scripts.

Pull the Bowtie2 image, which provides `bowtie2-build`:

```bash
apptainer pull bowtie2.sif docker://community.wave.seqera.io/library/bowtie2_htslib_samtools_pigz:edeb13799090a2a6
```

Download the genome from NCBI, check it against NCBI's checksum, and index it:

```bash
URL=https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/009/914/755/GCF_009914755.1_T2T-CHM13v2.0
NAME=GCF_009914755.1_T2T-CHM13v2.0_genomic.fna.gz

curl -fsS -O "$URL/$NAME"
curl -fsS "$URL/md5checksums.txt" | grep " ./$NAME$" | sed 's| \./| |' | md5sum -c -

gzip -cd "$NAME" > chm13v2.fa

mkdir chm13v2
apptainer exec bowtie2.sif bowtie2-build --threads 32 chm13v2.fa chm13v2/chm13v2
```

The FASTA is about 3 GB and the index in `chm13v2/` about 4 GB. Building it with 32 CPUs and 64 GB of memory takes an hour or two. Once
`chm13v2/` exists, `chm13v2.fa` and the `.fna.gz` download can be deleted.

Both scripts look for the index in `./chm13v2`. To keep it somewhere else, set
`DB` to its folder, e.g. `export DB=/data/db/chm13v2`.


## Option 1: KneadData

Pull KneadData 0.12.4, which includes Bowtie2 2.5.4:

```bash
apptainer pull kneaddata.sif docker://quay.io/biocontainers/kneaddata:0.12.4--pyhdfd78af_0
```

Save this as `decontam_kneaddata.sh`:

```bash
#!/bin/bash
# Usage: decontam_kneaddata.sh <fq1> <fq2> [out] [cpus]
#
# Removes human reads from one sample's paired FASTQ files with KneadData. The
# Bowtie2 index is read from the folder $DB, ./chm13v2 by default.
set -euo pipefail

fq1=$1 fq2=$2 out=${3:-.} cpus=${4:-1}
db=${DB:-chm13v2}

# S1_R1.fastq.gz, S1_R1_001.fastq.gz and S1_1.fq.gz are all sample S1
sample=$(basename "$fq1" | sed -E 's/\.(fastq|fq)(\.gz)?$//; s/_R?1(_001)?$//')
prefix=${sample}_decontam

mkdir -p "$out"
tmp=$(mktemp -d "$out/.$prefix.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

kneaddata --input1 "$fq1" --input2 "$fq2" --reference-db "$db" \
    --output "$tmp" --output-prefix "$sample" --threads "$cpus" \
    --bypass-trim --bypass-trf --decontaminate-pairs strict --reorder

# KneadData writes uncompressed FASTQ; its image has gzip but not pigz
if command -v pigz > /dev/null; then
    compress="pigz -p $cpus -c"
else
    compress="gzip -c"
fi

for mate in 1 2; do
    $compress "$tmp/${sample}_paired_$mate.fastq" > "$out/${prefix}_$mate.fq.gz"
    (cd "$out" && md5sum "${prefix}_$mate.fq.gz" > "${prefix}_$mate.fq.gz.md5")
done

# Pairs before and after, from KneadData's log
awk -F ': ' -v OFS='\t' -v sample="$sample" '
    /READ COUNT: raw pair1 /   { input = $NF }
    /READ COUNT: final pair1 / { kept = $NF }
    END {
        print "sample", "pairs_input", "pairs_kept", "pairs_dropped"
        printf "%s\t%d\t%d\t%d\n", sample, input, kept, input - kept
    }
' "$tmp/$sample.log" > "$out/${prefix}_counts.tsv"
```

Run it on one sample:

```bash
apptainer exec kneaddata.sif bash decontam_kneaddata.sh S1_R1.fastq.gz S1_R2.fastq.gz results 16
```

`--bypass-trim` and `--bypass-trf` turn off KneadData's trimming and tandem
repeat steps, so host removal is all it does. `--reorder` keeps the reads in
input order, so the same input always gives the same files and checksums.

KneadData works in a hidden temporary folder inside `out`, which the script
deletes when it finishes. While it runs, that folder holds an uncompressed copy
of the sample, then a second copy with renamed reads, then the human and
non-human reads it splits them into, so it needs several times the sample's
uncompressed size in free space. KneadData has no option to skip writing the
human reads.

KneadData also renames every read to its first word plus `#0/1` or `#0/2`:
`@A00123:8:H5:1:1101:1000:2000 1:N:0:ACGT` comes out as
`@A00123:8:H5:1:1101:1000:2000#0/1`.


## Option 2: Bowtie2 directly

Pull Bowtie2 2.5.4, with pigz (skip this if you already pulled it to build the
database):

```bash
apptainer pull bowtie2.sif docker://community.wave.seqera.io/library/bowtie2_htslib_samtools_pigz:edeb13799090a2a6
```

Save this as `decontam_bowtie2.sh`:

```bash
#!/bin/bash
# Usage: decontam_bowtie2.sh <fq1> <fq2> [out] [cpus]
#
# Removes human reads from one sample's paired FASTQ files with Bowtie2. The
# Bowtie2 index is read from the folder $DB, ./chm13v2 by default.
set -euo pipefail

fq1=$1 fq2=$2 out=${3:-.} cpus=${4:-1}
db=${DB:-chm13v2}

# S1_R1.fastq.gz, S1_R1_001.fastq.gz and S1_1.fq.gz are all sample S1
sample=$(basename "$fq1" | sed -E 's/\.(fastq|fq)(\.gz)?$//; s/_R?1(_001)?$//')
prefix=${sample}_decontam

# The index's name, from the one *.rev.1.bt2 file in the folder
index=$(ls "$db"/*.rev.1.bt2* | head -n 1)
index=${index%.rev.1.bt2*}

mkdir -p "$out"
tmp=$(mktemp -d "$out/.$prefix.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Each read as one line of its four, a pair's two mates on one line
pairs() {
    paste <(gzip -cdf "$fq1" | paste - - - -) <(gzip -cdf "$fq2" | paste - - - -)
}

# Bowtie2 over every pair, or over the pairs a flags file marks 1, with each
# mate aligned on its own. Writes a flags file of one line per pair, in input
# order: 1 when neither mate aligned.
align() {
    local flags=$1 result=$2
    shift 2

    pairs \
        | awk -F '\t' -v flags="$flags" '
            flags != "" { getline keep < flags; if (keep != 1) next }
            { for (i = 1; i <= NF; i++) print $i }
        ' \
        | bowtie2 -p "$cpus" --reorder --no-hd -x "$index" -U - "$@" \
        | cut -f 2 \
        | awk 'NR % 2 { first = int($1 / 4) % 2; next } { print (first && int($1 / 4) % 2) }' \
        > "$result"
}

# A quick end-to-end pass over every pair, then KneadData's own
# --very-sensitive-local over only the pairs it left
align "" "$tmp/pass1" --fast
align "$tmp/pass1" "$tmp/pass2" --very-sensitive-local

# 1 for the pairs both passes left
awk -v second="$tmp/pass2" '
    $1 == 1 { getline keep < second; print keep; next }
    { print 0 }
' "$tmp/pass1" > "$tmp/keep"

# Each mate's records for the pairs kept, unchanged
for mate in 1 2; do
    reads=$fq1
    [ "$mate" = 2 ] && reads=$fq2

    paste "$tmp/keep" <(gzip -cdf "$reads" | paste - - - -) \
        | awk -F '\t' '$1 == 1 { print $2; print $3; print $4; print $5 }' \
        | pigz -p "$cpus" > "$out/${prefix}_$mate.fq.gz"

    (cd "$out" && md5sum "${prefix}_$mate.fq.gz" > "${prefix}_$mate.fq.gz.md5")
done

awk -v OFS='\t' -v sample="$sample" '
    { input++; kept += $1 }
    END {
        print "sample", "pairs_input", "pairs_kept", "pairs_dropped"
        print sample, input + 0, kept + 0, input - kept
    }
' "$tmp/keep" > "$out/${prefix}_counts.tsv"
```

Run it on one sample:

```bash
apptainer exec bowtie2.sif bash decontam_bowtie2.sh S1_R1.fastq.gz S1_R2.fastq.gz results 16
```

**It runs the same commands as option 1, and keeps the same pairs.** KneadData's
host removal is Bowtie2 2.5.4 with `--very-sensitive-local`, with each mate
aligned on its own and a pair removed if either mate aligns
(`--decontaminate-pairs strict`). This script runs that same Bowtie2 command
itself.

**It runs much faster, for three reasons:**

- **A quick first pass.** A `--fast` end-to-end pass runs over every read first,
  and the slow `--very-sensitive-local` pass only sees the pairs it couldn't
  place. A read that aligns end to end also aligns locally, so this changes how
  long it takes, not which pairs are kept. The more human a sample is, the more
  time it saves. On one sample that was 99.9% human, KneadData spent 13 hours on
  host removal; with the first pass in front, the slow pass gets only the small
  fraction of reads the quick one couldn't place.
- **No copies of the reads.** The gzipped files are streamed straight into
  Bowtie2. On disk there is only a few bytes per pair, plus the compressed
  output.
- **Parallel compression.** The output is compressed with pigz on every CPU,
  where KneadData's image only has single-threaded gzip.

The reads it keeps are the input records, byte for byte, original names
included.


## What both leave behind

For a sample `S1`, in `out`:

```
S1_decontam_1.fq.gz        mate 1 of every pair with no human read
S1_decontam_2.fq.gz        mate 2 of those pairs, in the same order
S1_decontam_1.fq.gz.md5    md5sum of each, checked with md5sum -c
S1_decontam_2.fq.gz.md5
S1_decontam_counts.tsv     pairs in, kept and dropped
```

```
sample	pairs_input	pairs_kept	pairs_dropped
S1	400	100	300
```

The sample name comes from `fq1`'s file name, without `.fastq.gz` or `.fq.gz`
and then without `_R1_001`, `_R1` or `_1`.

**Many samples** run one script call each. With a `samples.txt` that lists one
sample name per line, four at a time:

```bash
xargs -P 4 -I {} apptainer exec bowtie2.sif bash decontam_bowtie2.sh {}_R1.fastq.gz {}_R2.fastq.gz results 8 < samples.txt
```

Each sample's counts can be joined into one table, keeping one header:

```bash
awk 'FNR > 1 || NR == 1' results/*_decontam_counts.tsv > results/counts.tsv
```
