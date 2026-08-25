# The results page

Every pipeline publishes its results to S3 behind a landing page, built from a
per-pipeline template but following the same lifecycle: claimed at submission,
live as a progress view while the job runs, overwritten by the finished report.
The ampliseq template is the worked example here.

The URL handed to the requester is `index.html`, not the report itself.
[`templates/ampliseq/index.html`](../../templates/ampliseq/index.html) is a template that
`ampliseq_upload.sh` fills in and uploads last, once everything it links to is
in place: a fixed header carrying the Wrike task name, the date, and download
buttons, above an iframe holding `summary_report/summary_report.html`. Every
link in it is relative, because it is served from S3 alongside the objects it
points at.

The task name is re-read from Wrike at upload time rather than taken from the
`wrike_task_name.txt` copy recorded at submission, since the requester may have
renamed the task since filing it. That copy is the fallback, and a generic
heading the one after that.

The buttons are built from files that actually exist under `results/`, not from
a fixed list — qiime2 steps can be skipped, and `raw-sequences.zip` only exists
for pipelines that stage their reads. Each is labelled with its own filename, so
a reader knows what they are getting and can recognize it once it lands:

| Button | File |
|---|---|
| `raw-sequences.zip` | the reads `ampliseq_samplesheet.sh` staged, zipped at upload |
| `feature-table.biom` | `qiime2/abundance_tables/feature-table.biom` — the ASV abundance table, carrying taxonomy as observation metadata |

The header also carries the sample count, taken from `sample_count.txt`, which
`ampliseq_samplesheet.sh` writes into the run directory. That is the count
*after* merging entries that share a sample name, so it is the number of samples
the run actually analysed rather than the number of lines the requester
submitted. A run without that file simply leaves the figure out.

**That page starts as a live progress view.**
[`nextflow_progress.sh`](../../scripts/nextflow_progress.sh), backgrounded by
`wrike_job.sh` for the length of the nextflow stage, renders
[`templates/progress.html`](../../templates/progress.html) to the *same key* every minute —
so a requester who opens the results link early watches the pipeline work. The
final upload overwrites it.

The link is live before any of that — before the request has even been checked
over. `wrike_task_handler.sh` claims the run's S3 prefix by publishing a
`Validating` page to it, writes that address to the task's results custom field,
and then re-publishes at each point the answer changes: `Queued` once Slurm has
taken the job, `Failed` if the request is rejected or never reaches the queue.
So the link on the task leads somewhere from the first few seconds rather than
to a `NoSuchKey`, and what it leads to agrees with the task's own Status. Every
one of those steps is best-effort — a page is not worth rejecting a good request
or abandoning a queued run over. `ampliseq_upload.sh` sets the same field again
at the end, which covers a failure earlier on and marks the point where the
address stops being a promise. All of them build it through `run_results_url`,
so a task can never point somewhere its results are not.

The whole prefix is deleted only by `wrike_delete_handler.sh`, when the task it
belongs to is deleted or unfiled. A request that failed keeps its page saying so.

**The other way a dashboard ends is its expiration date.** `wrike_expiration.sh`
empties the prefix of everything but the run's records once the window the
requester asked for has passed, and republishes `index.html` from
[`templates/expired.html`](../../templates/expired.html) — so the link still
leads somewhere, and still says what the run was and how to repeat it. See
[Expiring a dashboard](../operations/expiration.md).

The numbers come from parsing nextflow's console output, which `wrike_job.sh`
tees to `nextflow.out`. Nextflow has no live status API outside Seqera Platform:
its trace file only records tasks that have already finished, and its HTML report
is written once at the end. What it does emit continuously is the same process
table an interactive terminal shows — one line per change, since ANSI output is
off in a batch job — so the table is those lines, last one per process winning.
That is not a stable interface, so every failure in that script is soft: a page
that cannot be built is skipped, and nothing about the run depends on it.

The progress page refreshes itself every minute and the finished report does
not, which is what stops a reader's browser polling once the results land.
