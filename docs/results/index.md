# The results page

Every pipeline publishes its results to S3 behind one landing page, and every
pipeline publishes the *same* landing page: the run's dashboard. It follows the
same lifecycle whichever pipeline built it — claimed at submission, live as a
progress view while the job runs, overwritten by the finished dashboard.

The URL handed to the requester is `index.html`, not a report.
[`templates/dashboard.html`](../../templates/dashboard.html) is what lands
there, rendered by
[`publish_dashboard.sh`](../../scripts/publish_dashboard.sh) and uploaded last,
once everything it links to is in place. Every link in it is relative, because
it is served from S3 alongside the objects it points at.

## What is on it

**A header** carrying the Wrike task name on the left, and on the right a row of
small bordered notes: the sample count, the completion date, and how long the
results stay online. The three share one shape, so the corner reads as one set
rather than as a caption plus a badge, and the header carries no rule of its
own — it runs into the tab row below it, and the one rule under the tabs closes
both.

The task name is re-read from Wrike at upload time rather than taken from the
`wrike_task_name.txt` copy recorded at submission, since the requester may have
renamed the task since filing it. That copy is the fallback, and a generic
heading the one after that. The sample count comes from `sample_count.txt`,
which the samplesheet script writes into the run directory — the count *after*
merging entries that share a sample name. A run without that file leaves the
note out rather than writing an empty one.

**The uid is not on the page.** It names the run in the address bar, in the S3
prefix and on the Wrike task, and a reader of the results has no use for it. The
expired page still carries it, under `reference`, because that page is asking the
reader to quote something back to us.

**The expiration notice**, the last of those three notes. See
[The expiration notice](#the-expiration-notice) below.

**A row of tabs**, one per report the run produced plus the file index. Each
loads into the frame below without leaving the page, and the open tab is
remembered in the URL fragment — so `#quality` is a link straight to the
MultiQC report, framed by the dashboard rather than bare.

**The download buttons**, at the right end of that same row. One per headline
file the pipeline declared, plus [the whole run as a single
zip](downloads.md) — the emphasised one, since it is what most readers want
before the deletion date. They sit in the tab row but are styled as buttons, so
they do not read as another view of the page.

| Tab | ampliseq | taxprofiler |
|---|---|---|
| `#report` | `summary_report/summary_report.html` | — |
| `#profile` | [`composition_and_diversity.html`](composition.md) | — |
| `#quality` | `multiqc/multiqc_report.html` | `multiqc/multiqc_report.html` |
| `#files` | the file index | the file index |

Which of these is most useful depends on the question being asked, so none is
buried: the pipeline's own narrative report is what an ampliseq page opens on,
and what was found and how varied it was — the two things most requesters open
the link for — is the tab beside it.

**The report is set in from the tabs, not butted against them.** It sits on the
page with a margin around it and nothing drawn around it, so the chrome of the
dashboard and the chrome of whatever report is loaded into it do not run
together.

**The file index**, under the `All output files` tab — a grouped, annotated
catalogue of everything the run published, with a menu of the groups beside it.
See [The file index](#the-file-index) below.

## The expiration notice

A published dashboard has a deletion date, and the page says so in the corner of
the header: *"Available until Sep 24, 2026 · 38 days left"*. It is written from
the reader's side — the date is the last day the link works, not the day we run
the delete — and stays quiet, muted text in a bordered pill, until the date is
inside the last two weeks, when it turns red. What a reader should do about it
is in the tooltip rather than the header, so the notice states the deadline
without shouting it.

If the date has already passed by the time the page is opened, the script that
works out the countdown rewrites the label to *"Deleted on Sep 24, 2026"*. That
is the only case the wording changes in, and one the reader should not normally
reach: the expiration pass replaces the whole page well before it.

**The date is rendered into the page; the countdown is worked out in the
reader's browser.** The notice carries `data-expires="2026-09-24"`, and a few
lines of script turn that into *"· 38 days left"* when the page is opened. A
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
The `All output files` tab is that account.

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
this page. Nothing on the dashboard links to it yet. See
[Downloading a whole run](downloads.md).

## Before and after the dashboard

**That page starts as a live progress view.**
[`nextflow_progress.sh`](../../scripts/nextflow_progress.sh), backgrounded by
`wrike_job.sh` for the length of the nextflow stage, renders
[`templates/progress.html`](../../templates/progress.html) to the *same key*
every minute — so a requester who opens the results link early watches the
pipeline work. The final upload overwrites it.

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

The progress page's numbers come from parsing nextflow's console output, which
`wrike_job.sh` tees to `nextflow.out`. Nextflow has no live status API outside
Seqera Platform: its trace file only records tasks that have already finished,
and its HTML report is written once at the end. What it does emit continuously is
the same process table an interactive terminal shows — one line per change, since
ANSI output is off in a batch job — so the table is those lines, last one per
process winning. That is not a stable interface, so every failure in that script
is soft: a page that cannot be built is skipped, and nothing about the run
depends on it.

The progress page refreshes itself every minute and the finished dashboard does
not, which is what stops a reader's browser polling once the results land.

## One page, one stylesheet

Every published page — dashboard, progress, expired, the folder listings, and
the [composition and diversity page](composition.md) — shares
[`templates/common.css`](../../templates/common.css): the palette, the header
notice, the buttons, the tables. The one page that adds to it is the composition
page, which needs a categorical palette for its fills and defines those eight
colours in its own style block. `render_template` in
[`utilities.sh`](../../scripts/utilities.sh) inlines it into whichever template
it is filling in, alongside that page's own placeholders:

```bash
render_template "$LISTING_TEMPLATE" \
    DIR_PATH "$(escape_html "$title")" \
    UP_LINK  "$up_link" \
    ROWS     "$rows" > "$dir/$LISTING_NAME"
```

Inlined, not linked, because these pages are served from S3 next to the objects
they describe and have no origin to fetch a stylesheet from — and because a
page that outlives its stylesheet is worse than a page that repeats it. Each
page follows the reader's light or dark setting; nothing is themed with Baylor
College of Medicine marks, which we have no permission to apply.
