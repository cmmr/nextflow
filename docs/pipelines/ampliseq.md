# The ampliseq pipeline

One pipeline handles every 16S library. A requester names neither a platform nor
a variable region — `AMPLISEQ` measures both from the reads.

## The version it runs

[`AMPLISEQ_01.sh`](../../pipelines/AMPLISEQ_01.sh) pins nf-core/ampliseq to a
**commit**, not a tag or a branch:

```bash
-r 827a6b77be8e9252ef3ae99aed32b807dd703fc0
```

That commit is `2.19.0dev` — the changelog calls the same thing `3.0.0dev` —
from 2026-08-20. It is ahead of the 2.18.0 release because **Oxford Nanopore
support is unreleased**: `--sequencing_type nanopore` and the Savont ASV caller
exist only on `dev`, and `-r dev` would move under a rerun.

Two consequences worth knowing:

- **`FW_primer` and `RV_primer` are now `primer_fwd` and `primer_rev`.** That
  revision also renames `--illumina_pe_its` → `--illumina_pe_readthrough`,
  `--extension` → `--input_folder_extensions`, and `--classifier` →
  `--qiime_classifier`, and it replaces the `--pacbio` / `--iontorrent` /
  `--single_end` flags with one `--sequencing_type`.
- **`sample_inference` is pinned to `pooled`**, which is that revision's new
  default, so a later change to the default cannot move results. Savont rejects
  the third value, `pseudo`, outright.

To move to a newer commit, add `AMPLISEQ_02.sh` with the new SHA and repoint
`AMPLISEQ.sh` at it. Runs already finished keep reproducing against this one.

## What the requester can change

On `Settings: Default` the form attaches none of the optional fields, so the
pipeline's own defaults stand — SILVA 138.2 for DADA2 taxonomy, no QIIME2
classifier, no Kraken2 read classification, no PICRUSt2, and `exclude_taxa` of
mitochondria, chloroplast and Francisella.

