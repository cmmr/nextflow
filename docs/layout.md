# Repository layout

```
.env                  Non-secret environment; sources secrets/.env, utilities.sh,
                      and wrike_api.sh. Sourced by every script here; does not
                      touch PATH.
secrets/.env          Wrike token and AWS credentials. Credentials only; not in git.
run                   CLI entry point. Files a Wrike request, then gets out of the way.

scripts/
  utilities.sh             log, warn, fail, and the uid helpers. Sourced by .env.
  pipeline_params.sh       The parameter map a params file is built from. Likewise.
  wrike_api.sh             Wrike REST helpers and object IDs. Likewise sourced.
  wrike_sqs_listener.sh    The daemon. Polls SQS, routes events.
  wrike_task_handler.sh    Validates a form request, submits it. Login node.
  wrike_delete_handler.sh  Tears a run down. Login node.
  wrike_job.sh             Runs one pipeline end to end. Slurm batch job.
  wrike_followup.sh        Reports the outcome to Wrike. Slurm batch job.
  nextflow_progress.sh     Publishes the live progress page. Backgrounded by wrike_job.sh.
  index_directories.sh     Writes a listing page into every results folder. Pipeline-agnostic.
  ampliseq_samplesheet.sh  PRE_PROCESS_CMDS for the ampliseq pipeline.
  ampliseq_detect_region.sh   Likewise; measures which 16S region was sequenced.
  ampliseq_upload.sh       POST_PROCESS_CMDS for the ampliseq pipeline.
  taxprofiler_samplesheet.sh  PRE_PROCESS_CMDS for the taxprofiler pipelines.
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
  progress.html       Live progress page template. Pipeline-agnostic.
  listing.html        Folder listing page template. Likewise.
  ampliseq/
    index.html        Landing page template for a published ampliseq run.
  taxprofiler/
    index.html        Landing page template for a published taxprofiler run.

systemd/              The daemon's supervisor.
  wrike-sqs-listener.service  systemd user unit for wrike_sqs_listener.sh.

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
    index.md          The published landing page and the live progress view.
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
    running-by-hand.md  The `run` CLI, and why it files a task rather than running one.
    cluster-requirements.md  What has to be installed on the cluster.

mkdocs.yml            Documentation site config; docs_hooks.py rewrites the
docs_hooks.py         links in docs/ that point at files in this repository.
```

Working directories that exist only on the cluster: `assets/`, `bin/`, `cache/`,
`db/` (gitignored), plus `log/` and `tmp/` (created at runtime).
