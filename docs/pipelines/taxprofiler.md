# taxprofiler

Shotgun metagenomic profiling with
[nf-core/taxprofiler](https://nf-co.re/taxprofiler), running kraken2, bracken and
metaphlan over the same lab samplesheet the ampliseq pipeline takes.

Everything here is taxprofiler-specific. For how a request becomes a run at all,
see the [README](../index.md).


## Versions in use

| Component | Version | Where |
| --- | --- | --- |
| nf-core/taxprofiler | **2.0.1** | pinned in `pipelines/TAXPROFILER_01.sh`, by the commit the tag points at |
| Kraken2 database | **PlusPF 2026-06-26** | `db/kraken2/pluspf_20260626` (111 GB) |
| Bracken distributions | 50, 75, 100, 150, 200, 250, 300-mers | same directory |
| MetaPhlAn database | **mpa_vJun23_CHOCOPhlAnSGB_202403** | `db/metaphlan/…` (33 GB) |
| Host — none | PhiX only (`GCF_000819615.1`) | `db/hostremoval/phix` |
| Host — human | T2T-CHM13v2.0 (`GCF_009914755.1`) + PhiX | `db/hostremoval/chm13v2phix` (14 GB) |
| Host — mouse | GRCm39 (`GCF_000001635.27`) + PhiX | `db/hostremoval/grcm39phix` (13 GB) |

Tool versions come from taxprofiler 2.0.1 and are not ours to choose: kraken2
2.1.5, bracken 3.1, metaphlan 4.1.1. The bowtie2 and minimap2 builds used for the
host references are recorded in each reference's `manifest.json`.

Every database was fetched fresh by the scripts in
[Cluster setup](#cluster-setup) rather than reused from elsewhere on the cluster,
and each carries a `manifest.json` naming its source URLs, checksums and fetch
date.

**Two pins are deliberate and should not be bumped casually:**

- **MetaPhlAn's database.** Its own `mpa_latest` marker names
  `mpa_vJan26_CHOCOPhlAnSGB_202605`, which requires MetaPhlAn 4.2. taxprofiler
  2.0.1 pins 4.1.1, whose newest supported database is the one above. Moving
  forward needs a newer taxprofiler, not a newer database.
- **Kraken2's memory reservation** in
  [`config/taxprofiler/slurm.config`](../../config/taxprofiler/slurm.config) tracks
  the size of `hash.k2d`, currently 110 GB. A reservation below it is an OOM
  kill, not a slow run — re-check on any database update.


## The pipeline

One pipeline, `TAXPROFILER`. Choosing it on the request form asks a follow-up
question — which host to deplete against — and the answer is what
[`TAXPROFILER_01.sh`](../../pipelines/TAXPROFILER_01.sh) turns into a reference:

| Answer | Depleted against | Reference |
| --- | --- | --- |
| `None` | nothing; host removal is skipped | — |
| `PhiX` | PhiX only | `phix` |
| `Human + PhiX` | T2T-CHM13v2.0 + PhiX | `chm13v2phix` |
| `Mouse + PhiX` | GRCm39 + PhiX | `grcm39phix` |

The pipeline reads it with `form_answer host`, lowercases it and takes the first
word, so `Human + PhiX` arrives at `chm13v2phix`. An unanswered question means
`PhiX`. The answer was already checked against the four the form offers, so an
unrecognized one means those two lists have drifted apart.

**Every depleting answer also strips PhiX**, since the Illumina spike-in is never
part of the sample and PlusPF contains viral genomes that would otherwise
classify it. `None` is the exception, and means exactly that.

**One combined mammalian reference is deliberately not offered.** It would be
more robust to a requester answering wrongly — the features that spuriously
attract microbial reads are largely shared between mammals, so depleting against
several costs little. But it would also mean reporting that an environmental
sample had been depleted against human *and* mouse, which is not a claim worth
defending to a reviewer.

The cost is that **answering wrongly fails quietly**: a mouse study depleted
against human is depleted against the wrong genome and nothing in the report says
so. The answer is recorded on the Wrike task and in the run's
`pipeline_manifest.json`, which is a better place for it than buried in a
reference nobody reads.

Adding a host is one `case` arm plus one reference build. The resolved reference
paths land in `taxprofiler_args.yaml` and in the manifest, so a
[rerun](index.md#reproducing-an-earlier-run) reproduces the host that was used
rather than re-reading the question.


## Preparing a run

[`taxprofiler_samplesheet.sh`](../../scripts/taxprofiler_samplesheet.sh) turns the
lab sheet into the six-column CSV taxprofiler wants — `sample`, `run_accession`,
`instrument_platform`, `fastq_1`, `fastq_2`, `fasta`.

- **Paired and single-end input are both accepted.** A line is
  `sample fastq_1 fastq_2` or `sample fastq_1`. A sample's runs must all be one
  or the other, which is what taxprofiler's own cross-row check enforces, so a
  sample that mixes them is rejected here with a clearer message.
- **Repeated sample names become runs, not merged files.** Rows sharing a sample
  name are numbered `run_1`, `run_2`, … in the `run_accession` column, and the
  pipelines set `perform_runmerging`, so taxprofiler concatenates them itself
  *after* per-run QC and host removal. One profile per sample, with per-run fastp
  and Bowtie2 statistics still reaching MultiQC — so a bad lane is still visible.
  Merging is what makes `sample_count.txt` (distinct samples, not rows) match the
  number of columns in the profile tables.

  **`perform_runmerging` defaults to off**, and without it every run is profiled
  separately: a two-lane sample lands in the taxpasta tables as `<sample>_run_1`
  and `<sample>_run_2`, two half-depth columns rather than one.
- **`instrument_platform` is measured, not declared.** taxprofiler acts on it for
  exactly one decision — short-read path or long-read path — so the median read
  length answers it directly: above 1000 bp is `OXFORD_NANOPORE`, anything else
  `ILLUMINA`. No Illumina instrument reaches 1000 bp. A header format would have
  been the obvious signal and is the worse one, since SRA round-trips and
  read-renaming tools erase it. `INSTRUMENT_PLATFORM` in the environment pins the
  value and skips detection, e.g. for `PACBIO_SMRT`. Long reads presented as a
  pair are rejected, since taxprofiler errors on a long-read row that names a
  second FASTQ.
- **Sample names are kept as submitted wherever possible.** taxprofiler forbids
  only whitespace, but the name ends up in output filenames that reach unquoted
  shell contexts inside the nf-core modules, so anything outside `[A-Za-z0-9._-]`
  becomes an underscore and a leading dash is prefixed. `P3.stool.T1` and
  `Sample-01` reach the report as submitted. Each rename is logged.
- **Every read is staged into `raw-sequences/`** as `<sample>_<run>_{1,2}.fq.gz`.
  taxprofiler reads gzipped FASTQ only, so `.bz2` and plain FASTQ are
  recompressed; already-gzipped inputs are symlinked rather than copied, which is
  nearly free and is what the common WGS case hits.
- **Bracken's read length is measured**, not assumed — see
  [Databases](#databases).

[`taxprofiler_upload.sh`](../../scripts/taxprofiler_upload.sh) mirrors the ampliseq
uploader: it zips `raw-sequences/` into the results folder (`zip -0` — the reads
are already compressed), indexes the results folders, copies them to
`s3://$AWS_S3_BUCKET/nxf/<uid>/`, renders the shared
[dashboard](../results/index.md) over `multiqc/multiqc_report.html`, and writes
the report URL to the Wrike custom field. What its file index lists is
[`templates/taxprofiler/outputs.conf`](../../templates/taxprofiler/outputs.conf).

**The reads archive is the bulk of what a WGS run publishes.** Building it needs
free space in the run directory equal to the input volume, and the upload is that
volume again over the wire; both land inside `wrike_job.sh`'s 48-hour ceiling or
the run fails with the profiling already done.

The page's buttons are globbed, since those filenames carry the tool and database
names from the database sheet:

| Button | Files |
|---|---|
| `raw-sequences.zip` | the staged reads, zipped at upload |
| krona charts | `krona/*.html` — one per tool and database |
| taxpasta tables | `taxpasta/*.tsv` — one merged profile per tool and database |

Only the archive downloads; the charts and the tables open in a tab, which is
what [their content types](../results/index.md#what-a-link-does-when-you-click-it)
are set at upload to allow.


## Host removal

Bowtie2 for short reads, minimap2 for long. Each reference is built into
`db/hostremoval/` as four artifacts:

```
<name>.fa             hostremoval_reference
<name>/               shortread_hostremoval_index   (bowtie2)
<name>.mmi            longread_hostremoval_index    (minimap2, -x map-ont)
<name>.manifest.json  provenance
```

**Both indexes are built for every reference**, because the platform is read from
the data rather than from the pipeline, so either path may be taken on any run.
The minimap2 index is a file rather than a directory, which is what
`longread_hostremoval_index` expects, and `-x map-ont` matches what taxprofiler's
own `MINIMAP2_INDEX` would produce — an `.mmi` is only valid for the preset it
was built with.

taxprofiler takes exactly one reference and one index — `hostremoval_reference`
is a single `file()` and the index channel is `.first()`-ed — so a host plus PhiX
is one concatenated reference rather than two databases. It is also why PhiX
cannot be added to a finished index: a bowtie2 index is an FM-index over the
whole concatenated text, with no append or merge. Including PhiX at build time is
free either way, at 5.4 kbp against 3 Gbp.

Each reference stays under bowtie2's 4.295 Gbp small-index threshold, so all
three build ordinary `.bt2` files. `BOWTIE2_ALIGN` finds the basename itself with
`find -L ./ -name "*.rev.1.bt2"`, so an index only has to be alone in its
directory; the name is free.

Human is a deliberate exception to using NCBI's designated reference: NCBI still
names GRCh38.p14 for annotation continuity, but T2T-CHM13v2.0 is gapless and
captures the centromeric and satellite reads GRCh38 lets through to be
misclassified as microbial. Host reads are discarded rather than analysed, so
completeness is what matters. GRCm39 *is* NCBI's current mouse reference.


## Databases

Profiling databases come from
[`config/taxprofiler/database.csv`](../../config/taxprofiler/database.csv):

| tool | db_name | notes |
| --- | --- | --- |
| kraken2 | `pluspf_20260626` | RefSeq archaea, bacteria, viral, plasmid, human, UniVec_Core, protozoa, fungi. `db_type` is `short;long` |
| bracken | `pluspf_20260626` | same directory; `db_params` is `;-r 150` |
| metaphlan | `mpa_vJun23_CHOCOPhlAnSGB_202403` | `db_type` is `short` |

**Bracken's `db_params` must contain a semicolon**, which splits kraken2's
parameters from bracken's. That is the only part of the field that is required —
`db_params` is empty on the other two rows.

**The `-r 150` there is only a fallback.** Bracken's read length is measured per
run: `taxprofiler_samplesheet.sh` samples the staged R1 files, takes the modal
read length, picks the closest `databaseNNNmers.kmer_distrib` the Kraken2
database ships, and writes `taxprofiler_database.csv` into the run directory with
that `-r`. The pipeline names *that* sheet, not this one. Anything before the
semicolon is kraken2's and is copied through untouched, as are bracken flags
other than `-r`.

A read length more than 15% away from the closest available distribution is
warned about on the Wrike task — relative rather than absolute, because 15 bp off
matters at 35 bp reads and does not at 250 bp. Every failure in this step falls
back to the sheet as written, and a long-read run skips it entirely since
taxprofiler does not run Bracken on long reads.

**The generated sheet is the record of what ran**, carrying the exact database
names, paths and parameters, so `taxprofiler_upload.sh` copies it into the
results beside the `nextflow_command.sh`, `taxprofiler_args.yaml` and
`pipeline_manifest.json` that `wrike_job.sh` puts there. The run directory is deleted once a run succeeds, so a
sheet that is not copied is gone. The input samplesheet is deliberately left
behind: it names the requester's own paths on the cluster, and says nothing about
how the numbers were produced.

`taxpasta_taxonomy_dir` points at the kraken2 database directory rather than a
separately downloaded taxdump: the PlusPF archive carries `nodes.dmp` and
`names.dmp`, and using the database's own taxonomy guarantees the taxon IDs match
by construction. `merged.dmp` is absent and optional; unknown taxon IDs — which
MetaPhlAn's unnamed SGBs produce — come back as blank names rather than an error.


## Resource limits

taxprofiler has its own
[`config/taxprofiler/slurm.config`](../../config/taxprofiler/slurm.config) rather
than sharing `config/slurm.config`. taxprofiler 2.0.1 is built on the nf-core 3.x
template, which dropped `params.max_cpus` / `max_memory` / `max_time` in favour
of `process.resourceLimits`; the `params` block in `config/slurm.config` sets
nothing taxprofiler reads.

Kraken2, MetaPhlAn and the host-depletion aligner are sized against the node
rather than left on nf-core's `process_high` label. 16 cpus each puts two of any
of them on a 32-core node with no cores stranded. Kraken2's memory is the figure
to watch: it reads `hash.k2d` into its own heap, 110 GB for PlusPF, so the
reservation is 128 GB.

Nothing copies a database. Nextflow stages inputs as absolute symlinks
(`stageInMode` defaults to `symlink`) and `scratch` copies only declared
*outputs* back, so every tool reads its database over the shared filesystem and
the first task on a node warms the page cache for the rest.


## Cluster setup

The commands below are the whole installation, in order, and reproduce it from
nothing. They drive two scripts —
[`fetch_taxprofiler_db.sh`](../../scripts/fetch_taxprofiler_db.sh) for the profiling
databases and
[`build_host_reference.sh`](../../scripts/build_host_reference.sh) for the host
references — each of which verifies every download against the publisher's own
checksums and writes a manifest beside its output. Each is a Slurm job; run them
from the login node. Steps 1–2 and 3–5 are
independent of each other and can run concurrently.

Total: about 144 GB of profiling database and 19 GB of host references — each
mammalian reference is ~14 GB, being a 3 GB FASTA, a 4 GB bowtie2 index and a
7 GB minimap2 index — and roughly four hours of wall time dominated by the two
mammalian bowtie2 builds.

Every script refuses to overwrite existing output, so re-running a completed step
is safe. To rebuild one, delete its output first.

### 1. Kraken2 + Bracken — PlusPF 2026-06-26

91 GB download needing ~200 GB free while the archive and the extracted copy
coexist; the script checks first and deletes the archive as soon as it unpacks.
Brings its own `nodes.dmp`, `names.dmp` and all seven Bracken distributions.

```bash
sbatch --job-name=db-kraken2 --cpus-per-task=4 --mem=8G --time=24:00:00 --output=/data/prod/nextflow/log/db_%j.out /data/prod/nextflow/scripts/fetch_taxprofiler_db.sh kraken2
```

### 2. MetaPhlAn — mpa_vJun23_CHOCOPhlAnSGB_202403

26 GB across two tars. The version is pinned in the script, not resolved from
`mpa_latest`, which names a database MetaPhlAn 4.1.1 cannot read.

```bash
sbatch --job-name=db-metaphlan --cpus-per-task=4 --mem=8G --time=24:00:00 --output=/data/prod/nextflow/log/db_%j.out /data/prod/nextflow/scripts/fetch_taxprofiler_db.sh metaphlan
```

### 3. Host reference — PhiX only

Seconds. Used by the "PhiX" answer, and by "Human + PhiX" and "Mouse + PhiX" as one
half of their combined references.

```bash
sbatch --job-name=ref-phix --cpus-per-task=32 --mem=64G --time=12:00:00 --output=/data/prod/nextflow/log/ref_%j.out /data/prod/nextflow/scripts/build_host_reference.sh phix GCF_000819615.1
```

### 4. Host reference — human + PhiX

One to two hours, ~4 GB of index. Used by the "Human + PhiX" answer.

```bash
sbatch --job-name=ref-chm13v2phix --cpus-per-task=32 --mem=64G --time=12:00:00 --output=/data/prod/nextflow/log/ref_%j.out /data/prod/nextflow/scripts/build_host_reference.sh chm13v2phix GCF_009914755.1 GCF_000819615.1
```

### 5. Host reference — mouse + PhiX

Same again. Used by the "Mouse + PhiX" answer.

```bash
sbatch --job-name=ref-grcm39phix --cpus-per-task=32 --mem=64G --time=12:00:00 --output=/data/prod/nextflow/log/ref_%j.out /data/prod/nextflow/scripts/build_host_reference.sh grcm39phix GCF_000001635.27 GCF_000819615.1
```

### 6. Verify

Each host reference should show six `.bt2` files, and each database a manifest.

```bash
ls -lh /data/prod/nextflow/db/hostremoval/*/ /data/prod/nextflow/db/hostremoval/*.mmi
```

```bash
jq -r '"\(.name)\t\([.sources[].url] | join(" "))"' /data/prod/nextflow/db/*/*.manifest.json /data/prod/nextflow/db/hostremoval/*.manifest.json
```

`build_host_reference.sh` fails rather than reporting success if `.rev.1.bt2*` or
the `.mmi` is missing, since those are what `BOWTIE2_ALIGN` and `MINIMAP2_ALIGN`
look for.

### 7. Register the pipeline in Wrike

`taxprofiler` is one of the "Pipeline Name" options on the "Bioinformatics
Pipeline" request form, and picking it asks the "Host Depletion" follow-up
question. Both are [set up on the Wrike side](../wrike/account.md#the-request-forms-questions);
nothing runs until they are, since the form is where a requester picks a pipeline
and `wrike_task_handler.sh` matches what they picked against `pipelines/`.

### Adding a host later

One more reference build, plus one `case` arm in
[`TAXPROFILER_01.sh`](../../pipelines/TAXPROFILER_01.sh) and one more option on the
"Host Depletion" field. Neither touches a reference already in place, and runs
that chose a different host reproduce unchanged — their manifests name the
reference by path, not by the answer that selected it.

```bash
sbatch --job-name=ref-newhost --cpus-per-task=32 --mem=64G --time=12:00:00 --output=/data/prod/nextflow/log/ref_%j.out /data/prod/nextflow/scripts/build_host_reference.sh <name> <host_accession> GCF_000819615.1
```
