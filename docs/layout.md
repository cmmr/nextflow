# Repository layout

```
.env                  Non-secret environment; sources secrets/.env, utilities.sh,
                      globus.sh, and wrike_api.sh. Sourced by every script here;
                      does not touch PATH.
secrets/.env          Wrike token and AWS credentials. Credentials only; not in git.
run                   CLI entry point. Files a Wrike request, then gets out of the way.

scripts/
  utilities.sh             log, warn, fail, the page renderer, and the uid helpers.
                           Sourced by .env.
  globus.sh                Where a run's two bulky downloads are written and how
                           they are addressed. Likewise sourced.
  pipeline_params.sh       The parameter map a params file is built from. Likewise.
  wrike_api.sh             Wrike REST helpers and object IDs. Likewise sourced.
  publish_dashboard.sh     Builds the three pages a run is read through, and
                           uploads a results tree. Likewise sourced; used by
                           both upload scripts.
  wrike_sqs_listener.sh    The daemon. Polls SQS, routes events.
  wrike_task_handler.sh    Validates a form request, submits it. Login node.
  wrike_delete_handler.sh  Tears a run down. Login node.
  wrike_job.sh             Runs one pipeline end to end. Slurm batch job.
  wrike_followup.sh        Reports the outcome to Wrike. Slurm batch job.
  wrike_expiration.sh      Retires dashboards past their date. Daily, login node.
  nextflow_progress.sh     Publishes the live progress page. Backgrounded by wrike_job.sh.
  prune_results.sh         Deletes what a run wrote for itself out of the results
                           folder, per templates/<pipeline>/prune.conf.
  index_directories.sh     Writes a listing page into every results folder. Pipeline-agnostic.
  ampliseq_samplesheet.sh  PRE_PROCESS_CMDS for the ampliseq pipeline.
  ampliseq_detect_region.sh   Likewise; measures which 16S region was sequenced.
  ampliseq_composition.sh  Works out what the Overview plots. Run by ampliseq_upload.sh.
  ampliseq_upload.sh       POST_PROCESS_CMDS for the ampliseq pipeline.
  taxprofiler_samplesheet.sh  PRE_PROCESS_CMDS for the taxprofiler pipelines.
  taxprofiler_composition.sh  Works out what the Overview plots. Run by taxprofiler_upload.sh.
  taxprofiler_upload.sh       POST_PROCESS_CMDS for the taxprofiler pipelines.
  build_host_reference.sh     Builds a host-depletion reference. Setup, not part of a run.
  build_16s_reference.sh      Builds the 16S landmarks the region detector aligns to. Likewise.
  fetch_taxprofiler_db.sh     Downloads a taxprofiler database. Likewise.

pipelines/            One file per pipeline; see docs/pipelines/index.md.
config/               Nextflow config, passed to `nextflow run -c`.
  slurm.config        Executor + apptainer settings used by the pipelines.
  local.config        Same, for running off the scheduler.
  taxprofiler/
    database.csv      Database sheet for the taxprofiler pipelines.
    slurm.config      Executor + apptainer settings for the taxprofiler pipelines.
                      Both are documented in docs/pipelines/taxprofiler.md.

templates/            Web pages published to S3 alongside a run's results.
  tailwind.html       The head every page below it shares: the Tailwind runtime,
                      the fonts, and the design system as its theme.
  dashboard.html      Landing page template: the navigation bar and its frame.
                      Pipeline-agnostic, as are the four below.
  overview.html       The view it opens on: the run, its plots and its sidebar.
  files.html          The annotated index of everything the run published.
  progress.html       Live progress page template: the task dial and the
                      per-process bars.
  expired.html        The page left where an expired dashboard was.
  common.css          The palette and base styling the folder listings inline.
  listing.html        Folder listing page template.
  ampliseq/
    outputs.conf      What the file index lists for an ampliseq run.
    prune.conf        What is deleted from an ampliseq results folder first.
    abstract.md       The section ampliseq's own summary report opens with.
  taxprofiler/
    outputs.conf      What the file index lists for a taxprofiler run.
    prune.conf        What is deleted from a taxprofiler results folder first.
  redesign/
    DESIGN.md         The Alkek design system the pages above are styled to:
                      tokens, type scale, and what each component is for.
    code.html         The dashboard as it was designed, before it was split into
                      a bar and the pages it frames. tailwind.html is its head.
    screen.png        The same, as a picture.

systemd/              The units systemd runs: the daemon, and the daily
                      expiration timer.
  wrike-sqs-listener.service  systemd user unit for wrike_sqs_listener.sh.
  wrike-expiration.service    systemd user unit for wrike_expiration.sh, started
  wrike-expiration.timer      by this timer, once a day.

images/               Assets that are not part of any published page.
  bot_100px.png       Cluster Bot's Wrike avatar. The small one is in this README.
  bot_large.png       Full size, kept so the avatar can be reused elsewhere.

docs/                 Source of the documentation site; one page per file.
  index.md            Overview, and how a run happens end to end.
  conventions.md      The uid, the run directory, and the other invariants.
  layout.md           This page.
  configuration.md    .env and everything it sources.
  pipelines/
    index.md          The pipeline file format, naming, and adding one.
    ampliseq.md       The ampliseq pre/post steps, and how the 16S region is detected.
    taxprofiler.md    The taxprofiler pipelines, their databases and host references.
  results/
    index.md          The dashboard, its file index, and the live progress view.
    browsable-folders.md  Listing pages written into every results folder.
    cloudfront.md     Viewer request function that serves those listing pages.
  wrike/
    account.md        The bot account, the space, and the request form.
    status.md         The task Status a run reports its progress as.
    webhook_bridge.md Wrike webhook registration and the AWS Lambda source.
    responses.md      Wrike API responses for the request form and its fields.
  operations/
    index.md          Controlling the daemon, and where the logs and run state are.
    daemon.md         Installing, supervising, and troubleshooting the daemon.
    expiration.md     The daily pass that retires dashboards past their date.
    running-by-hand.md  The `run` CLI, and why it files a task rather than running one.
    cluster-requirements.md  What has to be installed on the cluster.
    globus.md         Installing globus-cli, and sharing a dataset by link only.

mkdocs.yml            Documentation site config; docs_hooks.py rewrites the
docs_hooks.py         links in docs/ that point at files in this repository.
```

Working directories that exist only on the cluster: `assets/`, `bin/`, `cache/`,
`db/` (gitignored), plus `log/` and `tmp/` (created at runtime).
