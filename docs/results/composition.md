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
| taxprofiler | [`taxprofiler_composition.sh`](../../scripts/taxprofiler_composition.sh) | the per-sample Bracken and Kraken2 reports |

Both write the same file in the same shape, so there is one Overview rather than
one per pipeline. What the two differ on is what a column of the diversity chart
counts — an ASV on a 16S run, a species on a shotgun one — and the plot data
says which, so the page names it rather than the template assuming it.

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

**Taxonomic composition** — one column per sample, stacked to 100%, under a
legend naming every taxon in it, with the panel's own control for the taxonomic
rank and one for the order the samples are in (by name, by the share of the most
abundant taxon, by read depth, or by Shannon index). The axis is labelled, and
what the chart is and how it is ordered is written under it. Hovering a column
names the sample and gives its full breakdown; hovering a legend entry gives
that taxon's mean share, how many samples it was found in, and its lineage.

**Alpha diversity** — one index at a time, chosen from the panel's own `Index`
select and drawn in the same sample order as the composition above it: the
Shannon index to begin with, then observed ASVs, read depth, the Simpson index
and Pielou's evenness. Under it, a table of the lowest, median and highest value
of every one of them.

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
answer at all to the second. Both are worked out from the kraken2-style reports
it does publish, one per sample:

| From | Gives |
|---|---|
| `bracken/<db>/<sample>_<db>.bracken.kraken2.report_bracken.txt` | the composition of each sample at every rank, and the species counts the diversity indices are computed from |
| `kraken2/<db>/<sample>_<db>.kraken2.kraken2.report.txt` | the reads no taxon was found for, and how far the classifier got |

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
  unclassified reads entered as a taxon of their own and competing for a colour
  like any other. On a shotgun run they are routinely the largest share of a
  sample, and a chart that left them out would say the opposite of what it means;
- the sidebar's rank bars are read off Kraken2 rather than Bracken, which would
  otherwise report that ~100% of reads reached species level.

**Ranks are matched by the report's own code**, `P` through `S`. A code carrying
a digit — `S1`, `G2` — names a rank between two of those, and is skipped: its
reads are already counted inside the clade above it. The lineage under each name
in the legend comes from the report's indentation, which is the only record it
carries of what sits above a taxon; a taxon is keyed by that lineage as well as
by its name, so two genera of the same name in different families stay apart.

Per sample, from the **unrarefied** species-level counts:

| Index | |
|---|---|
| Read depth | every read that reached the classifier |
| Observed species | distinct species with a non-zero count |
| Shannon, Simpson, Pielou | as above |

**No Chao1 here either**, for a different reason: a shotgun profile's rarest taxa
are the classifier's error rate as much as they are biology, so an estimator
built on what was seen once and twice reads that noise as richness.

All of it is written to `alpha_diversity.tsv` in the results root, which the file
index lists under `Start here` and the sidebar links to as *Per-sample
diversity*.

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

**taxprofiler** reports the reads the run started with, how many of them were
host, and how many the classifier placed; the thinnest, middle and deepest
sample; the share of reads resolved to phylum, to genus and to species; and how
many distinct phyla, genera and species the run named over all its samples. Reads
in come from the bowtie2 host-removal log where host removal ran — the only
count taken before anything was discarded — and the classifier's own total
otherwise. Everything else comes off the reports.

The taxa counts are written out in full rather than rounded: how many genera a
run named is not a figure to hand over as "3k".

The middle sample rather than the mean: one deeply sequenced sample drags an
average away from what the run's samples actually look like.

Both record them as key and value under `.statistics` in the **run** directory's
`run_state.json`, beside `composition_data.json` and for the same reason: both
are the page's own data rather than an output of the analysis, and every number
in them is derivable from something that is published. The upload script reads
them back when it renders the pages, and a run without the statistics gets a tile
for its sample count and nothing else.

## Colour

Only the **eleven most abundant taxa** of each rank are drawn in their own
colour; everything rarer is summed into `Other`, which wears a neutral. A rank's
eleven are usually eight or nine named taxa plus the unclassified and unassigned
shares. Past that many fills, a reader cannot reliably tell one from the next —
least of all a colour-blind one — so a twelfth taxon is not given a twelfth hue.

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
