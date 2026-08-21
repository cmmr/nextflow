# taxprofiler

Shotgun metagenomic profiling with
[nf-core/taxprofiler](https://nf-co.re/taxprofiler) 2.0.1, running kraken2,
bracken and metaphlan over the same lab samplesheet the ampliseq pipelines take.

Everything here is taxprofiler-specific. For how a request becomes a run at all,
see the [README](../README.md).


## The pipeline variants

Three pipelines share one pair of scripts and one database sheet, and differ
only in which host genome their reads are depleted against:

| Pipeline | Depleted against | Reference |
| --- | --- | --- |
| `TAXPROFILER` | PhiX only | `phix` |
| `TAXPROFILER_HUMAN` | human + PhiX | `chm13v2phix` |
| `TAXPROFILER_MOUSE` | mouse + PhiX | `grcm39phix` |

Every variant strips PhiX, since the Illumina spike-in is never part of the
sample and PlusPF contains viral genomes that would otherwise classify it.

**The split is deliberate, and the reason is the methods section.** One combined
mammalian reference would be marginally more robust to a requester picking the
wrong variant — the features that spuriously attract microbial reads are largely
shared between mammals, so depleting against several costs little. But it would
also mean reporting that an environmental sample had been depleted against human
and mouse, which is not a claim worth defending to a reviewer. Host depletion
should name the host the sample came from.

The cost is that **picking the wrong variant fails quietly**: a mouse study run
through `TAXPROFILER_HUMAN` is depleted against the wrong genome and nothing in
the report says so. That is an operator choice recorded on the Wrike task, which
is a better place for it than buried in a reference nobody reads.

Adding a host is a new `TAXPROFILER_<host>` plus one reference build, and
touches none of the pipelines already defined.

Each `_01` file carries its full parameter set rather than sourcing a shared
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
- **Both paired and single-end input are accepted.** A line is
  `sample fastq_1 fastq_2` or `sample fastq_1`. A sample's runs must all be one
  or the other, which is what taxprofiler's own cross-row check enforces, so a
  sample that mixes them is rejected here with a clearer message.
- **`instrument_platform` is measured, not declared.** taxprofiler acts on it
  for exactly one decision — short-read path or long-read path — so the median
  read length answers it directly: above 1000 bp is `OXFORD_NANOPORE`, anything
  else `ILLUMINA`. No Illumina instrument reaches 1000 bp. A header format would
  have been the obvious signal and is the worse one, since SRA round-trips and
  read-renaming tools erase it. Setting `INSTRUMENT_PLATFORM` in the environment
  pins the value and skips detection, e.g. for `PACBIO_SMRT`. Long reads
  presented as a pair are rejected: taxprofiler errors on a long-read row that
  names a second FASTQ, and paired long reads do not exist.
- **Sample names are kept as submitted wherever possible.** taxprofiler forbids
  only whitespace in a sample name, but the name ends up in output filenames
  that reach unquoted shell contexts inside the nf-core modules, so anything
  outside `[A-Za-z0-9._-]` becomes an underscore and a leading dash is prefixed.
  Dots and dashes survive, so `P3.stool.T1` and `Sample-01` reach the report as
  submitted. Each rename is logged. This is looser than the ampliseq converter,
  which has to satisfy ampliseq's own stricter rule.
- **Bracken's read length is measured, not assumed** — see
  [Databases and resource limits](#databases-and-resource-limits).
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

Host depletion runs on Bowtie2 against one reference per variant, built into
`db/hostremoval/`:

```
db/hostremoval/
  <name>.fa             hostremoval_reference
  <name>/               shortread_hostremoval_index   (bowtie2)
  <name>.mmi            longread_hostremoval_index    (minimap2, -x map-ont)
  <name>.manifest.json  provenance
```

built for `phix`, `chm13v2phix` and `grcm39phix`. **Both indexes are built for
every reference**, because the platform is read from the data rather than from
the pipeline, so either path may be taken on any run. The minimap2 index is a
file rather than a directory, which is what `longread_hostremoval_index`
expects, and `-x map-ont` matches what taxprofiler's own `MINIMAP2_INDEX` would
have produced — an `.mmi` is only valid for the preset it was built with.

taxprofiler takes exactly one reference and one index — `hostremoval_reference`
is a single `file()` and the index channel is `.first()`-ed — so a host plus
PhiX is one concatenated reference rather than two databases. It is also why
PhiX cannot be added to a finished index: a bowtie2 index is an FM-index over
the whole concatenated text, with no append or merge, so adding anything means
rebuilding. Including PhiX at build time is free either way, at 5.4 kbp against
3 Gbp.

Each reference stays under bowtie2's 4.295 Gbp small-index threshold, so all
three build ordinary `.bt2` files. `BOWTIE2_ALIGN` finds the basename itself
with `find -L ./ -name "*.rev.1.bt2"`, so an index only has to be alone in its
directory; the name is free.

### Databases and resource limits

Profiling databases come from
[`config/taxprofiler/database.csv`](../config/taxprofiler/database.csv):

| tool | db_name | notes |
| --- | --- | --- |
| kraken2 | `pluspf_20260626` | RefSeq archaea, bacteria, viral, plasmid, human, UniVec_Core, protozoa, fungi. `db_type` is `short;long` |
| bracken | `pluspf_20260626` | same directory; `db_params` is `;-r 150` |
| metaphlan | `mpa_vJun23_CHOCOPhlAnSGB_202403` | newest database MetaPhlAn 4.1.1 accepts |

**Bracken's `db_params` must contain a semicolon**, which splits kraken2's
parameters from bracken's. That is the only part of the field that is required —
`db_params` is empty on the other two rows.

**The `-r 150` in that file is only a fallback.** Bracken's read length is
measured per run rather than assumed: `taxprofiler_samplesheet.sh` samples the
staged R1 files, takes the modal read length, picks the closest
`databaseNNNmers.kmer_distrib` the Kraken2 database actually ships, and writes
`taxprofiler_database.csv` into the run directory with that `-r`. The pipeline
names *that* sheet, not this one.

PlusPF carries distributions for 50, 75, 100, 150, 200, 250 and 300-mers, so
selection has something to choose from; with a single distribution the step is a
no-op. Anything before the semicolon is kraken2's and is copied through
untouched, as are any bracken flags other than `-r`.

A read length more than 15% away from the closest available distribution is
warned about on the Wrike task — relative rather than absolute, because 15 bp
off matters at 35 bp reads and does not at 250 bp. Every failure in this step
falls back to the sheet as written: a run is still worth doing with the recorded
default.

**The generated sheet is the record of what ran**, carrying the exact database
names, paths and parameters, so `taxprofiler_upload.sh` copies it into the
results beside the `nextflow_command.sh` and `taxprofiler_args.yaml` that
`wrike_job.sh` puts there. The run directory is deleted once a run succeeds, so
a sheet that is not copied is gone.

The input samplesheet is deliberately left behind: it names the requester's own
paths on the cluster, and unlike the database sheet it says nothing about how
the numbers were produced.

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

### Building the host references

[`build_host_reference.sh`](../scripts/build_host_reference.sh) takes a name and
one or more NCBI assembly accessions, downloads each, verifies it against NCBI's
`md5checksums.txt`, concatenates them into one FASTA, builds the bowtie2 index,
and writes the manifest. Accessions are resolved against NCBI's directory
listing, since the FTP path carries the assembly name as well as the accession.

| Reference | Accessions |
| --- | --- |
| `phix` | `GCF_000819615.1` — Escherichia phage phiX174, 5.4 kbp |
| `chm13v2phix` | `GCF_009914755.1` (T2T-CHM13v2.0, 3.117 Gbp) + PhiX |
| `grcm39phix` | `GCF_000001635.27` (GRCm39, 2.728 Gbp) + PhiX |

GRCm39 is NCBI's current reference assembly for mouse. Human is the deliberate
exception: NCBI still designates GRCh38.p14 the human reference for annotation
continuity, but T2T-CHM13v2.0 is gapless and therefore captures the centromeric
and satellite reads GRCh38 lets through to be misclassified as microbial. Host
reads are discarded rather than analysed, so completeness is what matters.

PhiX alone takes seconds; either mammalian genome takes one to two hours and
produces roughly 4 GB of index.

```bash
sbatch --job-name=ref-phix --cpus-per-task=32 --mem=64G --time=12:00:00 --output=/data/prod/nextflow/log/ref_%j.out /data/prod/nextflow/scripts/build_host_reference.sh phix GCF_000819615.1
```

```bash
sbatch --job-name=ref-chm13v2phix --cpus-per-task=32 --mem=64G --time=12:00:00 --output=/data/prod/nextflow/log/ref_%j.out /data/prod/nextflow/scripts/build_host_reference.sh chm13v2phix GCF_009914755.1 GCF_000819615.1
```

```bash
sbatch --job-name=ref-grcm39phix --cpus-per-task=32 --mem=64G --time=12:00:00 --output=/data/prod/nextflow/log/ref_%j.out /data/prod/nextflow/scripts/build_host_reference.sh grcm39phix GCF_000001635.27 GCF_000819615.1
```

Adding a host later is one more invocation plus a `TAXPROFILER_<host>` pair;
neither touches an existing pipeline or reference.

An existing reference is never overwritten; remove `<name>.fa` and `<name>/` to
rebuild.

### Checking what was built

```bash
ls -lh /data/prod/nextflow/db/hostremoval/*/ && jq -r '.name, (.sources[].url)' /data/prod/nextflow/db/*/*.manifest.json /data/prod/nextflow/db/hostremoval/*.manifest.json
```

A bowtie2 index is six files — `.1` through `.4` plus `.rev.1` and `.rev.2`.
`build_host_reference.sh` fails rather
than reporting success if `.rev.1.bt2*` is missing, since that is the file
`BOWTIE2_ALIGN` globs for.
