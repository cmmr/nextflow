# Composition and diversity

Two questions come back on nearly every request, 16S or shotgun: **what was in
each sample**, and **how varied was each sample**. Neither pipeline answers
either well, so one script per pipeline works both out from what the pipeline
does produce and leaves them in `composition_data.json`, which
[`publish_dashboard.sh`](../../scripts/publish_dashboard.sh) writes into the
Overview of [the results page](index.md) — the view a reader lands on, and the
panel with a tab-link for each of those two questions.

| Pipeline | Script | Reads |
|---|---|---|
| ampliseq | [`ampliseq_composition.sh`](../../scripts/ampliseq_composition.sh) | the QIIME 2 abundance tables |
| taxprofiler | [`taxprofiler_composition.sh`](../../scripts/taxprofiler_composition.sh) | the per-sample Bracken and Kraken2 reports for composition, nonpareil and mOTUs for diversity |

Both write the same file in the same shape, so there is one Overview rather than
one per pipeline. What the two differ on, the plot data says rather than the
template assuming: what a column of the diversity chart counts — an ASV on a 16S
run, a species on a shotgun one — *which indices there are at all*, since the two
pipelines share none, and the caption naming the tools and the database the
composition was worked out from. Only the script that read the reports knows any
of it, so it writes them and the page renders what it is handed. Plot data naming
no indices falls back to the amplicon set; plot data with no caption leaves that
line off rather than describing the wrong pipeline.

The rest of this page takes the 16S half first, then the shotgun half; the
sections on the sidebar and on colour apply to both.

## Why ampliseq's own answers were not enough

**The barplot.** `qiime2/barplot/index.html` is a QIIME 2 visualisation: QIIME's
own page furniture, and a stacked chart drawn as one SVG rectangle per sample per
taxon. At six samples that is fine. At a few thousand it is hundreds of thousands
of elements, and the browser stops being able to draw it — which matters here
because a single request can carry that many samples. It is still published, and
the file index still lists it under `Taxonomy`, for a reader who wants QIIME's
own controls and its per-rank CSVs. It is not what the Overview plots.

**Alpha diversity.** ampliseq does not compute it at all for these runs. The
gate in the dev workflow is:

```groovy
if ( params.metadata && (!params.skip_alpha_rarefaction || !params.skip_diversity_indices) ) {
    QIIME2_DIVERSITY ( ... )
}
```

`--metadata` is a sample sheet of grouping variables, and a run submitted through
Wrike has none: nobody has told us which samples are cases and which are
controls. Without it there is no `qiime2/diversity/`, no
`qiime2/alpha-rarefaction/`, and nothing under `Diversity` in the file index but
the entries that never matched. Supplying a synthetic metadata file to unlock the
subworkflow would also unlock the group-comparison steps behind it, which have
nothing real to compare — so the indices are computed here instead, where they
need no grouping to be meaningful.

**There is no other switch to throw.** The dev revision this system pins exposes
`--report_css`, `--report_abstract`, `--report_logo`, `--report_title` and
`--report_template` for the summary report, and `--metadata_category_barplot` for
averaged barplots — all of which need metadata or replace the whole report
template. No parameter adds figures to what a metadata-free run publishes.

## What is in the panel

The panel is the same for both pipelines.

**Taxonomic composition** — one column per sample, under a legend naming every
taxon in it, with the panel's own control for the taxonomic
rank and one for the order the samples are in (by name, by the share of the most
abundant taxon, by read depth, or by whichever index the run leads with). The axis is labelled, and
what the chart is, how the numbers in it were made, and how it is ordered are
written under it. Hovering a column names the sample and gives its full
breakdown; hovering a legend entry gives that taxon's mean share, how many
samples it was found in, and its lineage.

**One order, in all three.** The columns stand on the axis and are stacked in the
order the legend reads — most abundant at the top, `Other` at the bottom — which
is also the order the tooltip lists them in. A reader who finds a taxon in one
finds it in the same place in the other two.

