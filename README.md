# nextflow

Amplicon (16S) and WGS pipelines for CMMR, driven from Wrike.

A user submits the **"Bioinformatics Pipeline"** Wrike request form, naming a
pipeline and attaching a samplesheet — or runs **`run 16Sv4 samples.txt`** on the
login node, which files the same request. A few seconds later the bot replies on
the resulting task that the job is queued; when it finishes, the task carries a
link to an S3-hosted report and a zip of the raw reads. Everything in between is
what this repository does.

There is no web service and no database. The whole system is bash scripts on the
cluster login node plus a Slurm queue, glued to Wrike by an SQS queue.

---

## How a run happens

```mermaid
flowchart TD
    U["User submits request form<br/>(pipeline + samplesheet)"] -->|TaskCreated| T{{"Task in the<br/>'Dashboards' folder"}}
    CLI["<i>or</i> run 16Sv4 samples.txt<br/><i>login node</i>"] --> ST["Task staged in the<br/>bot's Personal space<br/>+ samplesheet attached"]
    ST -->|TaskParentsAdded| T
    T --> W[Wrike webhook]
    W --> L["AWS Lambda<br/>wrike-webhook-bridge<br/>(verifies HMAC signature)"]
    L --> Q[(AWS SQS queue)]
    Q --> D["wrike_sqs_listener.sh<br/><i>daemon, login node</i>"]
    D -->|"TaskCreated /<br/>TaskParentsAdded"| C[wrike_task_handler.sh]
    D -->|TaskDeleted / TaskParentsRemoved| X[wrike_delete_handler.sh]
    C -->|sbatch| J["wrike_job.sh<br/><i>compute node</i>"]
    J -->|"sbatch --dependency=afterany"| F[wrike_followup.sh]
    J --> S3[(S3 results)]
    F --> R["Reply comment<br/>+ Status on the task"]
    X --> CL["scancel jobs, delete S3 results,<br/>delete run directory"]
```

1. **Wrike → SQS.** A webhook on the "Dashboards" folder publishes JSON to an API
   Gateway endpoint backed by a Lambda, which checks an HMAC signature against a
   pre-shared secret and pushes the raw body onto SQS. Registration commands,
   example payloads, and the Lambda source are in
   [config/webhooks.md](config/webhooks.md).

   **A request arrives as one of two events, because there are two ways into that
   folder.** The request form creates its task there outright, which is
   `TaskCreated`. [`run`](run) builds its task somewhere else first and files it
   afterwards, which is `TaskParentsAdded`. They mean the same thing and go to the
   same handler.

