# The results page

Every pipeline publishes its results to S3 behind one landing page, and every
pipeline publishes the *same* landing page: the run's dashboard. It follows the
same lifecycle whichever pipeline built it — claimed at submission, live as a
progress view while the job runs, overwritten by the finished dashboard.

The URL handed to the requester is `index.html`, and that page is a navigation
bar and a frame. Everything under the bar is a page in its own right, loaded
into that frame — so the bar is the one piece of chrome that survives
navigation, and each of the pipeline's own reports is read inside it exactly as
the pipeline wrote it.

[`publish_dashboard.sh`](../../scripts/publish_dashboard.sh) renders three of
those pages from what the run produced and uploads them last, once everything
they link to is in place:

| Template | Lands as | What it is |
|---|---|---|
| [`dashboard.html`](../../templates/dashboard.html) | `index.html` | the navigation bar, and the frame the rest load into |
| [`overview.html`](../../templates/overview.html) | `overview.html` | the run itself: what it was, what it found, what to take away |
| [`files.html`](../../templates/files.html) | `files.html` | the annotated index of everything the run published |

All three are laid out to the [Alkek design
system](../../templates/redesign/DESIGN.md), and every link in them is relative,
because they are served from S3 alongside the objects they point at.

## The navigation bar

The CMMR wordmark, one link per view of the run, and the deletion date at the
far end. Overview is always first and is the view a reader lands on; the rest
are what the pipeline declared, and the file index sits where the pipeline put
it.

| Link | ampliseq | taxprofiler |
|---|---|---|
| `#overview` | `overview.html` | `overview.html` |
| `#report` | `summary_report/summary_report.html` | — |
| `#krona` | — | `krona/kraken2_<db>.html` — see [why that one](../pipelines/taxprofiler.md) |
| `#quality` | `multiqc/multiqc_report.html` | `multiqc/multiqc_report.html` |
| `#files` | `files.html` | `files.html` |

The open view is remembered in the URL fragment, so `#quality` is a link
straight to the MultiQC report with the bar still around it. Each link also
carries `target="view"`, so the bar works with scripting off — the script only
keeps the fragment and the underline in step with the frame.