**The columns do not reach 100%, and are not meant to.** What the classifier
named nothing — a shotgun run's `Unclassified`, a 16S run's `Unassigned` — is
left out of the chart entirely: it is not a taxon anybody can act on, and it was
routinely the tallest band on the column, burying everything that was found
under one slab saying only how much of the run went unnamed. Every share is
still a share of the whole sample, so a column stops short of the top by exactly
that much, and the caption under the chart says so. The share itself is not lost:
it is in `composition_data.json`, and the sidebar reports how far down the
taxonomy the classifier did get.

**Alpha diversity** — one index at a time, chosen from the panel's own `Index`
select and drawn in the same sample order as the composition above it. Which
indices those are is the run's own: an amplicon run offers the Shannon index
first, then observed ASVs, read depth, the Simpson index and Pielou's evenness; a
shotgun run offers what nonpareil and mOTUs measured, none of which needs a
classification database, and opens on estimated coverage. Under it, the caption
says what the index is and — where the run's data names one — which tool
measured it, and a table gives the lowest, median and highest value **of that
index**. The other indices are a select away, and three numbers for an index the
reader is not looking at read as though they belonged to the one they are.

**The axis belongs to the index, not to the chart.** Most of them are drawn
straight, from zero to the best sample in the run. Two are not, and say so in
the data rather than in the page:

- **A share of a whole tops out at that whole.** Estimated coverage runs to
  100%, so the topmost gridline is 100% however well the run did. Scaled to the
  best sample instead, every run's tallest column reached the top and a run that
  covered 40% of its communities looked like one that covered 97%.
- **A count is drawn on a square root.** Read depth is the one index that is a
  count, and a run holding a sample that failed beside one sequenced a hundred
  times as deep draws every column but the deepest as a hairline. The square
  root pulls the top in while keeping zero at the floor — which a logarithm
  cannot, so the columns still start where the axis does — and the caption says
  a column twice as tall is four times the reading.

Both are drawn to a `<canvas>`. A column per sample stays a column per sample
whether there are six or six thousand; nothing is added to the document, so
there is no number of samples at which the page stops rendering. A 1,500-sample
run comes out as a 300 KB page that draws instantly.

## How the 16S numbers are worked out

| From | Gives |
|---|---|
| `qiime2/rel_abundance_tables/rel-table-<rank>.tsv` | the composition of each sample at each rank the run agglomerated to |
| `qiime2/abundance_tables/feature-table.tsv` | the ASV counts every diversity index is computed from |

Per sample, from the **unrarefied** counts:

| Index | |
|---|---|
| Read depth | reads assigned to ASVs after filtering |
| Observed ASVs | distinct ASVs with a non-zero count |
| Shannon | `−Σ p ln p` |
| Simpson | `1 − Σ p²` |
| Pielou's evenness | `H / ln S`, and 0 for a sample holding one ASV |

**A sequence classified only to `Bacteria` counts as `Unassigned`.** Silva writes
it as `Bacteria;;;;;`, which is a rank short of a classification at every rank
the chart offers, and the domain it names is the one every sequence in a 16S run
is expected to land in — so it says only that the run worked. Its counts are
summed into the `Unassigned` share, and since the chart does not draw that share
at all, both are what a 16S column falls short of 100% by. Everything else keeps
its own row: `Unclassified Pseudomonadota` names a phylum the sequence really did
reach, and is drawn like any other taxon.

**No Chao1.** It estimates the species that were missed from the ones seen
exactly once and twice, and DADA2 has already dropped most of the singletons —
so on an ASV table the estimate is not a richness anyone should act on. It is
not computed, not published in the table, and not offered in the panel.

**Nothing is rarefied.** Rarefaction exists to make counts comparable between
groups, and there are no groups here — so instead of throwing reads away, the
read depth each index was computed at is plotted beside the indices and published
in the same table. A reader can then see for themselves that the sample with 50
reads is not evidence of low richness.

All of it is written to `alpha_diversity.tsv` in the results root, which the file
index lists under `Diversity` and the panel links to.

## The shotgun half

taxprofiler publishes its answer to the first question only as Krona sunbursts
— one page per classifier, no way to read one sample against another — and no
answer at all to the second. Composition is worked out from the kraken2-style
reports it does publish, one per sample:

