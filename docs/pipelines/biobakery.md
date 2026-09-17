# biobakery

Shotgun metagenomic profiling with the [bioBakery](https://github.com/biobakery)
tools, run as a Nextflow workflow that lives in this repository:
[KneadData](https://github.com/biobakery/kneaddata) cleans the reads and removes
the host, [MetaPhlAn](https://github.com/biobakery/MetaPhlAn) says what was in
each sample, and [HUMAnN](https://github.com/biobakery/humann) says what those
communities can do. [mOTUs](https://github.com/motu-tool/mOTUs) and
[Nonpareil](https://github.com/lmrodriguezr/nonpareil) beside them say how
diverse each community is, for the Overview's diversity chart,
[EsViritu](https://github.com/cmmr/EsViritu) finds the human, animal and plant
viruses among the reads, and
[Marker-MAGu](https://github.com/cmmr/Marker-MAGu) profiles gut phages beside
the bacteria and archaea in one marker gene pass.

KneadData and MetaPhlAn run on every sample; HUMAnN, mOTUs, Nonpareil, EsViritu
and Marker-MAGu are modules a run can switch off. The workflow is built so that
more optional modules can be added beside it — see
[Adding a module](#adding-a-module) — and so that the whole of it can later be
packaged into one Nix image with the databases mounted from outside; see
[Toward a container](#toward-a-container).

For how a request becomes a run at all, see the [Overview](../index.md).


## Versions in use

| Component | Version | Where |
| --- | --- | --- |
| KneadData | **0.12.4** | `quay.io/biocontainers/kneaddata:0.12.4--pyhdfd78af_0`, in `modules/kneaddata.nf` |
| MetaPhlAn | **4.1.1** | `quay.io/biocontainers/metaphlan:4.1.1--pyhdfd78af_0`, in `modules/metaphlan.nf` |
| HUMAnN | **3.9** | `quay.io/biocontainers/humann:3.9--py312hdfd78af_0`, in `modules/humann.nf` |
| mOTUs | **3.1.0** | `quay.io/biocontainers/motus:3.1.0--pyhdfd78af_0`, in `modules/motus.nf` |
| Nonpareil | **3.5.5** | `quay.io/biocontainers/nonpareil:3.5.5--r43hdcf5f25_0`, in `modules/nonpareil.nf` |
| EsViritu | **1.3.3** | `quay.io/biocontainers/esviritu:1.3.3--pyhdfd78af_0`, in `modules/esviritu.nf` |
| Marker-MAGu | **0.4.0** | `quay.io/biocontainers/marker-magu:0.4.0--pyhdfd78af_1`, in `modules/markermagu.nf` |
| biom-format | **2.1.17** | `quay.io/biocontainers/biom-format:2.1.17`, in `modules/markermagu.nf`, for Marker-MAGu's BIOM tables |
| MultiQC | **1.35** | `quay.io/biocontainers/multiqc:1.35--pyhdfd78af_1`, in `modules/multiqc.nf` |
| MetaPhlAn database | **mpa_vJun23_CHOCOPhlAnSGB_202403** | `db/metaphlan/…`, shared with taxprofiler |
| HUMAnN databases | **v201901_v31** / **v201901b** | `db/humann/v201901b/…`, shared with taxprofiler |
| mOTUs database | **db_mOTU_v3.1.0** | `db/motus/db_mOTU_v3.1.0/db_mOTU`, shared with taxprofiler |
| EsViritu database | **v3.2.4** ([doi:10.5281/zenodo.17716199](https://doi.org/10.5281/zenodo.17716199)) | `db/esviritu/v3.2.4`, biobakery's alone |
| Marker-MAGu database | **v1.1** ([doi:10.5281/zenodo.8342581](https://doi.org/10.5281/zenodo.8342581)) | `db/markermagu/v1.1`, biobakery's alone |
| Host references | PhiX, T2T-CHM13v2.0 + PhiX, GRCm39 + PhiX | `db/hostremoval/…`, shared with taxprofiler |

**Every image is the BioContainers build of the bioconda package.** The
`biobakery/*` images on Docker Hub are the tools' own, but they have not kept
up: the newest KneadData there is 0.10.0 (2021) and the newest MetaPhlAn 4.0.2
(2022). The bioconda recipes track each release, and BioContainers publishes an
image of every one, pinned here by tag like every other image this system runs.

**MetaPhlAn is pinned to 4.1.1 and its vJun23 database, for HUMAnN.** HUMAnN 3.9
is its newest stable release and accepts a taxonomic profile only if the profile
names vJun23. MetaPhlAn 4.2 writes vJan25 and later databases, and HUMAnN 4 —
still an alpha — does not read MetaPhlAn 4.2 profiles either. Moving MetaPhlAn
forward waits on a stable HUMAnN that does. The same pin already holds for
[taxprofiler](taxprofiler.md#versions-in-use), so both pipelines read the same
database directory.

**mOTUs and Nonpareil are pinned to taxprofiler 2.0.1's versions.** mOTUs
refuses a database built for any other version, so 3.1.0 is what lets both
pipelines read `db_mOTU_v3.1.0`; see [the mOTUs
pin](taxprofiler.md#versions-in-use). Nonpareil needs no database.

**EsViritu is on its newest release and database.** Its database is versioned
apart from the tool — EsViritu 1.0.0 and later read v3.1.0 or later — and v3.2.4
is the newest on Zenodo.

**Marker-MAGu is on its only release.** 0.4.0 is the one version bioconda
publishes and v1.1 the newest database on Zenodo, and v1.1 is the catalogue the
paper behind the tool built and used.

**Two databases are this pipeline's alone.** The MetaPhlAn, HUMAnN and mOTUs
databases and the host references are the ones [taxprofiler's cluster
setup](taxprofiler.md#cluster-setup) installs. EsViritu's and Marker-MAGu's are
fetched once with the same script, before the first run with `run_esviritu` or
`run_markermagu` on:

```bash
sbatch --cpus-per-task=2 --mem=4G --time=2:00:00 scripts/fetch_taxprofiler_db.sh esviritu
```

```bash
sbatch --cpus-per-task=2 --mem=4G --time=4:00:00 scripts/fetch_taxprofiler_db.sh markermagu
```

Each checks its archive against the md5 the Zenodo record lists, unpacks it, and
writes a manifest beside it: `db/esviritu/v3.2.4` —
`virus_pathogen_database.fna`, its minimap2 index and the metadata table — and
`db/markermagu/v1.1`, which is one 10.5 GB `Marker-MAGu_markerDB.fna` and needs
about 16 GB free while it unpacks. Until a database is there, every
`BIOBAKERY_01` run stops before its first task, for want of the parameter that
names it.


## The pipeline

One pipeline, `BIOBAKERY`, currently `BIOBAKERY_01`. Like taxprofiler it reads the
form's "Host Removal" answer — `None`, `PhiX`,
`Human + PhiX` or `Mouse + PhiX`, and `PhiX` when unanswered — and hands KneadData
the matching bowtie2 index. `None` still trims; it removes nothing.

[`BIOBAKERY_01.sh`](../../pipelines/BIOBAKERY_01.sh) runs
`workflows/biobakery` with HUMAnN, mOTUs, Nonpareil, EsViritu and Marker-MAGu
on:

| Step | What | Progress page row |
| --- | --- | --- |
| pre-process | [`biobakery_samplesheet.sh`](../../scripts/biobakery_samplesheet.sh) | `samplesheet` |
| nextflow | `workflows/biobakery` | `biobakery` |
| post-process | [`biobakery_upload.sh`](../../scripts/biobakery_upload.sh) | `upload` |

HUMAnN runs inside the workflow rather than as a second workflow afterwards, as
it does for taxprofiler, so its tasks are listed under the `biobakery` row with
everything else.

**The workflow is not pinned by `-r`.** An nf-core pipeline is fetched at a
commit; this one runs from `$NEXTFLOW_DIR/workflows/biobakery`, so a
[rerun](index.md#reproducing-an-earlier-run) reuses the recorded parameters with
whatever code is checked out. The Nix image is what will pin the code itself.


## How the workflow is put together

```
workflows/biobakery/
  main.nf              samplesheet in, then each enabled module in order
  nextflow.config      parameter defaults, profiles, execution reports
  conf/base.config     per-process resources and retries
  bin/                 helper scripts Nextflow puts on each task's PATH
                         metaphlan_sgb_biom.py, markermagu_tables.py
modules/
  kneaddata.nf         KNEADDATA, KNEADDATA_COUNTS
  metaphlan.nf         METAPHLAN, METAPHLAN_MERGE
  humann.nf            HUMANN_PREPARE_PROFILE, HUMANN_PROFILE, HUMANN_TABLES
  motus.nf             MOTUS, MOTUS_MERGE
  nonpareil.nf         NONPAREIL, NONPAREIL_CURVES
  esviritu.nf          ESVIRITU, ESVIRITU_SUMMARY
  markermagu.nf        MARKERMAGU, MARKERMAGU_MERGE, MARKERMAGU_TABLES
  multiqc.nf           MULTIQC
config/biobakery/
  slurm.config         the cluster: executor, node sizes, apptainer
```

The split is between **what the analysis is** and **where it runs**. Everything
under `workflows/biobakery` and `modules/` is free of host paths: every database
is a parameter, containers are named by registry address, and the executor comes
from a `-c` config. [`config/biobakery/slurm.config`](../../config/biobakery/slurm.config)
is the one file that knows about this cluster.

`modules/humann.nf` is shared: `workflows/humann`, which taxprofiler runs after
itself, includes the same two HUMAnN processes, so there is one copy of how
HUMAnN is called and how its tables are built.

### Choosing modules per run

KneadData and MetaPhlAn run on every sample. HUMAnN, mOTUs, Nonpareil,
EsViritu, Marker-MAGu and every add-on are switched by a parameter of their
own:

| Parameter | Default | Needs |
| --- | --- | --- |
| `run_humann` | `true` | `humann_chocophlan`, `humann_uniref`, `humann_utility_mapping` |
| `run_motus` | `true` | `motus_db` |
| `run_nonpareil` | `true` | nothing; `nonpareil_mode` is `kmer` unless set to `alignment` |
| `run_esviritu` | `true` | `esviritu_db` |
| `run_markermagu` | `true` | `markermagu_db`; `markermagu_detection` is `default` unless set to `relaxed` |

`motus_args`, `nonpareil_args`, `esviritu_args` and `markermagu_args` add
options to each tool, as `metaphlan_args` does to MetaPhlAn.

A pipeline file sets each with `params_set`, like any other parameter, so it lands
in the params file and in the manifest a rerun is rebuilt from. A form question
could switch it just as `hostremoval_reference` chooses a reference.

`metaphlan_db` is always required, and an empty `kneaddata_db` trims without
depleting a host. A database is checked only when the module that reads it is
enabled, and an unset or missing one stops the run before any task starts.

### What the modules share

The modules talk to each other through two channels in `main.nf`:

| Channel | Shape | Holds |
| --- | --- | --- |
| `ch_reads` | `[meta, reads]` | KneadData's cleaned reads |
| `ch_profiles` | `[meta, profile]` | MetaPhlAn's profile per sample |

`meta` is `[id: <sample>, single_end: <true|false>]`. For a paired sample `reads`
is the two mates' files followed by KneadData's orphans.

### Adding a module

A tool that takes cleaned reads and a database and has a BioContainers image
goes in the way EsViritu and Marker-MAGu did:

1. **`modules/<tool>.nf`** — one process per sample reading `ch_reads`, and a
   second that merges the per-sample tables, publishing under
   `${params.outdir}/<tool>/`. Pin the container by tag, and give both
   processes a `stub:` block. A tool that can trim or deplete reads itself —
   both of these can — has that left off, since KneadData has done it.
2. **`workflows/biobakery/nextflow.config`** — `run_<tool> = true` and the
   database parameter.
3. **`workflows/biobakery/main.nf`** — an `if (params.run_<tool>)` block after
   KneadData's, calling `database('<tool>_db')`.
4. **`workflows/biobakery/conf/base.config`** and
   **`config/biobakery/slurm.config`** — its resources.
5. **A database fetch** with a manifest, as `fetch_taxprofiler_db.sh` does, and
   an entry for it in [`config/databases.json`](../operations/databases.md).
6. **`pipelines/BIOBAKERY_01.sh`** — `params_set run_<tool> true` and the
   database path under `$NEXTFLOW_DB_DIR`.
7. **The dashboard** — rows in `templates/biobakery/outputs.conf`, a
   `dashboard_tab` in `biobakery_upload.sh`, a sentence in
   `biobakery_methods.sh` citing the tool from `config/references.json`, and a
   line in `templates/biobakery/prune.conf` for anything it publishes per
   sample that a merged table already carries.


## Preparing a run

[`biobakery_samplesheet.sh`](../../scripts/biobakery_samplesheet.sh) runs
[`taxprofiler_samplesheet.sh`](taxprofiler.md#preparing-a-run) and keeps what it
writes, so both pipelines accept the same lab samplesheet the same way: paired or
single-end, repeated sample names as runs of one sample, reads staged into
`raw-sequences/`, the platform measured. The CSV is renamed
`biobakery_samplesheet.csv`, and the Bracken database sheet taxprofiler also
needs is deleted.

**A run whose reads are not Illumina short reads is refused** here, with the
requester told why: KneadData, MetaPhlAn and HUMAnN are all short-read tools. The
workflow checks again for anyone running it by hand, and skips such rows with a
warning.


## KneadData

One task per sample. A sample's runs are joined in samplesheet order into one
file per mate, then trimmed with Trimmomatic, cleared of tandem repeats with TRF,
and aligned against the host with bowtie2. FastQC runs before and after. The
defaults are KneadData's own: `--sequencer-source NexteraPE`, Trimmomatic's
`SLIDINGWINDOW:4:20` and a minimum length of half the read length, bowtie2 in
`--very-sensitive-local`, and `--decontaminate-pairs strict`.
`kneaddata_args` adds to them.

**KneadData is pointed at Trimmomatic's jar, not its command.** It passes
`--max-memory` to Java only when it runs the jar itself. Left to find
Trimmomatic on `PATH`, it runs the bioconda wrapper instead, which ignores that
setting and caps the heap at 1 GB — enough for a small sample, and an
`OutOfMemoryError` on a sample of a million pairs at 16 threads, however much
memory the task was given. The heap is three quarters of the task's memory.

**The cleaned reads are the files KneadData's log lists as final.** Which files
those are depends on the run — `<sample>_paired_1.fastq` and its orphans when a
host was depleted, `<sample>.repeats.removed.1.fastq` when nothing was, and
`<sample>.fastq` for single-end reads — and KneadData leaves its contaminant and
trimmed files beside them whatever `--remove-intermediate-output` says. They are
gzipped for the modules after it and not published; `save_clean_reads` publishes
them under `kneaddata/clean/`.

**Where reads are lost is `kneaddata/read-counts.tsv`**: one row per sample, one
column per step and file — `raw pair1`, `trimmed pair1`,
`decontaminated host pair1`, `final orphan1`, and so on — with `NA` where a
sample has no such count. It is built from the `READ COUNT` lines of every log
rather than by `kneaddata_read_count_table`, which names each sample by its log's
name up to the first dot and so would merge `P3.stool.T1` and `P3.stool.T2`.

**KneadData logs no count after Tandem Repeats Finder.** Its `decontaminated` and
`final` counts come from host depletion, so they take in what TRF removed as
well, and a run with no host logs nothing after `trimmed`. For that run
`KNEADDATA` counts the final files itself and appends them to the log as
`final` lines in KneadData's own format, which is what keeps the retained reads
from reading as the trimmed ones.


## MetaPhlAn

One task per sample, over every cleaned file at once, with
`-t rel_ab_w_read_stats --unclassified_estimation`. Each profile therefore
carries marker coverage and an estimated read count beside each clade's relative
abundance, and that abundance is a share of every read processed — the
`UNCLASSIFIED` row is the rest. Published per sample under
`metaphlan/profiles/`.

**The database release is the one `metaphlan_db` is named after.** MetaPhlAn
reads an index by name, so one directory can hold several releases. The module
uses the index named like the directory when there is one, the only index
otherwise, and refuses a directory holding several with none named like it.

`METAPHLAN_MERGE` publishes the profile at three levels of detail under
`metaphlan/`:

| Files | Rows | `UNCLASSIFIED` | Tree |
|---|---|---|---|
| `metaphlan-counts.tsv`, `metaphlan-relab.tsv` | every clade at every rank, kingdom to SGB | yes | no |
| `species-counts.tsv`, `species-relab.tsv` | species | yes | no |
| `taxa-counts.tsv`, `.json.biom`, `.hdf5.biom` | SGBs on the phylogeny | no | in the `.biom` files |
| `taxa-tree.newick` | the phylogeny, pruned to those SGBs | — | — |

`merge_metaphlan_tables.py` joins the profiles into `metaphlan-relab.tsv`, one
column per sample, and keeps only relative abundance. The species tables are
the species rows and the `UNCLASSIFIED` row alone — so each sample's column
accounts for every read, and these are the tables that say how much of a sample
went unclassified.

**The read counts are merged by `METAPHLAN_MERGE` itself.** An awk pass over the
same profiles takes `estimated_number_of_reads_from_the_clade` — the clade's
marker coverage multiplied by its genome length — into `metaphlan-counts.tsv`,
in the same layout as the relative abundance tables: whole numbers, and 0 where
a sample did not report a clade. These are what taxprofiler publishes as
`count_tables/metaphlan-reads.tsv`.

Its SGB rows are the feature table, written by
[`bin/metaphlan_sgb_biom.py`](../../workflows/biobakery/bin/metaphlan_sgb_biom.py)
with the biom-format and DendroPy libraries the MetaPhlAn container ships:
`taxa-counts.tsv` in classic tabular BIOM form, and the same table as
`taxa-counts.json.biom` (BIOM 1.0) and `taxa-counts.hdf5.biom` (BIOM 2.1). One row per SGB, keyed by the bare SGB number, with its lineage from
kingdom to `t__SGB…` as the taxonomy. A `t__SGB…_group` row is that SGB. These
are the tables to rarefy or hand to a count-based differential abundance method.

**The rows are SGBs, not species, because the tree's tips are.** MetaPhlAn 4's
unit is the SGB, and one species name can cover several of them — so a
species-level table has no tip to put each row on. Collapsing on the species
rank of the taxonomy gives the species table back.

**The tree is MetaPhlAn's own SGB phylogeny**, the same file taxprofiler reads
(see [The MetaPhlAn phylogeny](taxprofiler.md#the-metaphlan-phylogeny)).
MetaPhlAn ships it inside its package as `utils/<database>.nwk`, and the copy in
the 4.1.1 container has the same md5 as the one `fetch_taxprofiler_db.sh`
verifies, so the workflow reads it from there by the database named in the
profiles and needs no parameter for it. It is pruned to the SGBs in the table,
keeping branch lengths — checked against `ape::keep.tip` — and goes into the
BIOM 2.1 file at `observation/group-metadata/phylogeny` and into the BIOM 1.0
file as the top-level `phylogeny` string rbiom reads, and is published on its own
as `metaphlan/taxa-tree.newick`. rbiom would prune the full tree itself on
reading, but QIIME 2 and phyloseq would not, and the standalone file wants to be
this run's tree.

Every row of a table carrying a tree has to be a tip on it, so **SGBs the
phylogeny lacks are left out of the BIOM tables** — the eukaryotic `t__EUK…`
bins, which it does not include — and listed in the task's log.
`metaphlan-counts.tsv` and `species-counts.tsv` keep them. A database MetaPhlAn
ships no tree for, or a run with fewer than two SGBs on it, gets its tables
without a tree and without `taxa-tree.newick`.


## HUMAnN

The same processes, tables and failure handling as taxprofiler's — see
[Functional profiling](taxprofiler.md#functional-profiling) for what HUMAnN is
doing and what each of the eighteen tables means. Two differences:

- **The profile is rewritten inside the workflow**, by `HUMANN_PREPARE_PROFILE`,
  rather than by a shell script beforehand. The reason is the same: HUMAnN 3.9
  reads the abundance from the second-to-last column, which under
  `rel_ab_w_read_stats` is coverage.
- **It reads KneadData's reads directly**, so nothing has to be published for it
  and deleted afterwards.


## Diversity

The Overview's diversity chart is the same one taxprofiler draws, from the same
two tools; see [Diversity and coverage](taxprofiler.md#diversity-and-coverage)
for what each reading means and why neither is Shannon or Simpson over the
MetaPhlAn profile. Both run by default; `run_motus` and `run_nonpareil` switch them off.

**mOTUs** runs once per sample over every cleaned file — mates as `-f` and `-r`,
orphans as `-s` — with `-c -p`, the same scaled insert counts and NCBI ids
taxprofiler asks for. `MOTUS_MERGE` joins the profiles with `motus merge` into
`motus/motus-counts.tsv`. The richness the chart plots is the clusters in a
sample's profile with a non-zero count, less `unassigned`. Its logs go to
MultiQC, which has a mOTUs section.

**Nonpareil** runs once per sample in k-mer mode over the first mate of each
pair, or over a single-end sample's reads, and `NONPAREIL_CURVES` fits every
curve with `NonpareilCurves.R` into `nonpareil/nonpareil-curves.tsv`, a JSON copy
that MultiQC plots, and a PDF of them all. Where it runs differs from
taxprofiler's in two ways worth knowing before comparing the two:

- **It runs after host removal**, on KneadData's final reads, so coverage and Nd
  describe what is left of the sample once the host is gone. taxprofiler runs it
  before host removal.
- **It runs per sample**, on the runs KneadData already concatenated, so there is
  one curve per sample rather than one per run.

It still reads one mate only, so `effort_gbp` is about half of what was
sequenced. Nonpareil's k-mer mode refuses reads shorter than 24 bp; KneadData's
Trimmomatic step drops reads shorter than 60 bp before anything else, and then
reads shorter than half the read length, which clears it for reads of
48 bp or longer.

**A sample Nonpareil cannot measure does not fail the run.** `NONPAREIL` is
retried three times and then ignored, and `NONPAREIL_CURVES` is ignored when it
fails; the samples it did measure are plotted and the rest are `NA`. mOTUs is
retried like MetaPhlAn.

[`biobakery_composition.sh`](../../scripts/biobakery_composition.sh) writes both
into `alpha_diversity.tsv` in the results root, one row per sample: `reads` (the
reads MetaPhlAn processed), `nonpareil_diversity`, `coverage_pct`,
`redundancy_pct`, `model_fit`, `effort_gbp`, `effort_95_gbp` and
`observed_motus`. The chart offers estimated coverage, Nonpareil diversity,
observed mOTUs, effort for 95% coverage and read depth, in that order, and only
the ones the run produced. A run with neither tool keeps the composition chart
alone.


## EsViritu

One `ESVIRITU` task per sample, over KneadData's final reads, against
`esviritu_db`. EsViritu aligns them with minimap2 (`-x sr`) and keeps an
alignment only when it spans at least 100 bases and 90% of the read at 80%
identity or better. It dereplicates the genomes that attract the same reads,
aligns the reads again to what is left, builds a consensus of each detected
genome with `samtools consensus`, and aligns that back to the whole database to
settle its taxonomy. Species and subspecies are assigned at 90% and 95%
identity, EsViritu's defaults; `esviritu_args` can change them with
`--species-threshold` and `--subspecies-threshold`.

- **A paired sample is run as `-p paired` over its two mates alone.** EsViritu
  takes one layout per call, so KneadData's orphans are left out — the one
  module that does not read them. A single-end sample is `-p unpaired`.
- **EsViritu's own filters are off.** Its `-q` (fastp) and `-f` (minimap2
  against a host) repeat what KneadData has done. It still runs fastp once per
  sample, only to count the reads its abundances are divided by.
- **No virus is not a failure.** EsViritu exits 0 without writing a table both
  when no read aligns and when it stops on an error, so `ESVIRITU` reads its log
  to tell the two apart: `No reads aligned to the EsViritu DB` is a sample with
  nothing to report, and anything else with the tables missing fails the task.
  A sample that got as far as writing its tables succeeds even if EsViritu then
  exits non-zero, which is its HTML report failing.
- **The HTML report needs an R package the image does not install.** EsViritu
  installs `dataui` from its own vendored copy on first use, into the first R
  library it can write, and a container's are read-only. Both processes point
  `R_LIBS` at a directory in the task first.

`ESVIRITU_SUMMARY` runs `summarize_esv_runs` over every sample's tables and
publishes them under `esviritu/`, rows sorted by sample:

| File | EsViritu's name | Rows |
| --- | --- | --- |
| `virus-taxa.tsv` | `tax_profile.tsv` | one per virus taxon per sample, with reads, RPKMF and identities |
| `virus-assemblies.tsv` | `detected_virus.assembly_summary.tsv` | one per genome assembly per sample, segments together |
| `virus-contigs.tsv` | `detected_virus.info.tsv` | one per reference sequence per sample, with depth and Pi |
| `virus-coverage.tsv` | `virus_coverage_windows.tsv` | 100 depth windows per reference sequence per sample |
| `read-counts.tsv` | `readstats.tsv` | one per sample: `filtered_reads`, which RPKMF is divided by |
| `virus-report.html` | `EsViritu_project_reactable.html` | every detection, with a coverage sparkline |

`esviritu/consensus/<sample>.consensus.fasta` holds each sample's consensus of
every virus it carried. **`read-counts.tsv` is the only table every sample is
in**; a sample with no row in the virus tables had no read align. The
per-sample tables, parameters and reports stay in the work directory.

`ESVIRITU` is retried twice with more memory and time, then lets running tasks
finish and stops, as mOTUs does: a sample left out would read as a sample with
no virus.


## Marker-MAGu

One `MARKERMAGU` task per sample, over KneadData's final reads, against
`markermagu_db`. Marker-MAGu is MetaPhlAn 4's marker gene strategy run over a
bigger catalogue: MetaPhlAn's own vOct22 markers for bacteria, archaea and
microeukaryotes, with marker genes of the 49,111 phage taxa of the Trove of Gut
Virus Genomes added, and thresholds retuned so that a phage is called about as
confidently as a bacterium. minimap2 (`-x sr`) aligns the reads, `samtools view
-q 1` keeps only those that align to one marker alone, and CoverM counts them
at 90% identity over at least half the read.

A species-level genome bin is reported when at least 75% of its markers carried
a read — `markermagu_detection` set to `relaxed` lowers that to 33.3% and at
least three markers — and at least four markers and ten reads back it. Its abundance is
reads per kilobase of marker per million reads, rescaled so that each sample's
abundances sum to 1.

**The threshold is a share of an SGB's markers, so it falls hardest on the
organisms with the most of them.** A phage in this database has four to seven
marker genes and needs three or four of them hit; a bacterium has hundreds and
needs three quarters of them hit, which a shallow sample cannot do however
clearly the organism is there. On a run of about 1.3M retained reads per
sample, `default` reported nothing but `k__Viruses` — the bacteria MetaPhlAn
found in the same reads were all below it. `markermagu_detection` set to
`relaxed` is what makes the bacterial half of the table comparable with
MetaPhlAn 4's; on `default` these tables are effectively the phage tables, which
is why their names carry a `virus-` prefix.

**Either way they do not replace MetaPhlAn's.** Marker-MAGu has no unclassified
share, so its abundances are shares of what was identified rather than of the
sample, and its counts are marker gene reads rather than an estimate of every
read an organism contributed. The reason to read it is the `k__Viruses` rows,
which MetaPhlAn has nothing to say about. A phage with fewer than four marker
genes cannot be detected at all, which leaves out the small single-stranded
microviruses and inoviruses.

- **Every cleaned file goes in at once.** Marker-MAGu pools the reads it is
  given and uses no pairing information, so mates and orphans are all passed
  together, as they are to mOTUs.
- **Its own filters are off.** `-q` (fastp) and `-f` (minimap2 against a filter
  set) repeat what KneadData has done, and both default to off.
- **`markermagu` always exits 0.** Its Python wrapper drops the exit code of the
  shell script that does the work, so a missing database, an unreadable read
  file and a finished profile all leave it exiting 0. `MARKERMAGU` therefore
  checks for the two tables the run should have written and fails the task when
  either is missing. A sample nothing passed the thresholds in is not that case:
  it gets a profile holding its header alone.

### The tables

`MARKERMAGU_MERGE` runs Marker-MAGu's own `combine_sample_tables1.R` over every
sample's profile, and `MARKERMAGU_TABLES` turns that long form into **the same
tables MetaPhlAn's profile is published as**, so the two can be read side by
side:

| MetaPhlAn | Marker-MAGu | Holds |
| --- | --- | --- |
| `metaphlan-counts.tsv`, `metaphlan-relab.tsv` | `virus-counts.tsv`, `virus-relab.tsv` | every clade from kingdom to SGB, one column per sample, as reads and as percentages |
| `species-counts.tsv`, `species-relab.tsv` | — | a Marker-MAGu lineage ends at its SGB, which is its species, so the feature table is the species table |
| `taxa-counts.tsv`, `.json.biom`, `.hdf5.biom` | `virus-taxa-counts.tsv`, `.json.biom`, `.hdf5.biom` | the SGB rows as a feature table, keyed by the SGB's own name |
| `taxa-tree.newick` | — | Marker-MAGu publishes no phylogeny of its SGBs |
| — | `virus-profile.tsv` | Marker-MAGu's long form: the marker counts behind each call, which no other table carries |
| — | `virus-read-counts.tsv` | one row per sample: the reads and bases it read, which RPKM is per million of |

**Every name carries a `virus-` prefix** so that no two files of a run share a
basename, and because in practice these tables are the viral ones — see the
threshold note above.

Three differences from MetaPhlAn's tables are worth knowing before reading them
together:

- **The counts are marker gene reads.** MetaPhlAn scales a clade's marker
  coverage up by genome length to estimate every read it contributed;
  Marker-MAGu's counts are the reads that actually aligned to a marker. A
  sample's column totals its marker gene reads, not its sequencing depth.
- **There is no `UNCLASSIFIED` row.** Marker-MAGu reports no unclassified share
  and rescales each sample to 100% of what it identified, so a percentage in
  `virus-relab.tsv` is a share of what was detected. MetaPhlAn's is a share of
  the sample.
- **The feature tables carry no tree**, since there is no phylogeny to put in
  them, so UniFrac and Faith's PD cannot be computed from them as they can from
  MetaPhlAn's.

The tables take their sample columns from `virus-read-counts.tsv` rather than
from the profiles, so **a sample Marker-MAGu detected nothing in is a column of
zeros** rather than a column missing. The per-sample profiles are published
under `markermagu/profiles/` and pruned before the results are indexed.

`MARKERMAGU_TABLES` runs in the biom-format container rather than Marker-MAGu's,
which ships neither biom-format nor numpy;
[`bin/markermagu_tables.py`](../../workflows/biobakery/bin/markermagu_tables.py)
is the counterpart of `metaphlan_sgb_biom.py`.

`MARKERMAGU` is retried twice with more memory and time, then lets running tasks
finish and stops, as mOTUs and EsViritu do.


## The dashboard

[`biobakery_upload.sh`](../../scripts/biobakery_upload.sh) takes the same steps
as taxprofiler's upload script, and a run is read through the same three pages
plus a fourth, Methods. The navigation bar reads:

| Link | Page |
| --- | --- |
| Overview | `overview.html` |
| Deliverables | `deliverables.html`, the annotated file index |
| Methods | `methods.html` — see [The Methods page](#the-methods-page) |
| QC Report | `multiqc/multiqc_report.html` |
| File Explorer | `directory_listing.html`, the results folder's own listing |

- **The Overview's composition chart is MetaPhlAn's.**
  [`biobakery_composition.sh`](../../scripts/biobakery_composition.sh) reads each
  sample's profile at phylum through species, keeps the eleven most abundant taxa
  of each rank and sums the rest into "Other". Shares are of every read MetaPhlAn
  processed, so a column falls short of the top by that sample's unclassified
  share, as on a taxprofiler run. The diversity chart beside it is Nonpareil's
  and mOTUs'; see [Diversity](#diversity).
- **Read totals** in the sidebar are KneadData's: total reads, and behind
  "details" what was left after trimming and after host depletion, each linking
  to the KneadData table in the QC Report; then the reads retained, and
  the smallest, median and largest sample. Each is the reads remaining after
  that step. Tandem Repeats Finder has no bar of its own, since KneadData logs no
  count for it: what it removed shows in "After host depletion", or in
  "Retained reads" for a run with no host.
- **The Feature Table card** has a MetaPhlAn tab (the SGB read counts as
  plain text, JSON and HDF5 BIOM) and a HUMAnN tab (the pathway, gene family and
  EC tables in reads per kilobase, as plain text). Under the downloads, each has
  one bar, "Mapped reads", read as `19% · 764k / 4M`: the reads MetaPhlAn mapped
  to a known clade, or HUMAnN aligned, out of the reads KneadData retained. The
  database is named under the bar — the MetaPhlAn release, or the ChocoPhlAn and
  UniRef90 versions `biobakery_composition.sh` reads off the file names in the
  directories the manifest records. Everything else is in Deliverables. A
  module a run did not enable leaves its tab off. The EsViritu tab offers the
  taxa and genome tables and the interactive report, and one bar, "Samples with
  a virus", out of the samples EsViritu read, with the database release under
  it. The Marker-MAGu tab mirrors the MetaPhlAn one: the same three BIOM
  formats of its own feature table, and one "Mapped reads" bar — the reads it
  aligned to a marker gene of an SGB it reported, out of the reads KneadData
  retained. That share is much the smaller of the two, since these are marker
  gene reads rather than MetaPhlAn's estimate of every read an organism
  contributed, and the two bars are not comparable. Neither tool has a link of
  its own in the navigation bar; their files are sections of Deliverables.
- **The QC Report is MultiQC**, over KneadData's FastQC reports and its
  read count table as a section of its own, and mOTUs' logs and Nonpareil's
  curves on a run with either. It is the only report the run adds;
  there is no Krona chart. `MULTIQC` ignores its own failure, so a run is never
  lost to it.

[`templates/biobakery/outputs.conf`](../../templates/biobakery/outputs.conf) is
the file index, and [`prune.conf`](../../templates/biobakery/prune.conf) deletes
the FastQC zips, MultiQC's re-encodings of its own report and its copy of the
Nonpareil curves, MetaPhlAn's, mOTUs' and Marker-MAGu's per-sample profiles, and
KneadData's and HUMAnN's per-sample logs before anything is published, and takes
the rows no sample has out of `motus-counts.tsv`. The profiles are read for the Overview
first, by `biobakery_composition.sh`. The index ends with a tree of the folders the
download unpacks into.

### The Methods page

One paragraph a requester can paste into the methods section of a manuscript,
describing how the profiles were made from the reads they sent — nothing about
how those reads were produced — with every reference it cites.
[`biobakery_methods.sh`](../../scripts/biobakery_methods.sh) writes it into
`methods_data.json` before the dashboard is rendered, from what this run was
given rather than from what the pipeline usually does:

- **Versions** are the BioContainers images the modules pin, named in full.
  KneadData, MetaPhlAn, HUMAnN and MultiQC carry the version in their tag;
  Trimmomatic, Tandem Repeats Finder, Bowtie2, FastQC and DIAMOND are named and
  cited without one, since the image that carried each fixes it. Nextflow's
  version is the one the manifest recorded.
- **Databases** are the paths in the manifest's parameters, described by their
  entries in [`config/databases.json`](../operations/databases.md): the MetaPhlAn
  release, the ChocoPhlAn and UniRef90 releases, and the genomes and RefSeq
  accessions of the host reference — or a sentence saying no host was removed.
  A dataset DOI in an entry is written beside its release. None of this
  pipeline's databases has one; their papers are cited instead.
- **KneadData's steps** are read from each sample's log in `kneaddata/logs/`,
  which is why the script runs before `prune.conf` deletes them. KneadData logs
  every argument it ran with and the Trimmomatic command itself, so the text
  gives what actually ran rather than what its defaults say. On an unchanged
  run that is:
  - **Trimmomatic** `MINLEN:60 ILLUMINACLIP:NexteraPE-PE.fa:2:30:10:8:TRUE
    SLIDINGWINDOW:4:20 MINLEN:<n>`. The first `MINLEN` drops reads shorter than
    60 bp before anything is clipped. The last is half the length of the
    *first read* of the sample, so it can differ between samples; the text
    gives the range. Single-end samples clip with `2:30:10`.
  - **Tandem Repeats Finder** with `2 7 7 80 10 50 500`. A read is removed if
    TRF reports *any* repeat in it scoring 50 or more — not only reads made up
    mostly of repeats. Each mate is filtered on its own, so a read whose mate
    goes is kept unpaired, as it is after Trimmomatic.
  - **Bowtie2** `--very-sensitive-local` against the host, every read aligned
    as a single-end read. In `strict` pair mode, the default, a read that aligns
    takes its mate with it.

  A run whose logs are gone is described by those defaults, without the read
  length.
- **Samples sequenced in more than one run** — a sample name repeated in the
  samplesheet — get a sentence saying their runs were concatenated.
- **Options** the run added through `kneaddata_args` or `metaphlan_args` are
  written in, and HUMAnN's sentences are left out of a run with `run_humann`
  off.
- **mOTUs and Nonpareil** get one sentence between them, with their versions
  and citations, saying they were run with default settings to quantify
  community diversity. A tool the run did not enable is left out of it.
- **EsViritu** gets sentences of its own on a run with `run_esviritu` on: its
  version, the database release and Zenodo DOI, minimap2 and the alignment
  thresholds, dereplication, RPKMF, and the identities species and subspecies
  were assigned at. On a paired run they say unpaired reads were not used.
- **Marker-MAGu** likewise on a run with `run_markermagu` on: its version, the
  database release and Zenodo DOI, minimap2 and the unique-alignment thresholds,
  the detection stringency this run chose, and how abundance was normalised.

Citations are written `[@id]` against
[`config/references.json`](../../config/references.json), and a tool named a
second time is not cited again. `publish_dashboard.sh` renders the text with
author-year citations, and the references it cites twice — formatted in
alphabetical order, and as BibTeX keyed by the same ids — behind two tab links.
Each copy button copies what is showing as plain text. A run whose text cannot
be written — no manifest, or an id missing from the references — publishes
without the page and without its link.


## Toward a container

The plan is one Nix image holding everything but the databases: Nextflow, this
repository's scripts and workflows, and the tools they call, run with the data
mounted in and described by environment variables. Nothing is built yet — code
outside an image is quicker to change — but this pipeline is laid out for it.

**Code and data are named separately.** `NEXTFLOW_DIR` is where the code is, and
`NEXTFLOW_DB_DIR` — set in `.env` to `$NEXTFLOW_DIR/db` unless the environment
already names somewhere else — is where the databases are. `BIOBAKERY_01.sh`
builds every database path from `NEXTFLOW_DB_DIR`, and the workflow itself names
no path at all. Image caches already have their own variables
(`NXF_APPTAINER_CACHEDIR`).

**Every resolved path lands in the manifest**, since each is a parameter rather
than something a config file reads from the environment. An image run with
different mounts records what it actually read.

**The site config is separate from the workflow.** An image carries
`workflows/biobakery` unchanged, and the site it runs at supplies its own `-c`.

What still assumes the current layout, and is the work of building the image:

- Every script begins `source /data/prod/nextflow/.env`. That line becomes the
  image's own path, or reads it from a variable.
- `.env` sets `NEXTFLOW_DIR` outright, and the other pipelines still read their
  databases from `$NEXTFLOW_DIR/db`.
- Each process names its BioContainers image, which suits a Nextflow run inside
  an image that launches tool containers beside it. An image holding the tools
  as well wants a profile with containers switched off, since every tool would
  already be on `PATH`.

The environment an image would need, beyond its own paths:

| Variable | For |
| --- | --- |
| `NEXTFLOW_DB_DIR` | the databases |
| `NXF_APPTAINER_CACHEDIR` | tool images, while tools still run in containers |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `AWS_DEFAULT_REGION`, `AWS_S3_BUCKET`, `AWS_SQS_QUEUE_URL` | publishing, and the queue |
| `WRIKE_API_TOKEN`, `WRIKE_WEBHOOK_SECRET`, `RUN_ID_SALT` | Wrike, and the uid |
| `GLOBUS_DIR`, `GLOBUS_URL`, `GLOBUS_UUID`, `GLOBUS_RUN_PREFIX`, `GLOBUS_CLI_CLIENT_ID`, `GLOBUS_CLI_CLIENT_SECRET` | the download |
| `S3_RUN_PREFIX` | where results are published |
| `RBIOM_CONTAINER` | the other pipelines' feature tables |

plus a run directory mounted where `wrike_job.sh` is started.


## Trying it locally

The workflow runs anywhere Docker does. The `local` profile caps each task at
the machine's cores and 16 GB; pass a config lowering `process.resourceLimits`
further on a smaller machine. `-stub` replaces KneadData, MetaPhlAn, HUMAnN's
two heavy steps, mOTUs, Nonpareil, EsViritu, Marker-MAGu and MultiQC with
placeholders and runs
everything between them for real, which checks how the modules are wired
together without a database:

```bash
nextflow run workflows/biobakery -stub -profile docker,local --input samplesheet.csv --outdir results --kneaddata_db db/host --metaphlan_db db/metaphlan --humann_chocophlan db/chocophlan --humann_uniref db/uniref90 --humann_utility_mapping db/utility_mapping --motus_db db/motus --esviritu_db db/esviritu --markermagu_db db/markermagu
```

The databases only have to exist for a stub run; add `--run_humann false` to leave
HUMAnN out, and `--run_motus false`, `--run_nonpareil false`,
`--run_esviritu false` or `--run_markermagu false` for any of those.

The samplesheet is the CSV `biobakery_samplesheet.sh` writes:
`sample,run_accession,instrument_platform,fastq_1,fastq_2`.


## Resource limits

[`conf/base.config`](../../workflows/biobakery/conf/base.config) sets a
reservation and a retry policy per process;
[`config/biobakery/slurm.config`](../../config/biobakery/slurm.config) resizes the
ones that depend on the node — KneadData at 16 cpus and 32 GB, MetaPhlAn at 16
cpus and 48 GB, mOTUs at 16 cpus and 32 GB and Nonpareil at 8 cpus and 64 GB, the
same as taxprofiler's `METAPHLAN_METAPHLAN`, `MOTUS_PROFILE` and
`NONPAREIL_NONPAREIL`, EsViritu at 16 cpus and 16 GB, and Marker-MAGu at 16 cpus
and 96 GB — and caps everything
at the node's size. Nonpareil is
handed its memory as `-R` and fills it with its k-mer table, and Marker-MAGu is
the largest reservation here because minimap2 holds the whole 10.5 GB marker
catalogue, split into chunks, while it aligns.

- **KneadData, MetaPhlAn, mOTUs, EsViritu and Marker-MAGu retry twice**, with
  more memory and time each time, then let running tasks finish and stop. All
  five read the requester's reads or a database over the shared filesystem.
  `MARKERMAGU_TABLES` is a small task beside them: two cpus and 8 GB, over
  tables of a few hundred rows.
- **HUMAnN** keeps taxprofiler's policy: a sample is retried once with twice the
  memory and time, then left out of the tables.
- **Nonpareil** is retried three times and then left out of the diversity table,
  and its summary is ignored when it fails.
- **MultiQC** is ignored when it fails.

KneadData decompresses a sample's reads onto the node's scratch before it starts
and compresses what it keeps afterwards, so a deep sample needs several times its
compressed size free under `/tmp`.

`wrike_job.sh`'s 48-hour limit covers the whole workflow, HUMAnN included.


## Registering the pipeline in Wrike

`biobakery` is in `WRIKE_FORM_ANSWERS`, but nothing runs until the Wrike side
matches:

1. Add `biobakery :: WGS taxonomic and functional profiling (KneadData, MetaPhlAn, HUMAnN)`
   to the "Nextflow Pipeline" field.
2. Show the "Host Removal" follow-up question for it as
   well. Unanswered, the pipeline depletes PhiX alone.
