# taxprofiler

Shotgun metagenomic profiling with
[nf-core/taxprofiler](https://nf-co.re/taxprofiler), running kraken2, bracken,
metaphlan and mOTUs over the same lab samplesheet the ampliseq pipeline takes,
with nonpareil measuring how much of each community was sequenced at all.

Everything here is taxprofiler-specific. For how a request becomes a run at all,
see the [README](../index.md).


## Versions in use

| Component | Version | Where |
| --- | --- | --- |
| nf-core/taxprofiler | **2.0.1** | pinned in `pipelines/TAXPROFILER_01.sh`, by the commit the tag points at |
| Kraken2 database | **PlusPF 2026-06-26** | `db/kraken2/pluspf_20260626` (111 GB) |
| Bracken distributions | 50, 75, 100, 150, 200, 250, 300-mers | same directory |
| MetaPhlAn database | **mpa_vJun23_CHOCOPhlAnSGB_202403** | `db/metaphlan/…` (33 GB) |
| mOTUs database | **db_mOTU_v3.1.0** | `db/motus/db_mOTU_v3.1.0/db_mOTU` (3.5 GB) |
| Host — none | PhiX only (`GCF_000819615.1`) | `db/hostremoval/phix` |
| Host — human | T2T-CHM13v2.0 (`GCF_009914755.1`) + PhiX | `db/hostremoval/chm13v2phix` (14 GB) |
| Host — mouse | GRCm39 (`GCF_000001635.27`) + PhiX | `db/hostremoval/grcm39phix` (13 GB) |

Tool versions come from taxprofiler 2.0.1 and are not ours to choose: kraken2
2.1.5, bracken 3.1, metaphlan 4.1.1, motus 3.1.0, nonpareil 3.5.5. Nonpareil
needs no database of its own — it measures redundancy in the reads themselves.
The bowtie2 and minimap2 builds used for the host references are recorded in
each reference's `manifest.json`.

Every database was fetched fresh by the scripts in
[Cluster setup](#cluster-setup) rather than reused from elsewhere on the cluster,
and each carries a `manifest.json` naming its source URLs, checksums and fetch
date.

**Three pins are deliberate and should not be bumped casually:**

- **MetaPhlAn's database.** Its own `mpa_latest` marker names
  `mpa_vJan26_CHOCOPhlAnSGB_202605`, which requires MetaPhlAn 4.2. taxprofiler
  2.0.1 pins 4.1.1, whose newest supported database is the one above. Moving
  forward needs a newer taxprofiler, not a newer database.
- **mOTUs' database.** mOTUs checks the version recorded inside the database
  against its own before it profiles anything, and taxprofiler 2.0.1 runs
  `MOTUS_PROFILE` in the motus 3.1.0 container. `db_mOTU_v3.1.0` is what that
  version accepts. The v4 catalogues published at `sunagawalab.ethz.ch` are not
  an upgrade path: they are raw gene catalogues - 182 GB for NR95, 745 GB for
  NR100 - for mOTUs 4, a different tool with a different database layout, whose
  only public build is a 4.0.0a alpha. That move needs a newer taxprofiler.
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

The pipeline reads it with `form_answer hostremoval_reference`, lowercases it and takes the first
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
so. The answer is recorded on the Wrike task and in the run's manifest, which is
a better place for it than buried in a reference nobody reads.

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
  Merging is what makes the recorded sample count (distinct samples, not rows)
  match the number of columns in the profile tables.

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
  second FASTQ. Whatever it settles on is recorded as `.samples.platform` as
  well as written into the CSV: the samplesheet is not published with the
  results, and the dashboard heads its read totals with what the reads were.
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

[`taxprofiler_upload.sh`](../../scripts/taxprofiler_upload.sh) summarises the
classifier reports, indexes the results folders, copies them to
`s3://$AWS_S3_BUCKET/nxf/<uid>/`, renders the shared
[dashboard](../results/index.md), and writes the report URL to the Wrike custom
field. What its file index lists is
[`templates/taxprofiler/outputs.conf`](../../templates/taxprofiler/outputs.conf).

[`taxprofiler_composition.sh`](../results/composition.md) runs first and works
out what the Overview plots and what its sidebar reports: the plots and the
classification bars from the kraken2-style reports the run publishes, and the
read totals above them from what fastp and bowtie2 wrote about their own steps.
See [Composition and diversity](../results/composition.md).

**The raw reads are not published.** Unlike ampliseq, the uploader leaves
`raw-sequences/` in the run directory: a WGS run's inputs are large enough that
packaging and uploading them costs more than the analysis did, and the requester
already holds them. The Overview keeps a hidden row for the link that will offer
them from the cluster instead — a `dashboard_link_button` with an empty address,
which renders the markup and hides it. Give it a URL to turn the link on.

**Neither is most of what the pipeline wrote.** `SKIP_UPLOAD` in the uploader
names what a run produces for itself rather than for whoever asked for it, as
globs read from the results folder. The same list goes to
[`index_directories.sh`](../results/browsable-folders.md), to the file index and
to the upload, so the listings, the row counts and the
[download zip](../results/downloads.md) all describe what is actually in the
bucket.

| Left behind | Why |
|---|---|
| `metaphlan/*/*.bowtie2out.txt` | MetaPhlAn's record of which read hit which marker gene, kept only so MetaPhlAn can be re-run without aligning again. On run `vbnhm2tf` these were 1,209 MB — 88% of everything the run published. The profile, the BIOM table and the merged report all stay. |
| `multiqc/multiqc_data/multiqc_data.json` | Every number in the MultiQC report again, as JSON. 28 MB. |
| `multiqc/multiqc_data/multiqc.log` | MultiQC's own debug trace. |
| `multiqc/multiqc_plots` and `multiqc/multiqc_plots/*` | Each of the report's interactive figures rendered again as PNG, SVG and PDF. The folder is named twice — once for what is in it, and once as itself, so `multiqc/` stops listing a folder there is nothing left in. |
| `fastqc/*/*_fastqc.zip` | The same measurements as the `_fastqc.html` published beside it, which is also what MultiQC read. |

On run `vbnhm2tf` — ten samples, PlusPF and CHOCOPhlAn — that is 1,278 MB of
1,381 MB, **92.5% of the bytes and 298 of the 533 files**, leaving 103 MB to
publish. Drop a line from the list to publish it again; nothing else has to
change.

**The navigation bar carries the Krona chart.** It is the one report that reads a
whole taxonomy rather than a summary of it, and the run writes one per classifier
and database — for this pipeline, `krona/kraken2_<db>.html` and
`krona/kraken2-bracken_<db>_bracken.html`.

**They are the same chart.** Both are drawn from Kraken2's clade counts; the
second is built over the Bracken branch of the workflow but does not render
Bracken's re-estimated abundances. Parsing both files from run `vbnhm2tf` and
comparing them node by node: 23,095 nodes each, the same node set, and the same
magnitude for every taxon in every sample. *Segatella* in sample 4211 is
4,720,453 reads on both — which is what Kraken2 placed in that clade
(`kraken2/.../4211_*.report.txt`), not the 4,893,782 Bracken reassigned to it
(`bracken/.../4211_*_bracken.txt`).

So the choice is between two names for one chart, and
[`taxprofiler_upload.sh`](../../scripts/taxprofiler_upload.sh) links the one that
does not promise estimates it is not showing: the first `krona/*.html` whose name
does not say `bracken`, with a `bracken`-named chart as the fallback for a run
that has only that. Both stay in the file index either way.

If a later taxprofiler release starts drawing the Bracken chart from Bracken's
own numbers, the preference is one condition in that loop — and worth
re-checking against the reports the way the above was, rather than trusting the
filename.

The sidebar's quick downloads are labelled rather than named after the file,
since those filenames carry the tool, the database and the format from the
database sheet:

| Row | File |
|---|---|
| Species abundance table | `taxpasta/bracken_*.tsv`, or `taxpasta/kraken2_*.tsv` for a run without Bracken |
| MetaPhlAn profiles | `metaphlan/metaphlan_*_combined_reports.txt` |
| mOTUs profiles | `motus/motus_*_combined_reports.txt` |
| Raw sequencing data | hidden, as above |

`alpha_diversity.tsv` is not among them: it is the numbers behind a plot the
reader is already looking at, and the file index lists it under `Start here` for
anyone who wants them.

All three open in a tab rather than downloading, which is what
[their content types](../results/index.md#what-a-link-does-when-you-click-it)
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
| bracken | `pluspf_20260626_bracken` | same directory as the kraken2 row; `db_params` is `;-r 150` |
| metaphlan | `mpa_vJun23_CHOCOPhlAnSGB_202403` | `db_type` is `short` |
| motus | `db_mOTU_v3.1.0` | `db_path` ends in `db_mOTU`; `db_type` is `short;long` |

**The mOTUs `db_path` has to end in a directory called `db_mOTU`.** mOTUs
resolves its own files relative to that name, so the release directory holds one
rather than being one: `db/motus/db_mOTU_v3.1.0/db_mOTU`. The `db_name` beside it
is taxprofiler's label, not mOTUs' — it names the output folder and every file
in it, which is why it carries the version.

**Bracken's `db_params` must contain a semicolon**, which splits kraken2's
parameters from bracken's. That is the only part of the field that is required —
`db_params` is empty on the other two rows.

**The bracken row's `db_name` must differ from the kraken2 row's**, even though
both point at the same directory. Running both tools makes taxprofiler classify
every sample twice, once per row, and it matches those kraken2 reports back to
bracken databases on `db_name` alone. Two rows sharing a name means both reports
match, bracken runs twice per sample writing the same `<sample>_<db_name>.bracken.tsv`
both times, and `TAXPASTA_MERGE` fails on an input file name collision at the end
of an otherwise complete run.

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
results beside the `nextflow_command.sh` and `taxprofiler_args.yaml` that
`wrike_job.sh` puts there, and the `run_state.json` published at the same prefix. The run directory is deleted once a run succeeds, so a
sheet that is not copied is gone. The input samplesheet is deliberately left
behind: it names the requester's own paths on the cluster, and says nothing about
how the numbers were produced.

`taxpasta_taxonomy_dir` points at the kraken2 database directory rather than a
separately downloaded taxdump: the PlusPF archive carries `nodes.dmp` and
`names.dmp`, and using the database's own taxonomy guarantees the taxon IDs match
by construction. `merged.dmp` is absent and optional; unknown taxon IDs — which
MetaPhlAn's unnamed SGBs produce — come back as blank names rather than an error.

**MetaPhlAn's taxpasta merge is expected to fail, and is ignored.** mpa_vJun23
splits some species into clades that share one NCBI taxon id — *Prevotella copri*
clades A, B, C and F are all taxon 165179 — and taxpasta indexes a profile by
taxon id, so any sample carrying two of them ends the merge with `ValueError:
Index has duplicate keys`. It is
[taxpasta#140](https://github.com/taxprofiler/taxpasta/issues/140), open, with
0.7.0 still the current release, and `taxpasta_ignore_errors` does not reach it:
that flag skips profiles raising taxpasta's own `StandardisationError`, and this
is a pandas `ValueError` raised straight through. So
[`slurm.config`](../../config/taxprofiler/slurm.config) gives `TAXPASTA_MERGE` an
`errorStrategy` that ignores a failure tagged `metaphlan` and terminates on any
other, and a run that hits it publishes three merged tables rather than four.

Nothing is actually lost: `METAPHLAN_MERGEMETAPHLANTABLES` merges the same
profiles itself into `metaphlan/metaphlan_<db_name>_combined_reports.txt`, keyed
by MetaPhlAn's clade names rather than by taxon id, which is what keeps those
clades apart in the first place.

Nothing in the pipeline reads taxpasta's tables either. The subworkflow emits
them, and the workflow takes only its MultiQC channel, which is built from the
native mergers — so an ignored merge costs one published file and has no other
effect. Switching `run_profile_standardisation` off to avoid taxpasta would be
the worse trade: it gates the whole subworkflow, and would take
`METAPHLAN_MERGEMETAPHLANTABLES` and `KRAKENTOOLS_COMBINEKREPORTS_KRAKEN` with
it, along with their MultiQC sections.


## Diversity and coverage

**Shannon, Simpson and Pielou are not reported for a shotgun run.** They were,
and they were misleading: around half the reads of a WGS sample routinely reach
no taxon at all, and an index computed over only the half PlusPF happens to name
describes the database as much as it describes the sample. Two samples can differ
in "diversity" because one is better represented in RefSeq than the other.

Two tools that do not depend on a classification answer that instead, and the
Overview's diversity chart is drawn from them:

| Reading | From | What it says |
|---|---|---|
| Nonpareil diversity (Nd) | nonpareil | How varied the community is, on a log scale, from how often the same sequence recurs |
| Estimated coverage | nonpareil | What share of the community the reads reached |
| Effort for 95% coverage | nonpareil | How much sequencing that sample would take to get there |
| Observed mOTUs | mOTUs | Species-level clusters found in universal marker genes |
| Read depth | kraken2 | The reads the estimates above were measured at |

**Nonpareil never looks at a database.** It measures redundancy directly:
how often a read has already been seen in the same dataset. A sample whose reads
keep repeating has been sequenced deeply relative to its diversity; one whose
reads are all new has not. That gives both a diversity index and — the reading a
requester asks for without knowing its name — how much of the community the
sequencing actually reached, and how much more it would take.

**mOTUs is the richness count beside it.** It profiles ten universal
single-copy marker genes rather than whole genomes, so it resolves species that
have no assembled reference at all, which is where a Kraken2 database is blind by
construction. Its profiles are published and merged like any other classifier's;
what the diversity chart takes from them is one number per sample, the count of
clusters with a non-zero read count.

Three things about where taxprofiler 2.0.1 wires nonpareil are worth knowing
before quoting its numbers, none of which we can change without patching the
pipeline:

- **It runs before host removal.** Nonpareil sees the reads fastp left, so on a
  `Human + PhiX` run the host reads are still in what it measures. Coverage and
  Nd for a host-heavy sample describe the sample *including* its host.
- **It reads R1 only.** For paired data the module is handed the first mate. The
  effort it reports is therefore about half the bases the sample was sequenced
  at, and `effort_gbp` in the published table is what nonpareil saw rather than
  what the sequencer produced.
- **It runs per run, not per sample.** Its curves are fitted before runs are
  merged, so a sample sequenced twice has two of them.
  [`taxprofiler_composition.sh`](../results/composition.md) keeps the deepest —
  every one of these readings saturates with effort, so the deepest run is the
  best-supported estimate of the same community, and averaging two curves fitted
  at different depths would not mean anything.

All of it lands in `alpha_diversity.tsv`, one row per sample, with the model fit
nonpareil reported for that curve beside each estimate — a low `model_fit` is how
a reader knows not to trust the Nd next to it. A run that produced neither tool's
output still gets its composition plotted; the Overview simply drops its
diversity half rather than plotting read depth and calling it diversity.


## Resource limits

taxprofiler has its own
[`config/taxprofiler/slurm.config`](../../config/taxprofiler/slurm.config) rather
than sharing `config/slurm.config`. taxprofiler 2.0.1 is built on the nf-core 3.x
template, which dropped `params.max_cpus` / `max_memory` / `max_time` in favour
of `process.resourceLimits`; the `params` block in `config/slurm.config` sets
nothing taxprofiler reads.

Kraken2, MetaPhlAn, mOTUs and the host-depletion aligner are sized against the
node rather than left on nf-core's `process_high` label. 16 cpus each puts two of
any of them on a 32-core node with no cores stranded. Kraken2's memory is the
figure to watch: it reads `hash.k2d` into its own heap, 110 GB for PlusPF, so the
reservation is 128 GB.

**Nonpareil is given a memory reservation it will actually use.** The module
passes `task.memory` straight to nonpareil's `-R`, which is the ceiling nonpareil
sizes its k-mer table against, so the 64 GB reserved for it is a budget rather
than a headroom estimate. Reserving less is a coarser estimate rather than a
failed task.

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
from the login node. Steps 1–3 and 4–6 are
independent of each other and can run concurrently.

Total: about 148 GB of profiling database and 19 GB of host references — each
mammalian reference is ~14 GB, being a 3 GB FASTA, a 4 GB bowtie2 index and a
7 GB minimap2 index — and roughly four hours of wall time dominated by the two
mammalian bowtie2 builds. Nonpareil has no setup step: it needs no database.

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

### 3. mOTUs — db_mOTU_v3.1.0

3.1 GB from Zenodo, unpacking to ~3.5 GB. This is the archive `motus downloadDB`
fetches for mOTUs 3.1.0, verified against the same md5 that command checks
(`f841c36150025af837f7a9a358c9a3c3`), so what lands is what that command would
have installed. The script writes `db_mOTU_versions` afterwards exactly as
`downloadDB` writes it — the archive does not carry a usable one, and mOTUs
refuses to profile without it.

```bash
sbatch --job-name=db-motus --cpus-per-task=4 --mem=8G --time=24:00:00 --output=/data/prod/nextflow/log/db_%j.out /data/prod/nextflow/scripts/fetch_taxprofiler_db.sh motus
```

### 4. Host reference — PhiX only

Seconds. Used by the "PhiX" answer, and by "Human + PhiX" and "Mouse + PhiX" as one
half of their combined references.

```bash
sbatch --job-name=ref-phix --cpus-per-task=32 --mem=64G --time=12:00:00 --output=/data/prod/nextflow/log/ref_%j.out /data/prod/nextflow/scripts/build_host_reference.sh phix GCF_000819615.1
```

### 5. Host reference — human + PhiX

One to two hours, ~4 GB of index. Used by the "Human + PhiX" answer.

```bash
sbatch --job-name=ref-chm13v2phix --cpus-per-task=32 --mem=64G --time=12:00:00 --output=/data/prod/nextflow/log/ref_%j.out /data/prod/nextflow/scripts/build_host_reference.sh chm13v2phix GCF_009914755.1 GCF_000819615.1
```

### 6. Host reference — mouse + PhiX

Same again. Used by the "Mouse + PhiX" answer.

```bash
sbatch --job-name=ref-grcm39phix --cpus-per-task=32 --mem=64G --time=12:00:00 --output=/data/prod/nextflow/log/ref_%j.out /data/prod/nextflow/scripts/build_host_reference.sh grcm39phix GCF_000001635.27 GCF_000819615.1
```

### 7. Verify

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

### 8. Register the pipeline in Wrike

`taxprofiler` is one of the "Nextflow Pipeline" options on the "Bioinformatics
Pipeline" request form, and picking it asks the "Taxprofiler --hostremoval_reference" follow-up
question. Both are [set up on the Wrike side](../wrike/account.md#the-request-forms-questions);
nothing runs until they are, since the form is where a requester picks a pipeline
and `wrike_task_handler.sh` matches what they picked against `pipelines/`.

### Adding a host later

One more reference build, plus one `case` arm in
[`TAXPROFILER_01.sh`](../../pipelines/TAXPROFILER_01.sh) and one more option on the
"Taxprofiler --hostremoval_reference" field. Neither touches a reference already
in place, and runs
that chose a different host reproduce unchanged — their manifests name the
reference by path, not by the answer that selected it.

```bash
sbatch --job-name=ref-newhost --cpus-per-task=32 --mem=64G --time=12:00:00 --output=/data/prod/nextflow/log/ref_%j.out /data/prod/nextflow/scripts/build_host_reference.sh <name> <host_accession> GCF_000819615.1
```