| From | Gives |
|---|---|
| `bracken/<db>/<sample>_<db>.bracken.kraken2.report_bracken.txt` | the composition of each sample at every rank |
| `kraken2/<db>/<sample>_<db>.kraken2.kraken2.report.txt` | the reads no taxon was found for, and how far the classifier got |
| `fastp/<sample>_<run>.fastp.json` | the reads quality filtering was given and the reads it kept, and the chemistry it read off them |
| `bowtie2/align/<sample>.bowtie2.log` | the reads host depletion was given and the reads it took |

The last two are read for the sidebar rather than for the plots; a run that
skipped either step leaves its bar off the sidebar rather than reporting a zero.

**Bracken's report is what is plotted.** Both carry a clade count at every rank,
so a rank is read straight off one rather than rolled up from a species table.
Bracken's is preferred because it redistributes the reads Kraken2 stranded at
internal nodes down to the species they came from — which is what makes a
stacked bar mean what it looks like it means. A run with no Bracken database
falls back to Kraken2's own counts.

**The Kraken2 report is read either way.** It is the only place the unclassified
reads are counted, since Bracken drops that line and renormalises over what it
placed, and the only honest account of how far the classifier got. So:

- the stacks are shares of **every read that reached the classifier**, with the
  unclassified reads counted as a taxon of their own and written into
  `composition_data.json` with the rest. The chart does not draw that taxon —
  see [above](#what-is-in-the-panel) — but it is what the denominator counts, so
  a column falls short of 100% by exactly the share of that sample the
  classifier could not name;
- the sidebar's rank bars are read off Kraken2 rather than Bracken, which would
  otherwise report that ~100% of reads reached species level.

**Ranks are matched by the report's own code**, `P` through `S`. A code carrying
a digit — `S1`, `G2` — names a rank between two of those, and is skipped: its
reads are already counted inside the clade above it. The lineage under each name
in the legend comes from the report's indentation, which is the only record it
carries of what sits above a taxon; a taxon is keyed by that lineage as well as
by its name, so two genera of the same name in different families stay apart.

### Diversity comes from somewhere else entirely

**Not from these reports.** Shannon, Simpson and Pielou over the classified
reads were what this page reported at first, and they were misleading: around
half the reads of a WGS sample reach no taxon at all, so an index computed over
the half PlusPF happens to name describes the database as much as the sample —
and two samples can differ in "diversity" because one is better represented in
RefSeq than the other. The unclassified share is the largest single wedge of most
of these charts; an index that silently drops it is not measuring the community.

Two tools that consult no classification database answer it instead:

| From | Gives |
|---|---|
| `nonpareil/nonpareil_all_samples.tsv` | the Nonpareil diversity index Nd, the share of the community the reads covered, the effort spent and the effort 95% coverage would take |
| `motus/<db>/<sample>_<db>.out` | how many species-level marker gene clusters the sample carried |

**Nonpareil measures redundancy, not taxonomy** — how often a read has already
been seen in the same dataset. Reads that keep repeating mean a community
sequenced deeply relative to its diversity; reads that are all new mean one that
was not. Every read counts towards that, named or not.

**mOTUs counts what is there rather than what has a name.** It profiles ten
universal single-copy marker genes, so it resolves species with no assembled
reference genome, which is where a Kraken2 database is blind by construction.
Richness is the count of its clusters with a non-zero read count; its
`unassigned` row is not a cluster and is left out.

**Nothing is rarefied.** Rarefaction exists to make counts comparable between
groups and there are no groups here — and nonpareil's readings are estimates of a
whole community rather than counts to be levelled.

Three details of where nonpareil sits in taxprofiler 2.0.1 shape what its numbers
mean, and are documented at length in [the pipeline
page](../pipelines/taxprofiler.md#diversity-and-coverage): it runs **before host
removal**, it reads **R1 only**, and its curves are fitted **per run**, so a
sample sequenced twice keeps its deepest run rather than an average of the two.

All of it is written to `alpha_diversity.tsv` in the results root, which the file
index lists under `Start here`, with the model fit nonpareil reported beside each
estimate — a low `model_fit` is how a reader knows not to trust the Nd next to
it. A reading nonpareil could not fit is written `NA` there and left as a gap in
the chart rather than drawn as a zero.

**The page is told what it is plotting.** The two pipelines share no index at
all, so the plot data carries the list of them — each with its name, its units
and how many decimals it is written to — and the Overview draws whatever it is
handed. Data naming none falls back to the amplicon set, which is what the first
pipeline published here. A run that measured no diversity drops that half of the
panel rather than plotting read depth and calling it diversity.

**Two passes, not two per rank.** A WGS report is megabytes per sample, so every
rank is worked out in the same two passes over the files: the first sums each
taxon across every sample, which is what decides the eleven of its rank that are
drawn, and the second emits only those eleven. Only twelve rows of sample-wide
data are held per rank, so the number of taxa a rank carries does not matter. Ten
samples of PlusPF reports — 8.6 MB, 14,300 species — take about five seconds.

## The numbers in the sidebar beside them

What the plots are drawn from also answers what the [Overview's
sidebar](index.md#what-is-on-the-overview) reports, so the same pass counts it.
Each pipeline counts the funnel its own tools measure, but both put a total at
the top and read every share against it, so two bars can be compared by eye.

**ampliseq** reports how many samples and ASVs there were, how many reads went in
and how many reached an ASV, the thinnest, middle and deepest sample, and what
share of the reads the classifier could place at family, at genus and at species.
Reads in come from `overall_summary.tsv` — cutadapt's own count of what it
processed, or DADA2's input for a run that skipped primer trimming — and
everything else from the ASV and relative abundance tables.

**taxprofiler** reports the reads the run started with, how many of them came
through quality filtering, and how many were left once the host was taken out;
the thinnest, middle and deepest sample; and the share of what reached the
classifier that it resolved to phylum, to genus and to species. It also names
what the reads were — the platform the samplesheet measured them into, and the
chemistry fastp read off them, as *"Illumina, 2 x 151 bp"* — which is the note
the read totals are headed with.

**Every bar is what was still in hand at that step**, never what was taken out.
Reads in come from fastp's own reports, which count what quality filtering was
given before anything downstream saw it; without them the bowtie2 log's count is
used, and without that the classifier's own total. fastp counts each mate of a
pair as a read of its own, so its counts are halved for a paired run: everything
below it counts pairs, and a funnel whose first bars count halves of what the
bars under them count is not a funnel.

**The rank bars are a share of what reached the classifier**, not of the reads
the run started with. By then quality filtering and depletion have taken their
cut, and reading those bars against the total would report the classifier as
having missed what it was never given.

The middle sample rather than the mean: one deeply sequenced sample drags an
average away from what the run's samples actually look like.

Both record them as key and value under `.statistics` in the **run** directory's
`run_state.json`, beside `composition_data.json` and for the same reason: both
are the page's own data rather than an output of the analysis, and every number
in them is derivable from something that is published. The upload script reads
them back when it renders the pages, and a run without the statistics gets a tile
for its sample count and nothing else.

## Colour

Only the **eleven most abundant taxa** of each rank are kept, the rest summed
into `Other`, which wears a neutral. Past that many fills, a reader cannot
reliably tell one from the next — least of all a colour-blind one — so a twelfth
taxon is not given a twelfth hue. The eleven are chosen before the unnamed share
is dropped, so a rank whose unnamed share was among them draws ten.

`Other` is the one grey, and the only band that is not a taxon. What was named
nothing is not drawn at all — see [above](#what-is-in-the-panel) — so a second
neutral would be a second thing the reader has to learn is not a finding.

The eleven are a categorical set whose *order* keeps neighbouring fills apart under
colour vision deficiency, so they are assigned in that order and never cycled.
Several of the steps sit below 3:1 against a white page, which is why the legend
above the chart **names** every taxon beside its swatch: identity is never
carried by colour alone.

Sorting the samples, or switching rank, never reassigns a colour to a different
taxon within a rank — a hue learned in one order still means the same thing in
the next.

## When there is nothing to plot

Each half is skipped if what it reads is missing, and nothing is written at all
if both are — which leaves the Overview's panel on its empty state. The step is
called before `index_directories.sh` so that the table it leaves in the results
is in the folder listings, and a failure in it is a warning rather than a failed
run: results without these plots are still results.