`Settings: Custom` attaches five
[form answers](../wrike/account.md#the-request-forms-questions), each titled
after the parameter it sets: `--dada_ref_taxonomy`, `--qiime_ref_taxonomy`,
`--kraken2_ref_taxonomy`, `--picrust` and `--exclude_taxa`. Picking a QIIME2 or
Kraken2 database turns that classification on, which is real extra runtime for a
second opinion on the same ASVs.

**The three database questions do not offer the same SILVA**, because ampliseq
does not carry the same one for each: `silva=138.2` exists only under
`dada_ref_databases`, so QIIME2 and Kraken2 stop at `silva=138`.

## Preparing a run

[`ampliseq_samplesheet.sh`](../../scripts/ampliseq_samplesheet.sh) turns the lab's
whitespace-delimited `sample fastq_1 [fastq_2]` sheet into what ampliseq
requires: it recompresses `.bz2` and plain FASTQ to `.gz`, merges entries sharing
a sample name, and sanitizes names to `[A-Za-z][A-Za-z0-9_]*`. Everything lands
in `raw-sequences/` as `<sample>_seqs_{1,2}.fq.gz`; already-gzipped inputs are
symlinked rather than copied, so the directory is nearly free in the common case.
It also derives ampliseq's `run` column by hashing each sample's source
directory, which groups samples that were sequenced together for error-model
training, and records the post-merge sample count as `.samples.count` in the
run's state file.

**A line with no `fastq_2` is single-end** — a MinION run, or single-end
Illumina — and the `fastq_2` column is left off the generated sheet entirely
rather than left empty. ampliseq requires only `sample` and `fastq_1`, but it
derives one read layout for the whole pipeline rather than one per sample, so a
sheet that mixes the two is refused with a message naming the offending line.

[`ampliseq_detect_region.sh`](../../scripts/ampliseq_detect_region.sh) then measures
what was sequenced and writes `detected_params.yaml` — `sequencing_type`,
`primer_fwd`, `primer_rev`, `skip_cutadapt`, and for ONT `asv_calling` and
`savont_options` — which `wrike_job.sh` layers over the pipeline's defaults.

[`ampliseq_upload.sh`](../../scripts/ampliseq_upload.sh) zips `raw-sequences/`
into the run's directory on [the Globus collection](../operations/globus.md)
(`zip -0` — the reads are already compressed), works out
[what the Overview plots](../results/composition.md), deletes what the run wrote
for itself, gives every folder a listing page, uploads the folder to
`s3://$AWS_S3_BUCKET/nxf/<uid>/`, publishes the whole dashboard as a second zip
beside the reads, and writes the report URL to a Wrike custom field. Nextflow's
`work/` directory is deliberately left behind.

**What is deleted first** is named in
[`templates/ampliseq/prune.conf`](../../templates/ampliseq/prune.conf), and
[`prune_results.sh`](../results/index.md) takes it out of `results/` outright
before anything is indexed — so the listings, the file index, the zip and the
bucket cannot come to describe different things. An amplicon run is small enough
that little of this is about storage; it is about a file index a reader can read.

| Deleted | Why |
|---|---|
| `dada2/chunks/` | DADA2 classifies the ASVs in chunks and concatenates the results. With one chunk — which is every run we do — the chunk and the concatenation are byte-identical to `dada2/ASV_tax*.tsv` beside them. |
| `dada2/QC/svg/` | The read-quality profiles and fitted error models, published as PDF in the folder above at a twentieth of the size. |
| `dada2/QC/*plotQualityProfile.txt` | One three-byte file per plot, saying how many files it read. The number is in the plot's own title. |
| `porechop_abi/*.log` | A few hundred kilobytes per sample of every adapter Porechop considered. What came off is in the MultiQC report, in `multiqc_data/porechop.txt`, and in `overall_summary.tsv`. |
| `multiqc/multiqc_data/multiqc_data.json`, `multiqc.parquet`, `llms-full.txt`, `multiqc.log` | The whole report encoded again — as JSON, as parquet, as a prompt, and as its debug trace. The per-plot `.txt` files, which are the numbers behind each figure, stay. |
| `multiqc/multiqc_plots/` | Each of the report's figures rendered again as PNG, SVG and PDF. |
| `fastqc/*_fastqc.zip` | The same measurements as the `_fastqc.html` published beside it. |

The per-sample FastQC reports themselves are **kept**: MultiQC summarises them
but does not carry each file's own duplication and overrepresented-sequence
detail, and they are the closest thing the run publishes to a statement about
the reads as they arrived.

What the requester actually opens — the landing page, and the live progress view
it starts out as — is [The results page](../results/index.md). What it offers of
this pipeline's output is declared in a handful of lines of that script and one
text file:

```bash
dashboard_view report  "Analysis Report" "summary_report/summary_report.html"
dashboard_view quality "Quality Control" "multiqc/multiqc_report.html"
dashboard_index_view   "File Explorer"
dashboard_button "qiime2/abundance_tables/feature-table.biom"
dashboard_bundle "Raw sequencing data" "$FASTQ_URL"
dashboard_bundle "All result files" "$(globus_run_url "$RUN_ID" dashboard.zip)"
dashboard_stat_group "READ TOTALS"    "$SEQUENCED"
dashboard_stat_group "CLASSIFICATION" "$REFERENCE"
```

plus [`templates/ampliseq/outputs.conf`](../../templates/ampliseq/outputs.conf),
the annotated index of everything else — abundance tables, taxonomy, sequences,
diversity, PICRUSt2, QC, the R objects, and the record of how the run was set
up. Entries whose files a given run did not produce are skipped, so an ONT run
lists `savont/` and no `dada2/` without a catalogue of its own.

Those are the links of the navigation bar, after the Overview every run opens
on. `$SEQUENCED` and `$REFERENCE` are read off the state file's `.manifest` —
the region and instrument, and the reference database — and each is stated over
the numbers it explains rather than in a row of its own. The numbers themselves,
and the Overview's plots, come from the `composition_data.json` and the
`.statistics` that
[`ampliseq_composition.sh`](../results/composition.md) works out of the ASV and
abundance tables.

## Dressing the summary report

ampliseq renders its own report from an R Markdown template, and exposes the
pieces of it worth replacing. Two are set in
[`AMPLISEQ_01.sh`](../../pipelines/AMPLISEQ_01.sh):

| Parameter | Set to |
|---|---|
| `report_abstract` | [`templates/ampliseq/abstract.md`](../../templates/ampliseq/abstract.md) — replaces the pipeline's `Abstract` section with one written for the client |
| `report_title` | `Amplicon sequencing analysis` |

**`report_css` is not set.** The report keeps the styling nf-core ships it with,
so what a reader sees inside the dashboard's frame is the pipeline's own report
rather than a restyled one, and a change to that template upstream cannot leave
a stylesheet of ours fighting it.

`report_logo` is left at its default too. Attribution stays where it belongs —
the report's subtitle names `nf-core/ampliseq` and its version, and the abstract
links to the project. **Nothing here carries Baylor College of Medicine marks**,
which we have no permission to apply.

## How the platform is detected

Read layout comes from the samplesheet that was just written; platform from how
many reads are longer than 1000 bases, the same line
[`taxprofiler_samplesheet.sh`](taxprofiler.md) draws. A run is long-read when at
least 5% of its reads are that long. Together they give ampliseq's
`sequencing_type`:

| | short reads | ≥5% of reads over 1000 b |
| --- | --- | --- |
| **paired** | `illumina_pe` | refused — no paired-end instrument reads that long |
| **single** | `illumina_se` | `nanopore` |

**A fraction is read rather than a median** because an ONT run's read lengths are
bimodal — unusable short reads on one side, full-length amplicons on the other —
and its median can sit in the trough between them and call the run Illumina. No
Illumina instrument produces a read over 1000 bases at all, so any real
population of them settles the question.

**PacBio HiFi is also single and long, and read length cannot tell it from ONT.**
Long single-end reads are called `nanopore` because that is what the lab runs.
There is no way to request PacBio: the form does not ask, and it has no free-text
parameter field. Supporting it means adding the question, or a
`PACBIO_16S` pipeline of its own.

`--sequencing_type nanopore` is not a DADA2 setting — it selects a different
workflow: Porechop_ABI → Chopper → Cutadapt → [Savont](https://doi.org/10.64898/2026.05.26.727271)
in place of DADA2, which has no error model for ONT reads. The detector also
writes `asv_calling: savont` and `savont_options: "--fl-16s"` explicitly, even
though ampliseq reaches both from `sequencing_type` alone (`asv_calling` defaults
to `auto`, `savont_options` to `--fl-16s`), so the run's record names them rather
than relying on a default holding still.

## How the region is detected

The five regions the system supports, in *E. coli* K-12 MG1655 16S numbering:

| Region | Primers | Amplicon |
| --- | --- | --- |
| `16SV1V3` | 27F / 534R | 8–534 |
| `16SV3V5` | 357F / 926R | 341–926 |
| `16SV4` | 515F / 806R | 515–806 |
| `16SV5V6` | 806F / 1053R | 785–1073 |
| `16SFULL` | 27F / 1492R | 8–1513 |

Up to eight samples are read end to end, and a reservoir keeps a uniform sample
of each file's reads rather than its head — an ONT run writes its shortest reads
first, and they are not the library. Of that sample, 2 000 reads go to the
aligner for a short-read run and 10 000 for a long-read one, which carries more
off-target material and so needs a wider sample to find 16S inside it. They are
aligned with `vsearch --usearch_global` to the landmark 16S genes that
[`build_16s_reference.sh`](../../scripts/build_16s_reference.sh) assembled, and every
hit is translated into *E. coli* numbering through `db/16s/ecoli_positions.tsv`.

A short query is a probe cut from inside the amplicon, so nearly all of it is
16S and it is held to `--query_cov 0.80`. A long read still carries its barcode
and adapters, and often more than one copy of the amplicon, so it is asked
instead to cover a third of the gene (`--query_cov 0.30 --target_cov 0.30`). The
host-DNA products a 16S primer pair also amplifies carry the primers without the
gene, and never reach that.

Landmark bases that are insertions relative to *E. coli*, and the ragged ends
soft-clipped when the landmark was aligned to it, have no row in
`ecoli_positions.tsv`. A full-length amplicon ends in exactly those, so a hit
whose end has no *E. coli* position is snapped up to 25 bases inward to the
nearest base that does, rather than discarded.

Which coordinates are readable depends on what the reads are:

- **Paired.** Mate 1 aligns to one strand of the gene and mate 2 to the other, so
  the median 5′ end of each mate is one end of the amplicon. Reads are cut to
  their first 150 bases first: the 5′ end is set by where the primer bound, while
  the 3′ end moves with read length, quality trimming and adapter read-through.
- **Single and long.** One read spans the whole amplicon, so its own two ends are
  the amplicon's. vsearch reports target coordinates ascending whichever way a
  read aligned, so ONT's mixed orientation needs no untangling — and this is the
  easiest of the three cases, not the hardest.
- **Single and short.** Only the end the reads start at can be measured. The
  region has to be identified from that one coordinate, at half the drift
  allowance, and `16SV1V3` and `16SFULL` cannot be told apart at all since both
  start at position 8.

Each region is then scored in four variants, since either end may still carry its
primer or may have had it trimmed off before the reads arrived. The closest wins.
One measurement therefore answers both questions — which region, and whether
`skip_cutadapt` should be true — and the four variants of a region span at most
39 bases while neighbouring regions sit at least 157 apart, so they never blur
the choice between regions. When only one end was measured, the far primer takes
the near one's answer: a library is trimmed at both ends or at neither.

The answer is refused rather than guessed when:

- fewer than 200 reads per mate align to 16S at all,
- fewer than 80% of a paired mate's reads agree on a strand, or both mates read
  the same strand,
- the best-fitting region is more than 60 bases off (30 with one end), or
- the runner-up region is within 120 bases of it.

Each of those is reported to the requester as its own message. The measurement is
written to `region_detection.txt` and published with the results, and the region,
the platform and the primer state go into the comment the bot posts when the run
ends.

**Detection is skipped for a rerun**, whose parameters are already fixed by the
run it reproduces. There is no other way past it: a library the detector cannot
place is a failed run, since the form has no free-text parameter field.

## Building the landmark reference

One-time cluster setup, run once rather than as part of any pipeline:

```bash
sbatch --cpus-per-task=4 --mem=8G --time=02:00:00 scripts/build_16s_reference.sh
```

It pulls the 16S gene out of eight RefSeq genomes — one per phylum a 16S survey
is likely to return, plus an archaeon — checksums every download against NCBI's
own `md5checksums.txt`, and aligns each gene to the *E. coli* one to record where
every base sits in *E. coli* numbering. Reads are aligned to landmarks rather
than to a taxonomy database because the detector needs a coordinate, and a
coordinate needs a reference whose numbering is fixed; one genome per phylum is
enough, since a read need only find something close enough to align and every
landmark carries the same coordinates.

It writes into `db/16s/`:

| File | |
| --- | --- |
| `landmarks.fasta` | the 16S genes, one per genome, named by accession |
| `landmarks.sam` | each landmark aligned to the *E. coli* landmark |
| `ecoli_positions.tsv` | landmark, position in it, homologous *E. coli* position |
| `manifest.json` | what went in, from where, and how |

The build refuses to write anything if the *E. coli* 16S it fetched is not 1 542
bases with the 515F site at position 515 — every coordinate in the region table
above assumes that numbering.