2. **SQS → handler.** [`wrike_sqs_listener.sh`](scripts/wrike_sqs_listener.sh) runs
   forever on the login node, long-polling SQS. It deletes each message before
   dispatching it (so a crashed handler can't cause the same job to run twice) and
   routes on `eventType`. Handlers are backgrounded so a slow one never stalls
   polling. It pauses entirely while Slurm is unreachable.

   `TaskCreated` is unambiguous — a task appearing in that folder is a request.
   The two parent events are not, because they fire for *any* parent change on a
   task the webhook can see, so both are checked against
   `WRIKE_DASHBOARDS_FOLDER_ID` before being acted on. The payload field is
   `addedParents` / `removedParents`; getting that name wrong fails silently, as
   the check simply never matches.

3. **Validation.** [`wrike_task_handler.sh`](scripts/wrike_task_handler.sh)
   is deliberately lightweight — it does no real work, only checks. In order: is
   the pipeline named in the task's custom field a real pipeline? is exactly one
   samplesheet attached, with a plausible extension? is the S3 prefix this task
   derives still unpublished? **Every failure replies to the user on the Wrike
   task and exits 0** — a rejected request is a normal outcome, not a daemon
   error.

   The pipeline field is free text, so users can pin an exact version
   (`16Sv4_01`) rather than only picking from the form's dropdown. It is
   therefore validated as a *name* — `^[A-Z0-9_]+$`, then a file that exists —
   before it is ever used as a path, because `wrike_job.sh` sources what it
   resolves to.

   The last check is that the run's derived S3 prefix is still unpublished; a
   collision there is rejected like any other bad request, since a new task
   derives a new uid.

   On success it creates `$NEXTFLOW_DIR/tmp/<uid>/`, records the task ID and
   title in `wrike_task_id.txt` and `wrike_task_name.txt` there, and submits two
   Slurm jobs. Creating that directory
   with plain `mkdir` is also the idempotency guard: SQS delivers at least once,
   and a redelivered event would otherwise put a second pipeline behind the same
   uid. It also covers the case of a task that somehow produces both entry
   events.

4. **The run.** [`wrike_job.sh`](scripts/wrike_job.sh) downloads the samplesheet,
   sources the requested pipeline definition, and runs its three stages:
   pre-process → nextflow → post-process. It never comments on Wrike itself; it
   records progress in `status.txt` and any user-facing explanation in
   `message.out`.

5. **The report.** [`wrike_followup.sh`](scripts/wrike_followup.sh) is submitted
   with `--dependency=afterany`, so it runs whether the job succeeded, failed, or
   was killed by the scheduler. It reads `status.txt` and `message.out` out of the
   run directory and posts the outcome. A successful run's directory is deleted
   (results are already in S3); a failed one is kept for inspection.

6. **Teardown.** Removing the "Dashboards" tag from a task, or deleting the task,
   fires the same webhook. [`wrike_delete_handler.sh`](scripts/wrike_delete_handler.sh)
   cancels any Slurm jobs for that task, purges its S3 prefix, and removes the run
   directory. Every step is best-effort, because a run may never have created the
   thing being removed.

   It checks *which* parent was removed before destroying anything. A task can sit
   in several folders at once — every task `run` submits keeps its staging space
   as a parent — and unfiling one of those must not tear down a run that is still
   on the dashboard.

### Conventions worth knowing up front

These carry most of the system's state, and nothing works if you break them:

- **The uid is the primary key; the Wrike task ID is what it is derived from.**
  A run's *uid* is eight base32 characters — `derive_uid` HMACs the Wrike task ID
  with `RUN_ID_SALT` — and it names the run directory (`tmp/<uid>`), the Slurm
  `--job-name` of both jobs, and the S3 prefix (`nxf/<uid>/`) the results are
  published under. Eight characters is short enough to keep a results URL
  readable and only safe because `wrike_task_handler.sh` checks S3 for the prefix
  before accepting a request: a collision is a rejected request, not one
  client's results landing on another's.
  Anything holding a task ID can recompute the uid, which is what lets
  `wrike_delete_handler.sh` find a run to tear down when the task it belonged to
  no longer exists. The Wrike task ID cannot serve as any of those names itself:
  Wrike may issue IDs containing `:` and `=`, which S3 wants URL-encoded and
  Apptainer reads as bind-spec separators, and at up to 256 characters they can
  outrun a 255-byte path component.
- **The derivation runs one way only.** A uid does not lead back to a task, so
  `wrike_task_handler.sh` writes the task ID to `wrike_task_id.txt` in the run
  directory, and everything on the compute node reads it back with
  `read_wrike_task_id` rather than recovering it from `$PWD`. Scripts that only
  need the uid take it from `$PWD` — it is the directory's name.
- **The run directory is the message bus.** `status.txt` (last stage reached;
  `Completed` only on success) and `message.out` (optional user-facing text) are
  how a compute node tells `wrike_followup.sh` what happened. `message.out` is
  created empty with the run directory, and the `fail` helper writes to it
  wherever it finds it — which is what makes any script in the run, down to a
  pipeline's own pre- and post-process steps, able to explain itself to the
  requester without knowing anything about Wrike.
- **`nextflow_command.sh` is the record.** `wrike_job.sh` writes the fully
  expanded nextflow command to that file and then executes it, rather than
  running nextflow directly — so the record can never drift from what actually
  ran. It is copied into the published results.

---

## Repository layout

```
.env                  Non-secret environment; sources secrets/.env, utilities.sh,
                      and wrike_api.sh. Sourced by every script here; does not
                      touch PATH.
secrets/.env          Wrike token and AWS credentials. Credentials only; not in git.
run                   CLI entry point. Files a Wrike request, then gets out of the way.

scripts/
  utilities.sh             log, warn, fail, and the uid helpers. Sourced by .env.
  wrike_api.sh             Wrike REST helpers and object IDs. Likewise sourced.
  wrike_sqs_listener.sh    The daemon. Polls SQS, routes events.
  wrike_task_handler.sh    Validates a form request, submits it. Login node.
  wrike_delete_handler.sh  Tears a run down. Login node.
  wrike_job.sh             Runs one pipeline end to end. Slurm batch job.
  wrike_followup.sh        Reports the outcome to Wrike. Slurm batch job.
  nextflow_progress.sh     Publishes the live progress page. Backgrounded by wrike_job.sh.
  ampliseq_samplesheet.sh  PRE_PROCESS_CMD for the ampliseq pipelines.
  ampliseq_upload.sh       POST_PROCESS_CMD for the ampliseq pipelines.

pipelines/            One file per pipeline; see below.
config/
  slurm.config        Nextflow executor + apptainer settings used by the pipelines.
  local.config        Same, for running off the scheduler.
  progress.html       Live progress page template. Pipeline-agnostic.
  ampliseq/
    index.html        Landing page template for a published ampliseq run.
  webhooks.md         Webhook registration commands and the Lambda source.
```

Working directories that exist only on the cluster: `assets/`, `bin/`, `cache/`,
`db/` (gitignored), plus `log/` and `tmp/` (created at runtime).

---

## Pipelines

A pipeline file is **not** a script — it is a set of variable assignments that
`wrike_job.sh` sources:

| Variable | Required | Purpose |
| --- | --- | --- |
| `NEXTFLOW_ARGS` | yes | Bash array; the full nextflow command line, already split |
| `PIPELINE_NAME` | no | Exact version recorded on the Wrike task, e.g. `16Sv4_01` |
| `PRE_PROCESS_CMD` | no | Runs before nextflow, in the run directory |
| `POST_PROCESS_CMD` | no | Runs after nextflow succeeds |

Sourcing (rather than executing) is what lets a pipeline file also write its own
params file as a side effect — see the `cat << EOF > ampliseq_args.yaml` block in
any of the `_01` files.

**Each versioned pipeline pins its own nextflow arguments as well as its params.**
Nothing about the command line is defaulted by `wrike_job.sh`. That is the point:
re-running `16SV4_01` a year from now reproduces this run exactly.

### Naming

Two names resolve to the same run, by chained `source`:

```
16SV4.sh  →  16SV4_01.sh      (the actual definition)
```

`16SV4_01.sh` is immutable once it has been used in production. To change
parameters, add `16SV4_02.sh` and repoint `16SV4.sh` at it; old tasks keep
reproducing their original run. The request form's pipeline field is matched
case-insensitively (`16sv4` works) and the resolved name is uppercased, so a user
who needs a specific version can type `16Sv4_01` instead of taking the dropdown's
default.

Currently defined: **16SV1V3** (27f/534r), **16SV3V5** (357f/926r),
**16SV4** (515f/806r), **16SV5V6** (806f/1053r) — all nf-core/ampliseq 2.18.0
against SILVA 138.2.

### Adding a pipeline

1. Write `pipelines/<NAME>_01.sh` setting the variables above.
2. Add `pipelines/<NAME>.sh` containing
   `source "$NEXTFLOW_DIR/pipelines/<NAME>_01.sh"`.
3. Add `<NAME>` as an option to Wrike's "Pipeline Name" custom field.

---

## The ampliseq pre/post steps

[`ampliseq_samplesheet.sh`](scripts/ampliseq_samplesheet.sh) turns the lab's
whitespace-delimited `sample fastq_1 fastq_2` sheet into what ampliseq requires:
it recompresses `.bz2` and plain FASTQ to `.gz`, merges entries sharing a sample
name, and sanitizes names to `[A-Za-z][A-Za-z0-9_]*`. Everything lands in
`raw-sequences/` as `<sample>_{1,2}.fq.gz`; already-gzipped inputs are symlinked
rather than copied, so the directory is nearly free in the common case. It also
derives ampliseq's `run` column by hashing each sample's source directory, which
groups samples that were sequenced together for error-model training. It records
the post-merge sample count in `sample_count.txt` for the results page to show.

[`ampliseq_upload.sh`](scripts/ampliseq_upload.sh) zips `raw-sequences/` into the
results folder (`zip -0` — the reads are already compressed), uploads the folder
to `s3://$AWS_S3_BUCKET/nxf/<uid>/`, and writes the report URL to a Wrike custom
field. Nextflow's `work/` directory is deliberately left behind.

Everything published lives under one `nxf/` prefix (`S3_RUN_PREFIX` in `.env`),
so that runs do not crowd the top of the bucket and a site can be built around
them later.

### The results page

The URL handed to the requester is `index.html`, not the report itself.
[`config/ampliseq/index.html`](config/ampliseq/index.html) is a template that
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
[`nextflow_progress.sh`](scripts/nextflow_progress.sh), backgrounded by
`wrike_job.sh` for the length of the nextflow stage, renders
[`config/progress.html`](config/progress.html) to the *same key* every minute —
so a requester who opens the results link early watches the pipeline work. The
final upload overwrites it.

The link is live before any of that. `wrike_task_handler.sh` writes the URL to
the task's results custom field the moment Slurm accepts the job, includes it in
the comment telling the requester their run is queued, and runs
`nextflow_progress.sh` once to put a "Queued" page at that address — so the link
it just posted leads somewhere rather than to a `NoSuchKey`. Every one of those
steps is best-effort: the job is already queued, and none of them is worth
abandoning a run over. `ampliseq_upload.sh` sets the same field again at the end,
which covers a failure at submission and marks the point where the address stops
being a promise. Both build it through `run_results_url`, so a task can never
point somewhere its results are not.

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

---

## Configuration

Every script that talks to Wrike or AWS begins with
`source /data/prod/nextflow/.env`. Every statement in that file is a plain
assignment or a `source`, so it is safe and cheap to source any number of times,
in any process, and it carries no guard. It sets `NEXTFLOW_DIR` and
`NEXTFLOW_NODE` (the compute node everything is pinned to — read both by the
`sbatch` calls and by `config/slurm.config`), sets the nextflow cache
directories, and then sources three things:

- `secrets/.env` — **credentials only**, never committed:
  - `WRIKE_API_TOKEN` — the bot's, assigned as `${WRIKE_API_TOKEN:-…}` so a token
    already in the caller's environment wins. That fallback is what lets `run`
    act as a real user; see below.
  - `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `AWS_DEFAULT_REGION`
  - `AWS_SQS_QUEUE_URL`, `AWS_S3_BUCKET`
  - `RUN_ID_SALT` — the HMAC key `derive_uid` derives uids with. Secret because the
    uid is the whole address of a client's results: without it, anyone holding a
    Wrike task ID could compute where that task published. **Changing it strands
    every published result and every in-flight run**, since teardown recomputes
    the uid rather than looking it up.
  - `WRIKE_WEBHOOK_SECRET`, `AWS_WEBHOOK_BRIDGE` (used when registering webhooks)
- [`scripts/utilities.sh`](scripts/utilities.sh) — `log`, `warn`, and `fail`, the
  three ways anything in this system says anything. All stamp the time; `log` and
  `warn` go to stdout, `fail` goes to stderr, copies itself to `message.out` when
  that file exists, and exits non-zero, so a caller stops on the spot rather than
  having to check. Also `derive_uid`, which turns a Wrike task ID into the
  8-character base32 uid that names the run everywhere outside Wrike — 40 bits,
  HMAC-SHA256, so it is stable, unguessable, and safe in a path and a URL, none
  of which a raw Wrike ID is — plus `is_valid_uid`, which every script that
  builds a path or an S3 prefix out of one checks first, `escape_html`, for the
  task name that heads both published pages, and `run_results_url`, the one
  place the address written onto a Wrike task is spelled.
- [`scripts/wrike_api.sh`](scripts/wrike_api.sh) — `call_wrike_api` plus the
  `update_wrike_*` / `add_wrike_task_comment` helpers, which read `TASK_ID` from
  the environment rather than taking it as an argument. **It also defines every
  Wrike object ID the system works against:**
  - `WRIKE_DASHBOARDS_FOLDER_ID` — the folder the webhook watches
  - `WRIKE_PIPELINE_NAME_CFID`, `WRIKE_S3_RESULTS_URL_CFID` — custom fields the
    bot writes the pipeline name and results URL into, which is part of what the
    Wrike Dashboards view renders
  - `WRIKE_CUSTOM_STATUS_IDS` — the status map described below
  - `WRIKE_NXFPIPE_SPACE_ID`, `WRIKE_NXFPIPE_WORKFLOW_ID`,
    `WRIKE_NXFPIPE_REQUEST_FORM_ID` — not read by the running system; they are
    what you need to re-inspect the workflow and form, as
    [config/wrike_responses.md](config/wrike_responses.md) does

**`.env` deliberately does not touch `PATH`.** Everything in this project is
invoked by its absolute path — `"$NEXTFLOW_DIR/scripts/wrike_job.sh"`, and
likewise for the handlers the daemon dispatches and the `PRE_PROCESS_CMD` /
`POST_PROCESS_CMD` a pipeline names. That costs a little verbosity and buys two
things: a bare word in these scripts is recognizably a shell function rather
than an executable, and nothing depends on an inherited `PATH` being right —
including `sbatch`, whose willingness to search `PATH` for a batch script varies
by version.

  These are opaque references, useless to anyone without a token, so they belong
  in git beside the code that uses them. Keeping them in `secrets/.env` would
  mean a fresh clone had no way to reconstruct them.

`WRIKE_PIPELINE_NAME_CFID` is read as well as written: it is the field the
request form fills in with the user's chosen pipeline, and what
`wrike_task_handler.sh` reads to find out what to run. The bot then writes back
over it — first with the resolved name, then with the exact version that ran.

### Progress is the task's Status

How far a run has got is reported as the task's own **Status**, not as a custom
field, so the board groups jobs by what they are actually doing:

```
Submitted → Validating → Queued → Initializing → Pre-Processing → Running → Post-Processing → Completed / Failed
```

`Submitted` is where a request starts: the form leaves its task there, and
[`run`](run) sets it explicitly when creating the task. `Validating` covers the
handler's pre-Slurm sanity checks. Everything from `Queued` on is set from inside
a run directory.

Two helpers do this, and the difference matters. `update_wrike_task_status` sets
the status alone; `update_wrike_pipeline_progress` also writes `status.txt`,
which `wrike_followup.sh` reads to find out how far the run got. The first two
stages happen before any run directory exists, so they use the former — a
`status.txt` written from wherever the user happened to invoke `run` would be
litter at best.

Wrike sets a status by ID, not by name, and those IDs are fixed properties of the
"Nextflow Pipeline Workflow". Resolving them at runtime meant a `GET /workflows`
in every process that reported progress, so **the name → ID mapping is hardcoded
in `WRIKE_CUSTOM_STATUS_IDS`** at the top of
[`scripts/wrike_api.sh`](scripts/wrike_api.sh). The account is rate limited to
400 calls a minute; reporting progress now costs nothing but the `PUT` itself.

**That map is a copy of state that lives in Wrike, so editing the workflow
desyncs it.** Regenerate it from the live workflow — the full response is kept in
[config/wrike_responses.md](config/wrike_responses.md):

```bash
call_wrike_api GET "/spaces/$WRIKE_NXFPIPE_SPACE_ID/workflows"
```

A stage name that isn't a key of the map is logged and skipped, deliberately:
losing a progress update is not worth killing a twelve-hour pipeline over, and
`status.txt` records the stage either way. So a rename in Wrike shows up only in
the daemon log:

```
WARNING: No Wrike custom status is mapped to "Pre-Processing"; progress not reported.
```

The workflow also defines `Archived` and `Cancelled`. Both are mapped and
available, but nothing sets them yet.

### The Wrike side

A bot account exists under `dpsmith@bcm.edu` ("Cluster Bot", `KUAYXHNY`),
distinct from Daniel's normal `Daniel.Smith@bcm.edu` account.

**The bot is a Collaborator, on purpose.** Everything the daemon, handlers, and
jobs do — commenting, attaching files, writing custom fields, setting task
status — a Collaborator can do, so the bot costs no license seat. Creating a task
is the one exception: it returns `403 not_allowed` for Collaborators, and that is
a license restriction, not a permission grantable on the folder.

Only [`run`](run) creates a task, which is why it is the one component that does
*not* run as the bot — see "Running a pipeline by hand" below.

To check which account a token belongs to:

```bash
curl -sS -H "Authorization: bearer $WRIKE_API_TOKEN" "https://www.wrike.com/api/v4/contacts?me=true" | jq '.data[0].profiles'
```

A "Nextflow Pipelines" space holds the
"Dashboards" folder that tracks every submitted job, and the "Bioinformatics
Pipeline" request form that creates tasks in it — see
[config/webhooks.md](config/webhooks.md) for the form's definition. Everything
the bot sees, it sees because the request form put it in that folder.

---

## Operating it

The daemon is the only long-lived process. Start it under a supervisor — it
never returns, and handles `INT`/`TERM` cleanly (shutdown can lag by up to the
20s SQS long-poll):

```bash
/data/prod/nextflow/scripts/wrike_sqs_listener.sh
```

Slurm output goes to `$NEXTFLOW_DIR/log/job_<uid>_<jobid>.out` and
`followup_<uid>_<jobid>.out` — one file per run, since `--job-name` is the
uid, and one file per job rather than two, since `--output` and `--error`
name the same path and both streams interleave there. Per-run state lives in `$NEXTFLOW_DIR/tmp/<uid>/`: a directory still
present after a run ended means that run failed, and `status.txt`, `message.out`,
and `nextflow.log` there say why — with `wrike_task_id.txt` naming the Wrike task
it came from, since the uid does not lead back to one.

### Running a pipeline by hand

**First, once per person: set your own Wrike token.** `run` is the only part of
this system that does not act as the bot, because the bot is a Collaborator and
Collaborators cannot create tasks. Create a permanent token in Wrike under
Apps & Integrations → API
(<https://www.wrike.com/frontend/apps/index.html#/api>) and put it in your
`~/.bashrc`:

```bash
export WRIKE_API_TOKEN="<your token>"
```

`secrets/.env` assigns the bot's token with `${WRIKE_API_TOKEN:-…}`, so yours
takes precedence for everything `run` does, while the daemon and the cluster jobs
— which never see your environment — keep using the bot's. Tasks you submit this
way are authored by you, which is arguably more honest than having them all
attributed to the bot.

`run` checks this before it creates anything and explains what to do if the token
turns out to be a Collaborator's, so the failure mode is a paragraph of
instructions rather than a bare `403`.

```bash
/data/prod/nextflow/run 16Sv4 /path/to/somesamples.txt
```

[`run`](run) does not run a pipeline. It builds the same task the request form
builds — pipeline in the custom field, samplesheet attached — files it under
"Dashboards", and then stops. The request is picked up by
`wrike_task_handler.sh` like any other. Nothing downstream can tell a
command-line request from a form submission, which is the whole idea: there is
one code path and one set of failure modes, not two.

It prints the task ID and permalink and exits as soon as the request is filed.
Progress, rejections, and the final result all show up on that task, not in your
terminal.

**It stages the task in the bot's Personal space first.** Create it there, attach
the samplesheet, *then* add "Dashboards" as a parent. Nothing watches the bot's
own space, so this buys two things:

- **No attachment race.** The samplesheet is always in place before the webhook
  fires, so the handler never has to wait for it. (A form submission still can
  race — Wrike delivers the task and its attachment as separate events with no
  promised order — which is why the handler retries for a few seconds.)
- **Clean rollback.** A failure before the move leaves a task nothing downstream
  has ever seen, so `run` just deletes it. Once the task is on the dashboard,
  failures belong to the bot and get reported on the task instead.

The staging space is deliberately *left* as a parent. Removing it would fire
`TaskParentsRemoved`, and `wrike_delete_handler.sh` listens for that.

This is also why the Wrike task ID being the primary key for everything (run
directory, job name, S3 prefix, and the target of every `update_wrike_*` call)
stopped being an obstacle for a CLI: `run` gets a real task ID by creating a real
task, so nothing needs a synthetic ID or a way to no-op the Wrike reporting.

**On "submitting the request form":** Wrike's API cannot do that.
[`/request_forms`](https://developers.wrike.com/api/v4/request-forms/) is
read-only and form submission is UI-only, regardless of what the bot account is
permissioned to do in the browser. But a request form is only a template for a
task in a folder, so `run` builds that task directly — `POST /folders/<id>/tasks`,
`POST /tasks/<id>/attachments`, then `PUT /tasks/<id>` with `addParents`. The
result is identical from the webhook down.

`run` validates the pipeline name and the samplesheet locally first, using the
same rules as the handler, so an obvious mistake fails in your terminal instead
of a round trip through Wrike.

### Requirements on the cluster

Two live in `$NEXTFLOW_DIR/bin` and are invoked by absolute path: **`nextflow`**
and **`lbzip2`** (the latter only for `.bz2` inputs). The rest are expected on
`PATH`: `apptainer`, Slurm (`sbatch`/`squeue`/`scancel`/`sinfo`), `jq`, `curl`,
`aws` CLI, `pigz`, `md5sum`, and `zip`.
Bash 5.1+ (the scripts use `${var^^}`, `${var,,}`, and associative arrays).
`jq` and `curl` are needed on the compute nodes as well as the login node,
because the Wrike helpers run there too.

---

## Reading the code

Every script carries a header block naming its caller, what it submits, what it
requires, and which environment variables it expects. Start with
[`wrike_task_handler.sh`](scripts/wrike_task_handler.sh) — it is the whole
system's front door, and its numbered steps are the request lifecycle.
