# Composition and diversity

Two questions come back on nearly every 16S request: **what was in each sample**,
and **how varied was each sample**. Neither is answered well by what
nf-core/ampliseq publishes, so
[`ampliseq_composition.sh`](../../scripts/ampliseq_composition.sh) works both out
from tables the pipeline does produce and writes them into one page —
`composition_and_diversity.html`, the `Composition & diversity` tab of
[the results page](index.md).

## Why the pipeline's own answers were not enough

**The barplot.** `qiime2/barplot/index.html` is a QIIME 2 visualisation: QIIME's
own page furniture, and a stacked chart drawn as one SVG rectangle per sample per
taxon. At six samples that is fine. At a few thousand it is hundreds of thousands
of elements, and the browser stops being able to draw it — which matters here
because a single request can carry that many samples. It is still published, and
the file index still lists it under `Taxonomy`, for a reader who wants QIIME's
own controls and its per-rank CSVs. It is not offered a tab.

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

## What is on the page

**Taxonomic composition** — one column per sample, stacked to 100%, with a
control for the taxonomic rank and one for the order the samples are in (by name,
by the share of the most abundant taxon, by read depth, or by Shannon index).
Hovering a column names the sample and gives its full breakdown.

**Alpha diversity** — read depth, observed ASVs, the Shannon index and Pielou's
evenness, one small chart each, in the same sample order as the chart above, with
a table of the lowest, median and highest value of each index including Chao1 and
Simpson.

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
| Chao1 | Chao 1984, bias-corrected — `S + F₁(F₁−1) / 2(F₂+1)` |
| Shannon | `−Σ p ln p` |
| Simpson | `1 − Σ p²` |
| Pielou's evenness | `H / ln S`, and 0 for a sample holding one ASV |

**Nothing is rarefied.** Rarefaction exists to make counts comparable between
groups, and there are no groups here — so instead of throwing reads away, the
read depth each index was computed at is plotted beside the indices and published
in the same table. A reader can then see for themselves that the sample with 50
reads is not evidence of low richness.

All of it is written to `alpha_diversity.tsv` in the results root, which the file
index lists under `Diversity` and the page links to.

## Colour

Only the **eight most abundant taxa** of each rank are drawn in their own colour;
everything rarer is summed into `Other`, which wears a neutral. Past eight fills,
a reader cannot reliably tell one from the next — least of all a colour-blind
one — so a ninth taxon is not given a ninth hue.

The eight are a validated categorical set, and the *order* they are assigned in
is what keeps neighbouring fills apart under colour vision deficiency, so they
are assigned in that order and never cycled. Three of the light-mode steps sit
below 3:1 against a white page, which is why the legend is a **table** carrying
each taxon's name, lineage, mean share and prevalence rather than a row of
swatches: identity is never carried by colour alone.

Sorting the samples, or switching rank, never reassigns a colour to a different
taxon within a rank — a hue learned in one order still means the same thing in
the next.

## When the page is not written

Each half is skipped if the table behind it is missing, and the page is not
written at all if both are — a run that produced no ASV table has no tab, because
[`dashboard_view`](index.md#what-is-on-it) only adds a tab for a file that
exists. The step is called before `index_directories.sh` so that the two files it
leaves behind are in the folder listings, and a failure in it is a warning rather
than a failed run: results without this page are still results.