**The expiration notice**, at the end of the bar. See [The expiration
notice](#the-expiration-notice) below.

## What is on the Overview

**The run's name**, as the headline, with a line naming what the analysis was
beneath it — *16S rRNA amplicon sequencing analysis*, *Shotgun metagenomic
taxonomic profiling*.

The task name is re-read from Wrike at upload time rather than taken from the
`.wrike.task_name` copy recorded at submission, since the requester may have
renamed the task since filing it. That copy is the fallback, and a generic
heading the one after that.

**The plots**, in the panel below: what was in each sample, and how varied each
sample was, under the panel's two tab-links, with the taxonomic rank, the
diversity index and the sample order beside them. One index is plotted at a
time. This is the pair of questions most requesters open the link for, which is
why it is the view they land on rather than one they have to find.
One script per pipeline — [`ampliseq_composition.sh` and
`taxprofiler_composition.sh`](composition.md) — works the numbers out and leaves
them in `composition_data.json`, which is written into the page; a run that
produced nothing to plot leaves the panel on its empty state. Which indices the
diversity chart offers comes from the same file, since the two pipelines share
none: a 16S run plots Shannon, Simpson and Pielou over its ASV table, and a
shotgun run plots what nonpareil and mOTUs measured without a classification
database in the way.

**The panel takes whatever height is left.** On a screen wide enough for the
sidebar, the Overview is exactly as tall as the frame it is read in: the chart
is drawn to the space the page has rather than the page growing a scrollbar to
fit the chart.

**Quick downloads**, at the top of the sidebar. One row per headline file the
pipeline declared, then [the whole run as a single zip](downloads.md) — the
emphasised one, since it is what most readers want before the deletion date.
That last opens a modal on the landing page rather than a tab of its own: the
zip is packaged while the reader carries on reading, and closing the modal stops
the watching rather than the build.

**Run statistics**, under them, headed by how many samples the run covered —
from `.samples.count`, the count *after* entries sharing a sample name were
merged, and the count every number under it is a count over. Then what the run
measured, in the units a sidebar has room for. An ampliseq run reports the reads
that went in against the reads that reached an ASV, the thinnest, middle and
deepest sample, how many ASVs it called, and how much of it the classifier could
place at family, at genus and at species. A taxprofiler run reports the reads it
started with, how many of them came through quality filtering, and how many were
left once the host was taken out; then the same three sample depths, and how much
of what reached the classifier it could place at phylum, at genus and at species.
The same pass that works out the plots counts all of it, into `.statistics`.

A share is written whole. On a shotgun run there is one exception, for the step
that needs it: where rounding whole would read 100% for a step that did drop
reads, it is written to a decimal instead — quality filtering keeps 99.5% of a
good run, and a sidebar calling that 100% would say nothing happened. The bars
carry two colours and mean them: a total is the institutional navy, and every
share read against it — what came through a step, what a rank could be placed at
— is the growth green.

**How the run was set up is stated over the numbers it explains**, rather than
in a row of its own: the region and the instrument sit above the read totals,
and the reference database above the classification. Each is read off the run's
`.manifest`, the same record a rerun is rebuilt from and published beside the
page as `run_state.json`, so the page
and the record cannot disagree — and a setting the manifest does not carry
leaves its note off rather than naming an empty one. On a taxprofiler run the
note over the read totals is what the reads were — *"Illumina, 2 x 151 bp"*,
*"Nanopore"* — which is measured off the reads rather than declared, so it comes
off `.statistics` with the numbers under it; the classifier and database sit over
the classification. What the run was depleted
against is named on the bar it explains, as *"Excluding PhiX"* or *"Excluding
Human + PhiX"*; a run that depleted nothing has no such bar.

**A footer** saying when the run finished, which pipeline version produced it,
and the uid. That last is there so a reader asking us about these results has
something to quote; nothing else on the page needs it.

## What is on the File Explorer

A grouped, annotated catalogue of everything the run published, with a menu of
the groups beside it. See [The file index](#the-file-index) below.

## The expiration notice

A published dashboard has a deletion date, and the bar says so at its far end:
*"Expires Sep 24, 2026 (38 days left)"*. It is written from the reader's side —
the date is the last day the link works, not the day we run the delete — and is
an amber pill against the bar's blue until the date is inside the last two
weeks, when it turns red. What a reader should do about it is in the tooltip
rather than the bar, so the notice states the deadline without shouting it.

If the date has already passed by the time the page is opened, the script that
works out the countdown rewrites the label to *"Deleted Sep 24, 2026"*. That is
the only case the wording changes in, and one the reader should not normally
reach: the expiration pass replaces the whole page well before it.

**The date is rendered into the page; the countdown is worked out in the
reader's browser.** The notice carries `data-expires="2026-09-24"`, and a few
lines of script turn that into *"(38 days left)"* when the page is opened. A
static page cannot say how long is left — it would be wrong the following week —
so it says the date, and the countdown is computed against the day the link is
actually clicked.

The date itself comes from the task's `Expiration` custom field, floored by
`wrike_dashboard_expiration` at `$WRIKE_EXPIRATION_NOTICE_DAYS` days from the
run's completion. That floor is the same one
[`wrike_expiration.sh`](../operations/expiration.md) holds the tear-down to, and
both read it from the same place, so the page cannot promise a date the daily
pass will not honour.

A run whose `Availability` answer was `Unlimited` leaves the field unset. Its
notice says *"No expiration date"* rather than disappearing, since "no date" is
itself worth stating.

## The file index

`summary_report.html` links to a good deal of what a run produces, but not to
all of it, and not with any account of what a reader would want each file for.
The File Explorer is that account.

It is built from the pipeline's **output catalogue** —
[`templates/ampliseq/outputs.conf`](../../templates/ampliseq/outputs.conf) and
[`templates/taxprofiler/outputs.conf`](../../templates/taxprofiler/outputs.conf)
— read top to bottom as `group | path | label | description`:

```
Start here | qiime2/abundance_tables/feature-table.biom | | The ASV abundance table in BIOM v2 …
Taxonomy   | dada2/ASV_tax.*.tsv                       | | Taxonomy for each ASV from the DADA2 classifier …
Sequences  | qiime2/representative_sequences/          | | The same sequences after filtering, as FASTA and …
```

- A **path** may be a glob, which lists one row per file it matches.
- A path ending in `/` is a **folder**, listed as one row linking to the
  `directory_listing.html` inside it — see [Browsable
  folders](browsable-folders.md) — and counted rather than sized.
- An entry matching **nothing is left out**, and a group left with no entries
  disappears with them. That is what makes one catalogue describe every run of
  the pipeline: an ONT run has no `dada2/` and lists `savont/` instead, a run
  without PICRUSt2 has no functional prediction group, and neither needs a
  second catalogue.

So the file the reader clicks is always a file that exists, under a heading that
says what family it belongs to, with a sentence saying what it is for. Adding an
output to the index is a line in a text file, not a change to any script.

## What a link does when you click it

Whether an output opens in the browser or lands in the downloads folder is
settled at **upload time**, by the content type each object is given, and the
page's links agree with it:

- `TEXT_EXTENSIONS` in
  [`publish_dashboard.sh`](../../scripts/publish_dashboard.sh) — `.txt`, `.tsv`,
  `.csv`, `.log`, `.yaml`, `.gff`, `.fasta` and the rest — are uploaded as
  `text/plain; charset=utf-8`, so a browser shows them. `upload_results_tree`
  makes two passes over the results folder for exactly this reason: one
  excluding those extensions and letting `aws` type the objects from their
  names, one including only those and setting the type itself.
- `DOWNLOAD_EXTENSIONS` — archives, QIIME 2 artifacts, `.biom`, `.rds` — get the
  `download` attribute on their links.
- Everything else — HTML, PDF, SVG, PNG — opens in a new tab.

Without the first of those, a browser handed `feature-table.tsv` as
`application/octet-stream` saves it instead of showing it, which is what a reader
wanting a quick look at a table least wants. It applies to every link to that
object, including the ones in the folder listing pages.

## Taking a copy of the whole thing

The one thing a client most wants before their deletion date is all of it at
once, and `https://$AWS_S3_BUCKET/download/<uid>` is that: the entire prefix,
packaged on demand into a single zip that unpacks into a working offline copy of
this page. The sidebar's **Download everything** button is that link. See
[Downloading a whole run](downloads.md).

## Before and after the dashboard

**That page starts as a live progress view.**
[`nextflow_progress.sh`](../../scripts/nextflow_progress.sh), backgrounded by
`wrike_job.sh` from the moment the job starts, renders
[`templates/progress.html`](../../templates/progress.html) to the *same key*
every ten seconds — so a requester who opens the results link early watches the
pipeline work. The final upload overwrites it.

**It starts before nextflow does**, because the stages before nextflow are the
ones a requester waits through with nothing to look at: recompressing and
staging a few hundred FASTQ files, and measuring what was sequenced, take long
enough to look like a stall. Each stage calls `report_stage` as it begins, which
writes one sentence to `.stage` in the run's state file, and the page says it
under the run's name — *Preparing your sequencing files.* The watcher is stopped
before the results are uploaded, since that upload lands the finished dashboard
on the same key; the last thing it publishes by hand is the page that says the
results are being packaged.

**Nothing is written into `nextflow.out` to make that work.** That file is
nextflow's own console output, teed for the record, and a line of ours in it
would be a line the parser has to tell apart from nextflow's — and a line in the
run's log that nextflow never printed. The stage file is beside it instead, and
the two are read independently.

The link is live before any of that — before the request has even been checked
over. `wrike_task_handler.sh` claims the run's S3 prefix by publishing a
`Validating` page to it, writes that address to the task's results custom field,
and then re-publishes at each point the answer changes: `Queued` once Slurm has
taken the job, `Failed` if the request is rejected or never reaches the queue.
So the link on the task leads somewhere from the first few seconds rather than
to a `NoSuchKey`, and what it leads to agrees with the task's own Status. Every
one of those steps is best-effort — a page is not worth rejecting a good request
or abandoning a queued run over. The upload script sets the same field again at
the end, which covers a failure earlier on and marks the point where the address
stops being a promise. All of them build it through `run_results_url`, so a task
can never point somewhere its results are not.

The whole prefix is deleted only by `wrike_delete_handler.sh`, when the task it
belongs to is deleted or unfiled. A request that failed keeps its page saying so.

**The other way a dashboard ends is its expiration date.** `wrike_expiration.sh`
empties the prefix of everything but the run's records once the window the
requester asked for has passed, and republishes `index.html` from
[`templates/expired.html`](../../templates/expired.html) — so the link still
leads somewhere, and still says what the run was and how to repeat it. See
[Expiring a dashboard](../operations/expiration.md).

**The progress page is a dial, a list, and the run's own numbers.** The dial is
every task of the run taken together, with the count it was worked out from
under it — *17 of 20 tasks*. A process nextflow has not yet given any tasks
counts for nothing rather than for nought out of nought, so the dial only ever
reports on work that exists.

Beside it, one bar per process: **navy once the process is done, green with its
stripes running while its tasks are in flight**, and an empty track for one
nextflow has not started. A process with tasks submitted but none finished still
shows a sliver, so "started" and "not started" never look the same.

**Under the dial are the run's Slurm jobs** — *3 Running*, *2 Queued*. `squeue`
is asked for every running and pending job, and a job is this run's when its
work directory is the run's own or under it, which covers both the job driving
the run and every task nextflow submits. The follow-up job that reports the
outcome is left out of the queued count: it is held on a dependency for the
whole run, and a job that cannot start until the run ends is not work anyone is
waiting on.

**Under those are the run's clocks** — how long it has been going, and how much
cpu time it has held, to the minute. The first is the elapsed time of the
longest-running of those jobs, which is the one driving the run. The second is
`CPUTimeRAW` summed over the run's jobs in the accounting database, which is the
only place the tasks that have already finished are still counted, so it only
ever goes up. Both are read at the moment the page is rendered rather than
counted up in the browser, so they step forward with each refresh.

**A run that is over still says how long it took.** Its jobs are gone from
`squeue` by then, so the counts read nought and nought — which is the true thing
to say — and the clocks would read nothing at all. They are recorded under
`.clocks` in the run's state file each time there is something to write, and
read back from it once there is not. The two blocks are left off the page
entirely only when `squeue` cannot be asked at all, and the cpu clock alone when
`sacct` cannot be.

**A run that failed carries its logs.** Under the card is a panel with the
explanation the stage that failed left in `.message`, then the tail of each
of three files the run wrote: nextflow's console output, then `nextflow.log` —
which is `nextflow.log` and not the `.nextflow.log` of a default invocation
because the pipeline files run nextflow with `-log nextflow.log` — then the
command that was run. Only the first is open; the others are there to be
unfolded. Two hundred lines of each, since the page is an object a browser
reloads, and every one of them is HTML-escaped. A run that failed before
nextflow started has none of those files and gets no panel.

The console output is cut at the last `ERROR ~ Error executing process` line,
which heads the block naming the process that died, its exit status, what it
printed and the work directory it left behind. That block is asked for by name
rather than taken as the last error of any kind, because nextflow closes a
failed run with a second one — *ERROR ~ Pipeline failed. Please refer to
troubleshooting docs* — that says nothing and would otherwise be the whole
report. A run that failed some other way has neither, and the tail of the output
stands in.

**And it stops refreshing.** The meta refresh is written by the renderer rather
than sat in the template, and a failed run's page is published without one, so
the reader's browser stops asking for a page that is never going to change —
the same way the finished dashboard does.

That panel is why [`wrike_followup.sh`](../../scripts/wrike_followup.sh)
republishes the page for a failed run. `wrike_job.sh` publishes one itself when
nextflow is what failed, but every other way a run ends — a stage before
nextflow, a job the scheduler killed — stops the progress watcher without a
word, and would otherwise leave the page frozen mid-run. The follow-up job runs
whatever happened, so it is the one place that can say so.

Those numbers come from parsing nextflow's console output, which `wrike_job.sh`
tees to `nextflow.out`. Nextflow has no live status API outside Seqera Platform:
its trace file only records tasks that have already finished, and its HTML report
is written once at the end. What it does emit continuously is the same process
table an interactive terminal shows — one line per change, since ANSI output is
off in a batch job — so the table is those lines, last one per process winning.
That is not a stable interface, so every failure in that script is soft: a page
that cannot be built is skipped, and nothing about the run depends on it.

The status the bar carries is the run's own — `Validating`, `Queued`, `Running`,
`Post-Processing` — and it pulses while the run is in it. `Failed` is red and
still, and `Completed` green, for the moment between the last stage and the
report landing.

The progress page refreshes itself every ten seconds; the finished dashboard and
a failed run's page do not, which is what stops a reader's browser polling once
a run is over either way.

## How the pages are styled

The three pages a run is read through — the bar, the Overview and the File
Explorer — share one head, inlined from
[`templates/tailwind.html`](../../templates/tailwind.html): the Tailwind
runtime, Inter and JetBrains Mono, the Material Symbols icon font, and the
design system's tokens as Tailwind's theme. It is
[`templates/redesign/code.html`](../../templates/redesign/code.html)'s own head,
lifted out of it unchanged, so the design and the pages built from it cannot
drift apart. Each page then styles itself in the utilities that head defines,
which is how the markup stays the design's markup.

The [progress page](../../templates/progress.html) and the [expired
page](../../templates/expired.html) share that head too, so every page a
requester is ever sent to — waiting, reading, or arriving after the date — is the
same design. All five fetch the Tailwind runtime and the fonts from their CDNs.

The [folder listings](browsable-folders.md) are the exception, and inline
[`templates/common.css`](../../templates/common.css) instead: there are one per
directory, they are read inside another page as often as on their own, and they
are the pages most likely to be opened out of an unpacked copy with no network.
`render_template` in [`utilities.sh`](../../scripts/utilities.sh) inlines
whichever of the two a template asks for, alongside that page's own
placeholders:

```bash
render_template "$LISTING_TEMPLATE" \
    DIR_PATH "$(escape_html "$title")" \
    UP_LINK  "$up_link" \
    ROWS     "$rows" > "$dir/$LISTING_NAME"
```

Inlined, not linked, because these pages are served from S3 next to the objects
they describe and have no origin to fetch a stylesheet from — and because a page
that outlives its stylesheet is worse than a page that repeats it.

Nothing is themed with Baylor College of Medicine marks, which we have no
permission to apply: the navigation bar carries the CMMR wordmark set in type,
and the footer names the Center and the College in text.
