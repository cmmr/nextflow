# Composition and diversity

Two questions come back on nearly every 16S request: **what was in each sample**,
and **how varied was each sample**. Neither is answered well by what
nf-core/ampliseq publishes, so
[`ampliseq_composition.sh`](../../scripts/ampliseq_composition.sh) works both out
from tables the pipeline does produce and leaves them in
`composition_data.json`, which
[`publish_dashboard.sh`](../../scripts/publish_dashboard.sh) writes into the
Overview of [the results page](index.md) — the view a reader lands on, and the
panel with a tab-link for each of those two questions.

## Why the pipeline's own answers were not enough

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

## How the numbers are worked out

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

## The numbers in the sidebar beside them

The tables the plots are drawn from also answer what the [Overview's
sidebar](index.md#what-is-on-the-overview) reports, so the same pass counts
them: how many samples and ASVs there were, how many reads went in and how many
reached an ASV, the thinnest, middle and deepest sample, and what share of the
reads the classifier could place at family, at genus and at species. Reads in
come from `overall_summary.tsv` — cutadapt's own count of what it processed, or
DADA2's input for a run that skipped primer trimming — and everything else from
the ASV and relative abundance tables.

The middle sample rather than the mean: one deeply sequenced sample drags an
average away from what the run's samples actually look like. The classified
shares are given to one decimal, since two neighbouring ranks are often within a
point of each other and rounding them to the same whole number reads as a
mistake.

They are written as key and value to `run_statistics.tsv` in the **run**
directory, beside `composition_data.json` and for the same reason: both are the
page's own data rather than an output of the analysis, and every number in them
is derivable from a table that is published. `ampliseq_upload.sh` reads them
back when it renders the pages, and a run without the statistics gets a tile for
its sample count and nothing else.

## Colour

Only the **ten most abundant taxa** of each rank are drawn in their own colour;
everything rarer is summed into `Other`, which wears a neutral. A rank's ten are
usually seven or eight named taxa plus the unclassified and unassigned shares.
Past ten fills, a reader cannot reliably tell one from the next — least of all a
colour-blind one — so an eleventh taxon is not given an eleventh hue.

The ten are a categorical set whose *order* keeps neighbouring fills apart under
colour vision deficiency, so they are assigned in that order and never cycled.
Several of the steps sit below 3:1 against a white page, which is why the legend
above the chart **names** every taxon beside its swatch: identity is never
carried by colour alone.

Sorting the samples, or switching rank, never reassigns a colour to a different
taxon within a rank — a hue learned in one order still means the same thing in
the next.

## When there is nothing to plot

Each half is skipped if the table behind it is missing, and nothing is written at
all if both are — which leaves the Overview's panel on its empty state, the same
one a taxprofiler run gets. The step is called before `index_directories.sh` so
that the table it leaves in the results is in the folder listings, and a failure
in it is a warning rather than a failed run: results without these plots are
still results.
