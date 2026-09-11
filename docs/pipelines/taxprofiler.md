# taxprofiler

Shotgun metagenomic profiling with
[nf-core/taxprofiler](https://nf-co.re/taxprofiler), running kraken2, bracken,
metaphlan and mOTUs over the same lab samplesheet the ampliseq pipeline takes,
with nonpareil measuring how much of each community was sequenced at all, and a
BIOM feature table carrying a tree out to the requester alongside plain count
tables in both reads and genome-size-corrected cells.

HUMAnN then answers the other half of the question — what those communities can
do — over the reads taxprofiler already cleaned and the profiles it already
computed. taxprofiler has no functional profiling of any kind, so that is a
second workflow in this repository rather than a taxprofiler parameter; see
[Functional profiling](#functional-profiling).

Everything here is taxprofiler-specific. For how a request becomes a run at all,
see the [README](../index.md).


## Versions in use

| Component | Version | Where |
| --- | --- | --- |
| nf-core/taxprofiler | **2.0.1** | pinned in `pipelines/TAXPROFILER_01.sh`, by the commit the tag points at |
| Kraken2 database | **PlusPF 2026-06-26** | `db/kraken2/pluspf_20260626` (111 GB) |
| Bracken distributions | 50, 75, 100, 150, 200, 250, 300-mers | same directory |
| MetaPhlAn database | **mpa_vJun23_CHOCOPhlAnSGB_202403** | `db/metaphlan/…` (33 GB) |
| MetaPhlAn SGB phylogeny | same release, 36,273 tips | `db/metaphlan/…/mpa_vJun23_CHOCOPhlAnSGB_202403.nwk` (1.2 MB) |
| mOTUs database | **db_mOTU_v3.1.0** | `db/motus/db_mOTU_v3.1.0/db_mOTU` (3.5 GB) |
| HUMAnN | **3.9** | pinned by container digest in `workflows/humann/main.nf` |
| ChocoPhlAn pangenomes | **v201901_v31** | `db/humann/v201901b/chocophlan` (16 GB) |
| UniRef90 DIAMOND index | **v201901b**, annotated | `db/humann/v201901b/uniref90` (34 GB) |
| HUMAnN utility mapping | **v201901b** | `db/humann/v201901b/utility_mapping` (6 GB) |
| Host — none | PhiX only (`GCF_000819615.1`) | `db/hostremoval/phix` |
| Host — human | T2T-CHM13v2.0 (`GCF_009914755.1`) + PhiX | `db/hostremoval/chm13v2phix` (14 GB) |
| Host — mouse | GRCm39 (`GCF_000001635.27`) + PhiX | `db/hostremoval/grcm39phix` (13 GB) |

Tool versions come from taxprofiler 2.0.1 and are not ours to choose: kraken2
2.1.5, bracken 3.1, metaphlan 4.1.1, motus 3.1.0, nonpareil 3.5.5. Nonpareil
needs no database of its own — it measures redundancy in the reads themselves.
The bowtie2 and minimap2 builds used for the host references are recorded in
each reference's `manifest.json`. HUMAnN is ours to choose and is pinned to the
BioContainer for 3.9, which brings its own bowtie2 and DIAMOND.

Every database was fetched fresh by the scripts in
[Cluster setup](#cluster-setup) rather than reused from elsewhere on the cluster,
and each carries a `manifest.json` naming its source URLs, checksums and fetch
date.

**Four pins are deliberate and should not be bumped casually:**

- **MetaPhlAn's database.** Its own `mpa_latest` marker names
  `mpa_vJan26_CHOCOPhlAnSGB_202605`, which requires MetaPhlAn 4.2. taxprofiler
  2.0.1 pins 4.1.1, whose newest supported database is the one above. This pin is
  now load-bearing for two steps rather than one: HUMAnN 3.9 accepts a MetaPhlAn
  profile only if it names `vJun23`, so moving forward needs a newer taxprofiler
  *and* a stable HUMAnN 4 — and there isn't one. HUMAnN's newest release is 3.9,
  from February 2024; 4.0 has been in alpha since October 2024.
- **HUMAnN's databases.** `v201901_v31` and `v201901b` look stale and are not:
  the `_v31` suffix is the bioBakery 3.1 pangenome catalogue, and HUMAnN 3.9
  refuses a ChocoPhlAn directory holding any file whose name does not carry that
  string. Nothing else may be written into that directory for the same reason —
  a README beside the pangenomes is enough to make every HUMAnN call exit.
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

**Human is depleted only when the answer asks for it.** Some published shotgun
studies deplete against human on every run, host or not, on the grounds that
human DNA is a handler and reagent contaminant of every library rather than a
candidate host. This pipeline does not: what a run was depleted against is what
the requester asked for, and a host they did not name is not silently added to
their methods section. Human reads in a non-human sample are visible in the
Kraken2 report like any other taxon, which is the right place for them.


## Preprocessing

Short reads take fastp, then complexity filtering, then host removal, then run
merging, with nonpareil forking off between fastp and the complexity filter —
which is where taxprofiler 2.0.1 wires it. Because the complexity filter here is
fastp's own, that fork is after it in practice: taxprofiler's complexity
subworkflow is a pass-through when its tool is `fastp`, and the filtering has
already happened one step up.

**Complexity filtering is on, through fastp rather than bbduk.** Homopolymer
runs, poly-G tails from two-colour chemistry and microsatellite carry no
taxonomic signal, and PlusPF is full of repeat-rich human, protozoan and fungal
sequence for them to land on. taxprofiler's default tool for this is `bbduk`,
which is a separate process and a second full pass over every FASTQ; setting
`shortread_complexityfilter_tool` to `fastp` instead makes taxprofiler append
`--low_complexity_filter --complexity_threshold 30` to the fastp call that is
already running, so the step costs no extra task and no extra I/O.

fastp's measure — the fraction of bases differing from the next base — is
cruder than bbduk's Shannon entropy over a 50 bp window. bbduk at
`entropy=0.3` is the upgrade if a run ever needs it; it costs one more pass over
the reads and one more copy of every FASTQ in the work directory.

**Reads shorter than 35 bp are dropped**, against taxprofiler's default of 15 —
see [Diversity and coverage](#diversity-and-coverage) for why.

**Duplicates are not removed.** fastp would do it for free, inside the same
call, under `shortread_qc_dedup`. It is left off: duplication rate in a shotgun
library tracks library size and the sample's own alpha diversity, so an abundant
organism sequenced deeply genuinely produces identical fragments, and removing
them biases common taxa downward in a depth-dependent direction. The studies
that recommend deduplication are about the cost of assembly and binning, which
this pipeline does not do. fastp measures the rate either way, and MultiQC
reports it.

**Pairs are not merged.** `shortread_qc_mergepairs` exists for tools that cannot
use pair information — DIAMOND, and MALT's independent alignment — and every
profiler here handles pairs natively. Merging would also change the read count
every share on the dashboard is taken against.

**Long reads take porechop_abi and nanoq**, at nanoq's defaults of 1,000 bp
minimum length and Q7 minimum quality. That length interacts with platform
detection: [`taxprofiler_samplesheet.sh`](#preparing-a-run) calls a run long-read
when its median read length exceeds 1,000 bp, so a PacBio HiFi or short-fragment
ONT run near that boundary is filtered at the same threshold that classified it.
`longread_qc_qualityfilter_minlength` is the parameter to lower for one, the way
`INSTRUMENT_PLATFORM` pins the platform.


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

[`taxprofiler_humann.sh`](../../scripts/taxprofiler_humann.sh) runs first among
the post-process steps, since the one after it publishes what it wrote and
deletes the reads it read. See [Functional profiling](#functional-profiling).

[`taxprofiler_upload.sh`](../../scripts/taxprofiler_upload.sh) summarises the
classifier reports, prunes and indexes the results folders, copies them to
`s3://$AWS_S3_BUCKET/nxf/<uid>/`, renders the shared
[dashboard](../results/index.md), publishes the reads and the results as one zip
to [Globus](../operations/globus.md), and writes the report URL to the Wrike
custom field. What its file index lists is
[`templates/taxprofiler/outputs.conf`](../../templates/taxprofiler/outputs.conf).

[`taxprofiler_composition.sh`](../results/composition.md) runs first and works
out what the Overview plots and what its sidebar reports: the plots and the
classification bars from the kraken2-style reports the run publishes, and the
read totals above them from what fastp and bowtie2 wrote about their own steps.
It also builds the [feature tables](#the-feature-tables) a requester loads. See
[Composition and diversity](../results/composition.md).

**The two bulky downloads go to Globus, not to S3.** The reads staged in
`raw-sequences/` and the whole dashboard as one zip are written into
`$GLOBUS_DIR/nxf/<uid>/` and linked from the Overview — see
[Globus](../operations/globus.md). A WGS run's inputs are large enough that
uploading them would cost more than the analysis did; writing them onto the
guest collection is a `zip` into place on the cluster's own disk, and the
requester fetches them at the cluster's own bandwidth.

**The reads in that zip are the raw ones, and only those.**
`save_analysis_ready_fastqs` is on, but only so that HUMAnN profiles exactly the
reads the classifiers saw; `prune.conf` deletes that set once HUMAnN has read it,
before anything is indexed, zipped or uploaded. What a requester wants back is
the data as it was sequenced — the processed reads are reproducible from it and
from the published parameters, and a second copy of every FASTQ doubles a
download that is already the largest thing a run produces.

**Most of what the pipeline wrote is deleted before any of it is published.**
[`templates/taxprofiler/prune.conf`](../../templates/taxprofiler/prune.conf)
names what a run produces for itself rather than for whoever asked for it, and
[`prune_results.sh`](../results/index.md) deletes it out of `results/` outright —
before the folders are indexed, so the listings, the row counts, the file index,
the zip and the bucket cannot come to describe different things. Any folder the
deletions empty goes with them.

| Deleted | Why |
|---|---|
| `analysis_ready_fastqs/` | The trimmed, filtered, depleted and merged reads, published only so that HUMAnN could be run over exactly what the classifiers saw. By the time this runs it already has been — see [Functional profiling](#functional-profiling). |
| `kraken2/*/`, `bracken/*/`, `metaphlan/*/`, `motus/*/` | The per-sample profiles. Each is one column of the merged table published in the folder above it, and of the taxpasta table beside that: a Kraken2 sample report is the `N_all`/`N_lvl` pair of `kraken2_*_combined_reports.txt`, a mOTUs `.out` is one column of `motus_*_combined_reports.txt` with the same 34,344 rows in the same order. `metaphlan/*/` also holds MetaPhlAn's alignments — its record of which read hit which marker gene, kept only so MetaPhlAn can be re-run without aligning again, and on run `vbnhm2tf` 1,209 MB of 1,381 MB. |
| `kraken2/kraken2_*-bracken_combined_reports.txt`, `taxpasta/kraken2_*-bracken.tsv` | nf-core/taxprofiler names Bracken's kraken-style outputs `<db>-bracken`, but what it aggregates there is Kraken2's own clade counts. The two combined reports are byte-identical below their headers, and the two taxpasta tables carry the same value for every taxon in every sample. The plain-named one is kept. |
| `fastp/*.fastp.json`, `fastp/*.fastp.log` | Every number in the HTML report beside it, written for a machine; and what fastp printed while it ran, which MultiQC read. |
| `bowtie2/align/*.log`, `minimap2/align/*.log`, `samtools/stats/*.stats` | Host removal's per-sample alignment rates, which are in the MultiQC report and in `multiqc_data/multiqc_bowtie2.txt`. |
| `nonpareil/*.npl`, `*.npa`, `*.npc` | Nonpareil's fitting log, and the per-read redundancy values and mating vector it works the curve out from — both of which grow with the reads rather than with the answer. The `.npo`, the plots and the summary table stay. |
| `multiqc/multiqc_data/multiqc_data.json`, `multiqc.parquet`, `llms-full.txt`, `multiqc.log` | The whole report encoded again — as JSON, as parquet, as a prompt, and as its debug trace. The per-plot `.txt` files beside them, which are the numbers behind each figure, stay. |
| `multiqc/multiqc_data/multiqc_kraken.txt`, `multiqc_bracken*.txt`, `multiqc_metaphlan.txt`, `multiqc_nonpareil.txt` | Whole profile tables restated inside MultiQC's data folder, where the published tables are what anybody would use instead. |
| `multiqc/multiqc_plots/` | Each of the report's interactive figures rendered again as PNG, SVG and PDF. |
| `fastqc/*/*_fastqc.zip` | The same measurements as the `_fastqc.html` published beside it, which is also what MultiQC read. |
| one of `krona/*.html` | See below. |

**Three sets of per-sample files are kept**, all for the same reason: the rule
for deleting them is that a merged file beside them carries the same numbers,
and in these three cases none does.

MetaPhlAn's per-sample profiles carry a `coverage` and an
`estimated_number_of_reads_from_the_clade` column that
`merge_metaphlan_tables.py` drops — it reads `relative_abundance` and no other
column — so the merged report is percentages and these are where the counts
live. The `.bowtie2out.txt` and per-sample `.biom` beside them still go; the
alignments alone were 1.2 GB of a 1.4 GB folder.

Kraken2's per-sample reports carry the distinct-minimizer count that
`--report-minimizer-data` adds, which no merged table has. The `_standardized`
copy cut down from each one goes, since that is what was merged.

mOTUs' `.mgc` files are the read count per marker gene cluster that each profile
is the median over — the per-marker evidence behind a call. The `.out` and
`.log` beside them go.

**`feature_table/` is not touched either.** Nothing in it is a second encoding
of something else published here: the tables in it carry a tree, and the
taxpasta and MetaPhlAn tables they were built from do not.

`motus/motus_*_combined_reports.txt` is not deleted but is rewritten:
`drop-zero-rows` takes out the rows that are zero in every sample. A mOTUs
profile has a row for every species-level marker gene cluster in the database, so
a run that saw 1,302 of them still publishes 34,344 rows — 2.7 MB of table, 103
KB of which is the run and the rest of which is the database.

On run `vbnhm2tf` — ten samples, PlusPF and CHOCOPhlAn — the alignments alone
were 1,278 MB of 1,381 MB, **92.5% of the bytes and 298 of the 533 files**. Drop
a line from the list to publish it again; nothing else has to change.

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
does not say `bracken`. A `bracken`-named chart is the fallback for a run that
has only that; where both exist, the `bracken`-named one is **deleted** rather
than published beside its twin, since six megabytes under a name that would
mislead is worse than nothing.

If a later taxprofiler release starts drawing the Bracken chart from Bracken's
own numbers, the preference and the deletion are one condition in that loop —
and worth re-checking against the reports the way the above was, rather than
trusting the filename.

The sidebar's **Feature Tables** card has a tab per tool. Each holds the files a
requester is likeliest to want from it — labelled rather than named after the
file, since those filenames carry the tool, the database and the format from the
database sheet — a link to the listing of the tool's folder, and how much of the
run the tool classified. A tool the run did not use has no tab.

| Tab | Downloads | Folder | Classification |
|---|---|---|---|
| MetaPhlAn | Relative abundance table (`metaphlan/metaphlan_*_combined_reports.txt`), Read count table (`count_tables/metaphlan-reads.tsv`), Feature table with phylogeny (`feature_table/metaphlan-table.hdf5.biom`) | `metaphlan/` | reads mapped to a known clade |
| Kraken/Bracken | Species abundance table (`taxpasta/bracken_*.tsv`, or `taxpasta/kraken2_*.tsv` for a run without Bracken); Feature table — Plain text / JSON / HDF5 (`feature_table/feature-table.tsv`, `.json.biom`, `.hdf5.biom`) | `kraken2/`, `bracken/` | reads Kraken2 placed at phylum, genus and species |
| HUMAnN | Pathway abundances, Gene family abundances, Enzyme (EC) abundances (`humann/pathway-abundance-relab.tsv`, `gene-families-relab.tsv`, `ec-relab.tsv`) | `humann/` | reads aligned to a gene family |

**Every mapped share is counted in the reads that reached the classifiers**, the
unit the read totals are in.
[`taxprofiler_composition.sh`](../../scripts/taxprofiler_composition.sh) reads
MetaPhlAn's share per sample off the `#<n> reads processed` and
`#estimated_reads_mapped_to_known_clades:<n>` lines of each profile's header, and
HUMAnN's off `humann/alignment-summary.tsv` — what was still unaligned after the
translated search, or after the nucleotide search where no translated search
ran — then weighs each sample's share by the reads it brought to Kraken2.
MetaPhlAn counts each mate of a pair as a read of its own, which is why its own
counts are not reported as they stand.

The row of boxes is [the feature table](#the-feature-tables) in the three
formats it was written in, shaped the way the 16S pipeline shapes the same
offer: one file three ways rather than three files. It is there because a
requester computing UniFrac or Faith's PD needs the object with the tree in it.

The mOTUs profiles, the rest of the count tables, and `alpha_diversity.tsv` are
all published — they are just not what the card is for. The file index carries
each of them under the heading that says what it is for, and everything the run
published comes down through the **Download everything** button at the top of
the page.

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
| kraken2 | `pluspf_20260626` | RefSeq archaea, bacteria, viral, plasmid, human, UniVec_Core, protozoa, fungi. `db_params` is `--confidence 0.1`; `db_type` is `short;long` |
| bracken | `pluspf_20260626_bracken` | same directory as the kraken2 row; `db_params` is `--confidence 0.1;-r 150` |
| metaphlan | `mpa_vJun23_CHOCOPhlAnSGB_202403` | `db_params` is `--unclassified_estimation -t rel_ab_w_read_stats`; `db_type` is `short` |
| motus | `db_mOTU_v3.1.0` | `db_path` ends in `db_mOTU`; `db_type` is `short;long` |

**Kraken2 runs at `--confidence 0.1`, not at its default of 0.** At the default
a single distinguishing k-mer places a read at a leaf, which against a database
this size gives species-level precision around 0.16; 0.2 lifts it to about 0.76
while recall barely moves, because a large database still has plenty of k-mer
support for organisms that are really there. 0.1 is the conservative end of the
published range — most studies that set it at all use 0.2 or 0.4 — chosen
because Bracken redistributes below the threshold and because the cost is
immediately visible: the classified share on the Overview falls, and that is the
whole point. It is a flag rather than a step, so it costs no runtime.

It goes on **both** rows. Running kraken2 and bracken makes taxprofiler classify
every sample twice, once per row, and on the bracken row it must sit *before*
the semicolon, which is where that row's kraken2 parameters live.

**MetaPhlAn runs at `-t rel_ab_w_read_stats`, not at its default.** The default
`rel_ab` reports one number per clade, a relative abundance. This analysis type
reports three: that abundance, the marker `coverage` behind it, and
`estimated_number_of_reads_from_the_clade`, which is that coverage multiplied by
the clade's genome length. Coverage is genome copies, so it is an organism
count; the read estimate is a read count. Both are needed and neither is in the
default output. It is a flag rather than a step, so it costs no runtime, and in
MetaPhlAn 4.1.1 it still writes the `--biom` file the module asks for.

What it does not survive is the merge. `merge_metaphlan_tables.py` selects
`clade_name` and `relative_abundance` and no other column, so
`metaphlan_*_combined_reports.txt` is percentages however MetaPhlAn was run.
`count_tables/metaphlan-cells.tsv` and `metaphlan-reads.tsv` are the per-sample
profiles merged by `scripts/R/taxprofiler_tables.R` instead, which is why
`prune.conf` keeps those profiles.

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


## The feature tables

A requester who wants to compute UniFrac or Faith's PD needs a table and a tree
in one object. The 16S pipeline hands them one — a BIOM 2.1 file with the EPA-NG
phylogeny inside it — and this one now does too, built by
[`scripts/R/taxprofiler_tables.R`](../../scripts/R/taxprofiler_tables.R) in the
same rbiom container, called by
[`taxprofiler_composition.sh`](../results/composition.md).

Shotgun data has no sequences to build a phylogeny from. It has taxon ids. So
two tables are published, from the two profiles that can carry a tree at all:

| File | Table | Tree |
|---|---|---|
| `feature_table/feature-table.{tsv,json.biom,hdf5.biom}` | Bracken's species counts, keyed by NCBI taxon id | the NCBI taxonomy over exactly those species, branch lengths by rank depth |
| `feature_table/metaphlan-table.hdf5.biom` | MetaPhlAn's SGB relative abundances | the maximum-likelihood phylogeny published with that database |

Both trees are written out beside the tables as `taxonomy-tree.newick` and
`metaphlan-tree.newick`, and both go into the BIOM 2.1 files at
`observation/group-metadata/phylogeny`, which is the spec's own place for one.
That is the same file layout the 16S pipeline publishes, so a requester who has
loaded one has loaded the other.

### The taxonomy tree

[`taxprofiler_taxonomy_tree.sh`](../../scripts/taxprofiler_taxonomy_tree.sh)
walks `nodes.dmp` and `names.dmp` — both inside the Kraken2 database, which is
also what `taxpasta_taxonomy_dir` points at — and writes the taxonomy restricted
to the taxa the run observed, collapsed to seven ranks: domain, phylum, class,
order, family, genus, species. Ranks between those, and the unranked nodes NCBI
carries, are skipped rather than counted, so every lineage is measured on the
same scale. **Branch length is the reciprocal of the child's depth**, so a
phylum-level branch is 1/2 and a species-level one 1/7.

That assignment is not invented here. It is what WGSUniFrac (Wei and Koslicki,
*WABI 2022*) tested UniFrac against: they replaced the fitted branch lengths of
GTDB's bac120 tree with it and recovered the same clustering, swapped GTDB's
topology for NCBI's and got much the same answer again, and beat the OGU /
Web-of-Life alignment approach in a head-to-head at a fraction of its cost.
Their conclusion is the one this section rests on — a tree reflecting a general
trend among the organisms is enough for UniFrac to say something useful about
beta diversity.

**It is a taxonomy with lengths on it, not an inferred phylogeny**, and the file
index says so on the row that offers it. Faith's PD computed over it is a
taxonomic diversity; the number is not comparable with a Faith's PD from the 16S
pipeline, which is computed over a real phylogeny.

Only tips are labelled. An id that turns out to be an ancestor of another id in
the same table is emitted as an unlabelled internal node, and the R script drops
it from the table rather than inventing a place for it — which is what keeps the
tree and the table describing the same set. The same pass writes the seven-rank
lineage the feature table carries as its taxonomy, so the two agree by
construction.

The tree is built from the **Bracken** taxpasta table, whose rows are species.
For a run without Bracken it falls back to the Kraken2 table filtered to its
species rows: that table carries a row at every rank, and a clade count plus the
counts inside it is the same read twice.

### The MetaPhlAn phylogeny

MetaPhlAn publishes a Newick tree beside every database release. For the pinned
`mpa_vJun23_CHOCOPhlAnSGB_202403` it is 1.2 MB, **36,273 tips with real branch
lengths**, inferred from the same PhyloPhlAn marker set the profiler is built
on. Every tip label is the bare SGB number, which is exactly the key the
`t__SGB…` rows of a MetaPhlAn profile carry — so the merged profile taxprofiler
already publishes and this tree join with no translation step.

MetaPhlAn's `--tax_lev` defaults to `a`, so those `t__SGB` rows are in every
profile, and `merge_metaphlan_tables.py` keeps them. MetaPhlAn's own
`calculate_diversity.R` computes UniFrac from this pair, and does it through
rbiom, which is the library this pipeline was already using.

`fetch_taxprofiler_db.sh metaphlan` downloads the tree into the database
directory. The publisher lists no checksum for it, so the md5 pinned in that
script is the file as fetched; a mismatch means the release moved under its own
name. **On a cluster where the database is already installed, run that same
command again**: it fetches the tree on its own rather than re-downloading 26 GB,
and says that the tree's provenance is therefore not in the manifest beside it.

The trade is coverage: MetaPhlAn is marker-gene based and detects fewer species
than Kraken2 does, so this table describes less of the sample. What it describes
it describes on a real phylogeny.

### What it costs

Nothing in the pipeline. Both trees are post-processing: one download of 1.2 MB,
one awk pass over the taxonomy dump, and one R invocation in a container that
was already built for the 16S pipeline. A run missing any piece publishes the
tables it can and reports what it left out, rather than failing the upload.


## The count tables

The BIOM files carry a tree, which is what constrains them: every feature has to
be a tip, so anything the tree has no place for is left out. `count_tables/`
carries no tree and so has no such constraint. It is the same profiles as plain
matrices — one row per taxon, one column per sample, whole numbers — written by
the same R script.

| File | Cell is | Comes from |
|---|---|---|
| `bracken-reads.tsv` | reads | `taxpasta/bracken_*.tsv` |
| `kraken2-reads.tsv` | reads | `taxpasta/kraken2_*.tsv`, every rank placed at species |
| `metaphlan-cells.tsv` | organisms | MetaPhlAn's `coverage` column |
| `metaphlan-reads.tsv` | reads | MetaPhlAn's `estimated_number_of_reads_from_the_clade` |
| `motus-cells.tsv` | organisms | mOTUs' scaled insert counts, unchanged |

**Reads and cells are not the same measurement.** A read count is what the
sequencer produced; an organism count is what was in the sample. They differ by
genome length: a fungus with a genome ten times a gut bacterium's sheds ten
times the reads per cell. Rarefaction wants reads, since it models drawing reads
from a pool and the per-sample totals have to be sequencing effort. Comparing
species *within* a sample wants cells.

**Every column here is a number its own profiler reported.** MetaPhlAn measures
marker coverage before it measures anything else, and coverage is genome copies;
mOTUs counts universal single-copy marker genes, so its scaled insert counts are
per-organism by construction. Neither needs a genome length applied from
outside, and neither gets one. Kraken2 and Bracken count reads and know nothing
about genome size, so they publish reads and nothing else — converting them
would mean joining an external genome size table onto the profile, which is a
step nf-core/taxprofiler does not take and neither does this pipeline.

**`kraken2-reads.tsv` accounts for every classified read.** Kraken2 assigns to
whatever rank the evidence supports, and on that same run only 55% of classified
reads landed at species — 25% stopped at genus, 7.5% at family. Filtering to
species rows would silently drop 45% of the data. Instead, reads assigned below
species roll up into the species in their own lineage, and reads assigned at
genus or above become a synthetic `<taxon> unclassified` species keyed `u<taxid>`.
Column totals are preserved exactly. This is what `taxpasta_add_idlineage` is
turned on for. Bracken needs none of it — Bracken's whole job is redistributing
those reads down, and its table is 100% species already.

The BIOM files do not get this treatment: a `u<taxid>` feature has no tip on the
NCBI taxonomy tree. `feature_table/` stays as it was, and `count_tables/` is
where the complete numbers are.

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
| Estimated coverage | nonpareil | What share of the community the reads reached |
| Nonpareil diversity (Nd) | nonpareil | How varied the community is, on a log scale, from how often the same sequence recurs |
| Observed mOTUs | mOTUs | Species-level clusters found in universal marker genes |
| Effort for 95% coverage | nonpareil | How much sequencing that sample would take to get there |
| Faith's PD | MetaPhlAn's SGB tree | Branch length of a real phylogeny the sample covers |
| Read depth | kraken2 | The reads the estimates above were measured at |

That is the order the `Index` select offers them in, so **estimated coverage is
the reading the chart opens on**. It is the one that says whether the rest of the
run is worth reading: a sample the reads only reached a third of has a diversity
and a cluster count that describe the sequencing rather than the community. It is
also the reading a requester asks about first, in those words or in others.

Because the seven come off four tools that answer different questions, the
caption under the chart **names the tool each reading came from** — *"Values come
from Nonpareil."* — so a reader comparing two of them knows which is which. The
last two before read depth are the only ones that consult a classification
database; everything above them does not.

Two of them carry their own axis. Estimated coverage is a share of a whole, so
its topmost gridline is 100% rather than the best sample in the run — otherwise
every run's tallest column reaches the top and a run that covered 40% looks like
one that covered 97%. Read depth is a count, and a run holding a failed sample
beside one sequenced a hundred times as deep would draw everything but the
deepest as a hairline, so it is plotted on a square root. See [the composition
panel](../results/composition.md#what-is-in-the-panel).

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

**Faith's PD is the exception, and carries its own caveat.** Unlike everything
above it, it reads a classification database — see [The feature
tables](#the-feature-tables) for the tree — so it describes only the part of the
sample MetaPhlAn detected. `faith_pd_sgb_basis_pct` beside it is that share, and
it is a real number rather than a constant because MetaPhlAn is run with
`--unclassified_estimation`: without it MetaPhlAn renormalises its profile to
100% and the column reads ~100 on every sample.

**Its counterpart over the NCBI taxonomy is published but not charted.**
`faith_pd` and `faith_pd_basis_pct` are in `alpha_diversity.tsv`; the Overview
does not offer them. Faith's PD is a sum of branch length, so over a taxonomy it
amounts to a weighted count of the lineages a classifier named — which rises
with how much of the sample the database happens to cover rather than with how
varied the sample is. On run `zo6gtknt` it correlated **+0.57 with the classified
fraction and −0.46 with the mOTUs count**, while the SGB reading correlated
**+0.99** with that same count. The sample with the fewest mOTUs and the highest
Nonpareil coverage — the least diverse in the run by every database-free reading
— had the highest `faith_pd`.

That is the failure this pipeline already refuses Shannon and Simpson for, and
it is why the taxonomy tree is shipped for UniFrac rather than for Faith's PD.
WGSUniFrac validated UniFrac on such a tree, not Faith's PD: weighted UniFrac
compares profiles that have each been renormalised, so it does not inherit the
confound, while Faith's PD and unweighted UniFrac scale directly with how many
taxa were named.

**The unclassified reads are not on either tree, and are not put there.** Faith's
PD and UniFrac are both sums over branches, and a read that reached no taxon has
no branch — every tool in this space computes over the classified subset by
construction, and MetaPhlAn's own diversity script goes further and drops a
sample that comes back 100% unknown. Hanging an `unclassified` tip off the root
would be worse than leaving it out: it is present in every sample, so it adds
nothing to unweighted UniFrac and the same constant to every Faith's PD, and in
weighted UniFrac it would be the largest mass in the sample on a single branch —
measuring the reference database rather than the community. So the metrics are
computed over what was classified, and the fraction is published beside them.
Nonpareil's estimated coverage in the same row is the other half of that caveat:
it says how much of the community the *sequencing* reached, without consulting a
database at all.

**Nonpareil sets the QC floor.** Its k-mer mode counts 24-mers and refuses to
run — *"Reads are required to have a minimum length of kmer size"* — the moment
one of the 10,000 reads it samples is shorter than 24 bp. taxprofiler's
`shortread_qc_minlength` defaults to **15**, which is below that, so with the
default fastp keeps reads nonpareil cannot read and the task dies on whichever
samples happen to catch one. It landed on five of ten on the first run.

`TAXPROFILER_01.sh` sets `shortread_qc_minlength` to **35** instead. That is
kraken2's `k`: a read shorter than 35 bp contains no 35-mer, so the classifier
cannot place it however good it is, and keeping it only pads the total every
share on the dashboard is read against. It clears nonpareil's 24 with room.

**A curve that will not fit is one sample's diversity, not a failed run.**
`NONPAREIL_NONPAREIL` carries `errorStrategy = 'ignore'` in
[`config/taxprofiler/slurm.config`](../../config/taxprofiler/slurm.config).
Nothing downstream consumes its output — it is a reading *about* the reads
rather than a step that produces them — so the alternative is losing an hour of
profiling over a curve. The samples it did measure are plotted; the rest are
written `NA` in the table and left as gaps in the chart.

Three more things about where taxprofiler 2.0.1 wires nonpareil are worth
knowing before quoting its numbers, none of which we can change without patching
the pipeline:

- **It runs before complexity filtering and host removal.** Nonpareil sees the
  reads fastp left — which, since the complexity filter rides inside that same
  fastp call, does mean it sees them complexity filtered — but on a
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


## Functional profiling

nf-core/taxprofiler has no functional profiling — its `run_*` parameters cover
fourteen classifiers and nothing else — so HUMAnN 3.9 runs as a second Nextflow
workflow in this repository, [`workflows/humann`](../../workflows/humann/main.nf),
driven by [`taxprofiler_humann.sh`](../../scripts/taxprofiler_humann.sh) as the
first post-process step. It is a workflow rather than a loop in that script
because HUMAnN is hours per sample: a loop would serialise it inside the
2-core job the post-process stage runs in, where a workflow gets the same
Slurm-level parallelism taxprofiler itself does. Its jobs appear on the progress
page under the `humann` step, the way taxprofiler's appear under its own.

Everything it writes lands in `results/humann/`, which the dashboard's File
Explorer carries as its own **Functional profiles** section.

### What HUMAnN is doing

Three tiers, in order:

1. **Prescreen.** MetaPhlAn decides which species are present.
2. **Nucleotide search.** bowtie2 maps the reads against a database assembled on
   the spot from *only those species'* ChocoPhlAn pangenomes.
3. **Translated search.** DIAMOND `blastx` sends whatever is left against
   UniRef90.

Two consequences are worth stating plainly, because both are easy to read the
wrong way off the output:

- **HUMAnN cannot find a taxon MetaPhlAn missed.** Step 2 never looks outside
  the gate step 1 set. The `g__…s__…` labels in a by-taxon table are inherited
  from the pangenome the sequence came from, not classified from the read. It is
  not a second opinion on the taxonomy.
- **This is capacity, not activity.** A pathway present in the DNA says the
  community *can* run it. Whether it does needs RNA.

**`--taxonomic-profile` hands HUMAnN the profile taxprofiler already computed**,
so it skips its own MetaPhlAn pass — one bowtie2 alignment of every read against
the marker database — and the taxonomy stratifying the by-taxon tables is the
same taxonomy the run publishes as its taxonomic deliverable. Translated search
still dominates what HUMAnN costs.

**It is the profile that is reused, not MetaPhlAn's alignments.** MetaPhlAn
aligns reads to a small set of marker genes per species, which is enough to say
who is present and nowhere near enough to say what they carry. HUMAnN aligns the
reads again, to the whole pangenomes of the species in that profile, and then
sends what is left to UniRef90.

**The profile is rewritten before HUMAnN sees it,** and this is the part not to
delete. taxprofiler runs MetaPhlAn with `-t rel_ab_w_read_stats`, which the
[count tables](#the-count-tables) need. HUMAnN 3.9 reads the abundance out of the
*second-to-last* column of whatever it is handed — which in that layout is
`coverage`, not `relative_abundance`. Given the profile unchanged it does not
fail: it reads a species at 12% as being at 0.05%, drops nearly all of them below
its 0.01% prescreen threshold, and builds a pangenome database out of almost
nothing. `taxprofiler_humann.sh` rewrites each profile into the column layout
`-t rel_ab` writes, keeping the comment lines — HUMAnN 3.9 exits unless one of
them names `vJun23`, which is also how it picks the right profile on a run given
two MetaPhlAn databases.

**Illumina samples only.** Both of HUMAnN's search tiers are short-read
aligners, so long-read samples are passed over and named in the run's notes.

### What it publishes

Eighteen tables, which are three primary outputs crossed through two
vocabularies, two normalisations and two stratifications:

| | Reads per kilobase | Relative abundance |
|---|---|---|
| UniRef90 gene families | `gene-families-rpk.tsv` | `gene-families-relab.tsv` |
| Level-4 EC numbers | `ec-rpk.tsv` | `ec-relab.tsv` |
| KEGG Orthology | `ko-rpk.tsv` | `ko-relab.tsv` |
| MetaCyc pathways | `pathway-abundance-rpk.tsv` | `pathway-abundance-relab.tsv` |
| MetaCyc pathway coverage | `pathway-coverage.tsv` | — not an amount |

and a `-by-taxon.tsv` beside each of the nine, holding the same values split
among the species HUMAnN attributed them to. Coverage is a confidence between 0
and 1 rather than a rate, so it is not normalised.

**Sample columns are named after the samples.** HUMAnN appends what the column
measures to each one — `_Abundance-RPKs`, `_Abundance-RELAB`, `_Coverage` — and
the file name says that already, so the header is rewritten to bare sample names.
That makes these tables key the same way as `count_tables/` and the taxpasta
tables.

**KEGG modules and KEGG pathways are not produced.** Only the KO *identifier*
mapping is distributed with HUMAnN; the module and pathway definitions are
licence-restricted. `ko-rpk.tsv` is gene families summed onto KO identifiers and
is free of that — it is the mapping, not the pathway hierarchy.

**EC and KO are renamed; gene families are not.** Both name maps ship inside
HUMAnN itself and turn an unreadable identifier into a readable one over a table
small enough to scan. Naming UniRef90 accessions needs a 1 GB mapping and makes
the largest table here larger still.

`alignment-summary.tsv` is how far HUMAnN got with each sample, read off the
per-sample logs published in `humann/logs/`: how many species the prescreen put
in that sample's pangenome database, what share of reads was still unaligned
after each search tier, and how many gene families it ended with. **A sample
missing from that table is one HUMAnN could not finish** — see below.

### What it costs, and what happens when it doesn't finish

Translated search dominates, and it scales with the *unmapped* fraction rather
than with depth, so the cost is uneven in a way worth knowing before quoting a
turnaround: a 70M-read stool sample is expensive, and a swab left with 600K reads
after host depletion is nearly free — and produces a functional profile that does
not mean much. Nothing here subsamples. Deciding a depth floor, or a cap on
input reads, is a policy question rather than a code one.

**One sample that cannot be finished is not a failed run.**
[`workflows/humann/nextflow.config`](../../workflows/humann/nextflow.config)
retries a HUMAnN task once with more memory and more time, then ignores it, and
the tables are built from the samples that did finish — the same treatment
`NONPAREIL_NONPAREIL` gets, and for the same reason.

**Nothing in this step is fatal to the run either.** Missing databases, missing
reads, an unreadable profile, or the workflow failing outright all leave the
taxonomic half published exactly as it would have been: the `humann/` entries in
[`outputs.conf`](../../templates/taxprofiler/outputs.conf) match nothing and are
left out, so the dashboard simply carries no Functional profiles section. What
went wrong is appended to the run's `.notes`, which `wrike_followup.sh` reports
back on the Wrike task.

**Watch the wall clock.** `wrike_job.sh` is submitted with `--time=48:00:00`, and
that budget now covers taxprofiler *and* HUMAnN. A large run of deep stool
samples is the case that would reach it.


## Resource limits

taxprofiler has its own
[`config/taxprofiler/slurm.config`](../../config/taxprofiler/slurm.config) rather
than sharing `config/slurm.config`. taxprofiler 2.0.1 is built on the nf-core 3.x
template, which dropped `params.max_cpus` / `max_memory` / `max_time` in favour
of `process.resourceLimits`; the `params` block in `config/slurm.config` sets
nothing taxprofiler reads.

Kraken2, MetaPhlAn, mOTUs and the host-depletion aligner are sized
against the node rather than left on nf-core's `process_high` label. 16 cpus each puts two of
any of them on a 32-core node with no cores stranded. Kraken2's memory is the
figure to watch: it reads `hash.k2d` into its own heap, 110 GB for PlusPF, so the
reservation is 128 GB.

**Nonpareil is given a memory reservation it will actually use.** The module
passes `task.memory` straight to nonpareil's `-R`, which is the ceiling nonpareil
sizes its k-mer table against, so the 64 GB reserved for it is a budget rather
than a headroom estimate. Reserving less is a coarser estimate rather than a
failed task.

**The steps that read the requester's own FASTQ files are retried** — `FASTQC`,
`FASTQC_PROCESSED`, `FASTP_SINGLE` and `FASTP_PAIRED`, three times each, on any
failure rather than on nf-core's list of exit codes. Nonpareil retries too,
before falling back to the `ignore` it already had.

The reason is run `i6hehgpw`, where four of ten `FASTQC` tasks died two minutes
in with `java.io.IOException: Operation not permitted` while reading a raw
FASTQ — across three different compute nodes, unrelated to file size or sample,
on files that read back clean immediately afterwards and could not be made to
fail again under the same concurrency. `read()` has no such error in POSIX; it
came out of the GPFS driver. The root cause is in the storage layer rather than
in this pipeline, and it is not one this repository can fix.

What it *could* fix is the cost. nf-core's default strategy retries exit 104 and
130–145, and a tool that has hit an I/O error is not among them — FastQC returns
1, and 1 terminates. So one bad read on one of twenty files threw away an
eight-hour run at minute two, in a step whose output feeds only MultiQC.

**These four are the exposed ones** because
[`taxprofiler_samplesheet.sh`](../../scripts/taxprofiler_samplesheet.sh)
symlinks already-gzipped input into `raw-sequences/` rather than copying it. That
is nearly free, and the price is that a run stays coupled to whatever filesystem
the sequencing centre wrote to for its whole duration, rather than for one pass
in pre-process. Copying would confine the exposure at the cost of a full
duplicate of the inputs on `/data`.

The HUMAnN workflow has its own
[`workflows/humann/nextflow.config`](../../workflows/humann/nextflow.config),
auto-loaded from the workflow's directory, with the same executor, the same
image cache and the same node sizing. `HUMANN_PROFILE` is reserved 16 cpus and
64 GB, doubling on a retry: the reservation is for DIAMOND against the 34 GB
UniRef90 index, and HUMAnN is left on its default `--memory-use minimum` so
DIAMOND blocks that index rather than holding it whole. `HUMANN_TABLES` is
retried for the same reason the steps above are — it is the one task between
every sample's profile and the published tables.

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
references — each of which verifies every download against a checksum and
writes a manifest beside its output. Four files have no publisher checksum to
verify against: the MetaPhlAn phylogeny, pinned in the script by the md5 of the
file as fetched, and the three HUMAnN archives, whose md5s are recorded in the
manifest rather than checked — what verifies those is their contents, including
the two checks HUMAnN itself makes on a ChocoPhlAn directory. Each is a Slurm
job; run them from the login node. Steps 1–4 and 5–7 are
independent of each other and can run concurrently.

Total: about 217 GB of profiling database and 19 GB of host references — each
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

26 GB across two tars, plus the 1.2 MB SGB phylogeny for the same release, which
lands in the database directory as `<release>.nwk` and is what the
[feature tables](#the-feature-tables) put a real phylogeny into the BIOM with.
The version is pinned in the script, not resolved from `mpa_latest`, which names
a database MetaPhlAn 4.1.1 cannot read.

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

### 4. HUMAnN — ChocoPhlAn, UniRef90 and the utility mapping

Three archives, about 38 GB down and 56 GB unpacked, needing ~130 GB free while
each archive and its extracted copy coexist. The publisher lists no checksums, so
the script records the md5 of what arrived and then checks the contents: every
ChocoPhlAn filename must carry `v201901_v31`, there must be at least one
`g__*s__*` pangenome, UniRef90 must have a `.dmnd`, and the mapping directory
must hold the two files `humann_regroup_table` is called with.

```bash
sbatch --job-name=db-humann --cpus-per-task=4 --mem=8G --time=24:00:00 --output=/data/prod/nextflow/log/db_%j.out /data/prod/nextflow/scripts/fetch_taxprofiler_db.sh humann
```

Nothing else may be written into `db/humann/v201901b/chocophlan` — HUMAnN 3.9
exits if it finds a file there whose name does not carry `v201901_v31`, and a
directory holding two ChocoPhlAn versions at once is the failure people hit most.

### 5. Host reference — PhiX only

Seconds. Used by the "PhiX" answer, and by "Human + PhiX" and "Mouse + PhiX" as one
half of their combined references.

```bash
sbatch --job-name=ref-phix --cpus-per-task=32 --mem=64G --time=12:00:00 --output=/data/prod/nextflow/log/ref_%j.out /data/prod/nextflow/scripts/build_host_reference.sh phix GCF_000819615.1
```

### 6. Host reference — human + PhiX

One to two hours, ~4 GB of index. Used by the "Human + PhiX" answer.

```bash
sbatch --job-name=ref-chm13v2phix --cpus-per-task=32 --mem=64G --time=12:00:00 --output=/data/prod/nextflow/log/ref_%j.out /data/prod/nextflow/scripts/build_host_reference.sh chm13v2phix GCF_009914755.1 GCF_000819615.1
```

### 7. Host reference — mouse + PhiX

Same again. Used by the "Mouse + PhiX" answer.

```bash
sbatch --job-name=ref-grcm39phix --cpus-per-task=32 --mem=64G --time=12:00:00 --output=/data/prod/nextflow/log/ref_%j.out /data/prod/nextflow/scripts/build_host_reference.sh grcm39phix GCF_000001635.27 GCF_000819615.1
```

### 8. Verify

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

### 9. Register the pipeline in Wrike

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
