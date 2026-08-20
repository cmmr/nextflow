# taxprofiler

Shotgun metagenomic profiling with
[nf-core/taxprofiler](https://nf-co.re/taxprofiler) 2.0.1, running kraken2,
bracken and metaphlan over the same lab samplesheet the ampliseq pipelines take.

Everything here is taxprofiler-specific. For how a request becomes a run at all,
see the [README](../README.md).


## The pipeline

There is one taxprofiler pipeline, `TAXPROFILER`.

**It depletes against every common host at once — human, mouse, macaque and
PhiX in a single pass — rather than offering a choice per species.** One
combined reference costs a small amount of extra microbial loss — the genome
features that spuriously attract microbial reads are
conserved between mammals, so the union overlaps heavily rather than adding up —
and in exchange it deletes an entire failure mode: a mouse study can no longer
be depleted against a human genome with nothing in the report saying so. For a
pipeline chosen from a request-form dropdown, that trade is worth making.

If false positives ever become a real concern, masking the reference against
bacterial genomes buys back roughly an order of magnitude, which dwarfs the
difference between one host and three.

Adding a host means rebuilding the combined reference and pointing a new
`TAXPROFILER_02` at it, rather than adding a parallel pipeline.

`TAXPROFILER_01.sh` carries its full parameter set rather than sourcing a shared
base, the same trade the four 16S pipelines make: a run from a year ago still
reproduces exactly.


## The taxprofiler pre/post steps

[`taxprofiler_samplesheet.sh`](../scripts/taxprofiler_samplesheet.sh) turns the same
lab sheet into the six-column CSV taxprofiler wants — `sample`,
`run_accession`, `instrument_platform`, `fastq_1`, `fastq_2`, `fasta`. It differs
from the ampliseq converter in two ways that follow from what taxprofiler can do
for itself:

- **Duplicate sample names are not merged.** taxprofiler concatenates a sample's
  runs itself, after per-run QC, so entries sharing a sample name become separate
  rows numbered `run_1`, `run_2`, … The count in `sample_count.txt` is therefore
  *distinct samples*, not rows.
- **Every read is staged into `raw-sequences/`**, as
  `<sample>_<run>_{1,2}.fq.gz`. taxprofiler reads gzipped FASTQ only, so `.bz2`
  and plain FASTQ are recompressed; already-gzipped inputs are symlinked rather
  than copied, which is nearly free and is what the common WGS case hits.

`instrument_platform` is written as `ILLUMINA` unless the pipeline definition
sets `INSTRUMENT_PLATFORM`, which is what a long-read version would change.

[`taxprofiler_upload.sh`](../scripts/taxprofiler_upload.sh) mirrors the ampliseq
uploader: it zips `raw-sequences/` into the results folder (`zip -0` — the reads
are already compressed), indexes the results folders, copies them to
`s3://$AWS_S3_BUCKET/nxf/<uid>/`, renders
[`templates/taxprofiler/index.html`](../templates/taxprofiler/index.html) over
`multiqc/multiqc_report.html`, and writes the report URL to the Wrike custom
field.

**The reads archive is deliberate, and it is the bulk of what a WGS run
publishes.** Building it needs free space in the run directory equal to the
input volume, and the upload is that volume again over the wire; both land
inside `wrike_job.sh`'s 48-hour ceiling or the run fails with the profiling
already done.

Only the profile buttons are globbed, since those filenames carry the tool and
database names from `database.csv`:

| Button | Files |
|---|---|
| `raw-sequences.zip` | the reads `taxprofiler_samplesheet.sh` staged, zipped at upload |
| krona charts | `krona/*.html` — opened in a new tab rather than downloaded |
| taxpasta tables | `taxpasta/*.tsv` — one merged profile per tool and database |

### Host removal

Host depletion runs on Bowtie2 against a single combined reference built into
`db/hostremoval/`:

```
db/hostremoval/
  human_mouse_macaque_phix.fa             hostremoval_reference
  human_mouse_macaque_phix/               shortread_hostremoval_index
  human_mouse_macaque_phix.manifest.json  provenance
```

taxprofiler takes exactly one reference and one index — `hostremoval_reference`
is a single `file()` and the index channel is `.first()`-ed — so several
genomes become one reference by concatenation, not by supplying several
databases. It is also why PhiX cannot be added to a finished index: a bowtie2
index is an FM-index over the whole concatenated text, with no append or merge.

At 9.0 Gbp the combined reference is over bowtie2's 4.295 Gbp (2^32) small-index
threshold, so it builds a **large index** — `.bt2l` files, roughly 13 GB, and a
longer build. Both `BOWTIE2_ALIGN` and
[`build_host_reference.sh`](../scripts/build_host_reference.sh) detect either
format, so nothing else changes.

### Databases and resource limits

Profiling databases come from
[`config/taxprofiler/database.csv`](../config/taxprofiler/database.csv):

| tool | db_name | notes |
| --- | --- | --- |
| kraken2 | `pluspf_20260626` | RefSeq archaea, bacteria, viral, plasmid, human, UniVec_Core, protozoa, fungi |
| bracken | `pluspf_20260626` | same directory; `db_params` is `;-r 150` |
| metaphlan | `mpa_vJun23_CHOCOPhlAnSGB_202403` | newest database MetaPhlAn 4.1.1 accepts |

**Bracken's `db_params` must contain a semicolon**, which splits kraken2's
parameters from bracken's — `;-r 150` is default kraken2 settings with a 150 bp
read length. The PlusPF archive ships distributions for 50, 75, 100, 150, 200,
250 and 300-mers, so `-r` can be changed to any of those without rebuilding
anything.

`taxpasta_taxonomy_dir` points at the kraken2 database directory rather than a
separately downloaded taxdump: the PlusPF archive carries `nodes.dmp` and
`names.dmp`, and using the database's own taxonomy guarantees the taxon IDs
match by construction.

taxprofiler has its own
[`config/taxprofiler/slurm.config`](../config/taxprofiler/slurm.config) rather
than sharing `config/slurm.config`. taxprofiler 2.0.1 is built on the nf-core
3.x template, which dropped `params.max_cpus` / `max_memory` / `max_time` in
favour of `process.resourceLimits`; the `params` block in `config/slurm.config`
sets nothing taxprofiler reads.

Kraken2, MetaPhlAn and the host-depletion aligner are sized against the node
rather than left on nf-core's `process_high` label. 16 cpus each puts two of any
of them on a 32-core node with no cores stranded. Kraken2's memory is the figure
to watch: it reads `hash.k2d` into its own heap, and PlusPF's is roughly 90 GB.

Nothing copies a database. Nextflow stages inputs as absolute symlinks
(`stageInMode` defaults to `symlink`) and `scratch` copies only declared
*outputs* back, so every tool reads its database over the shared filesystem and
the first task on a node warms the page cache for the rest.


## Cluster setup

Everything taxprofiler reads is fetched fresh by the scripts below, even where a
copy already exists elsewhere on the cluster, so that every database a run
touches has a recorded origin. Each writes a `.manifest.json` beside its output
naming the source URLs, checksums and fetch date.

All of these are one-time steps. Submit them rather than running them on the
login node.

### Profiling databases

[`fetch_taxprofiler_db.sh`](../scripts/fetch_taxprofiler_db.sh) downloads a
database, verifies every file against the publisher's own checksums, and writes
the manifest. Versions are pinned as constants at the top of the script rather
than resolved to "latest".

```bash
sbatch --job-name=db-kraken2 --cpus-per-task=4 --mem=8G --time=24:00:00 --output=/data/prod/nextflow/log/db_%j.out /data/prod/nextflow/scripts/fetch_taxprofiler_db.sh kraken2
```

```bash
sbatch --job-name=db-metaphlan --cpus-per-task=4 --mem=8G --time=24:00:00 --output=/data/prod/nextflow/log/db_%j.out /data/prod/nextflow/scripts/fetch_taxprofiler_db.sh metaphlan
```

Kraken2 PlusPF is a 91 GB download that needs about 200 GB free while the
archive and the extracted copy coexist; the script checks before starting and
deletes the archive as soon as it has unpacked. MetaPhlAn is 26 GB across two
tars.

**MetaPhlAn is pinned deliberately.** Its own `mpa_latest` marker currently
names `mpa_vJan26_CHOCOPhlAnSGB_202605`, which needs MetaPhlAn 4.2 —
taxprofiler 2.0.1 pins 4.1.1, whose newest supported database is
`mpa_vJun23_CHOCOPhlAnSGB_202403`. Letting MetaPhlAn resolve `latest` would
fetch a database it cannot read. Moving past this needs a newer taxprofiler, not
a newer database.

### Building the host reference

[`build_host_reference.sh`](../scripts/build_host_reference.sh) takes a name and
one or more NCBI assembly accessions, downloads each, verifies it against NCBI's
`md5checksums.txt`, concatenates them into one FASTA, builds the bowtie2 index,
and writes the manifest. Accessions are resolved against NCBI's directory
listing, since the FTP path carries the assembly name as well as the accession.

| Component | Accession | Assembly | Size |
| --- | --- | --- | --- |
| human | `GCF_009914755.1` | T2T-CHM13v2.0 | 3.117 Gbp |
| mouse | `GCF_000001635.27` | GRCm39 | 2.728 Gbp |
| macaque | `GCF_049350105.2` | T2T-MMU8v2.0 | 3.115 Gbp |
| PhiX | `GCF_000819615.1` | ViralProj14015 | 5.4 kbp |

Mouse and macaque are NCBI's current reference assemblies for their taxa.
Human is the deliberate exception: NCBI still designates GRCh38.p14 the
reference for annotation continuity, but T2T-CHM13v2.0 is gapless and therefore
captures the centromeric and satellite reads GRCh38 lets through to be
misclassified as microbial. Host reads are discarded rather than analysed, so
completeness is what matters.

```bash
sbatch --job-name=ref-hostmix --cpus-per-task=32 --mem=128G --time=48:00:00 --output=/data/prod/nextflow/log/ref_%j.out /data/prod/nextflow/scripts/build_host_reference.sh human_mouse_macaque_phix GCF_009914755.1 GCF_000001635.27 GCF_049350105.2 GCF_000819615.1
```

An existing reference is never overwritten; remove `<name>.fa` and `<name>/` to
rebuild.

### Checking what was built

```bash
ls -lh /data/prod/nextflow/db/hostremoval/*/ && jq -r '.name, (.sources[].url)' /data/prod/nextflow/db/*/*.manifest.json /data/prod/nextflow/db/hostremoval/*.manifest.json
```

A bowtie2 index is six files — `.1` through `.4` plus `.rev.1` and `.rev.2`,
with an `l` suffix on the large index. `build_host_reference.sh` fails rather
than reporting success if `.rev.1.bt2*` is missing, since that is the file
`BOWTIE2_ALIGN` globs for.
