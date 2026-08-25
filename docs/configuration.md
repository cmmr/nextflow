# Configuration

Every script that talks to Wrike or AWS begins with
`source /data/prod/nextflow/.env`. Every statement in that file is a plain
assignment or a `source`, so it is safe and cheap to source any number of times,
in any process, and it carries no guard. It sets `NEXTFLOW_DIR`, sets the
nextflow cache directories, unsets any `WRIKE_API_TOKEN` inherited from the
caller, and then sources three things:

- `secrets/.env` — **credentials only**, never committed:
  - `WRIKE_API_TOKEN` — the bot's, and the only one anything here uses. `.env`
    **unsets any inherited `WRIKE_API_TOKEN` before sourcing this file**, so a
    token exported by whoever invoked `run` cannot stand in for the bot's; see
    [Running a pipeline by hand](operations/running-by-hand.md).
  - `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `AWS_DEFAULT_REGION`
  - `AWS_SQS_QUEUE_URL`, `AWS_S3_BUCKET`
  - `RUN_ID_SALT` — the HMAC key `derive_uid` derives uids with. Secret because the
    uid is the whole address of a client's results: without it, anyone holding a
    Wrike task ID could compute where that task published. **Changing it strands
    every published result and every in-flight run**, since teardown recomputes
    the uid rather than looking it up.
  - `WRIKE_WEBHOOK_SECRET`, `AWS_WEBHOOK_BRIDGE` (used when registering webhooks)
- [`scripts/utilities.sh`](../scripts/utilities.sh) — `log`, `warn`, and `fail`, the
  three ways anything in this system says anything. All stamp the time.
  `log` goes to stdout while `warn` and `fail` go to stderr — which keeps stdout
  free to carry a function's return value, since several helpers hand their
  result back through `$(…)`. `fail` also copies itself to `message.out` when
  that file exists, and exits non-zero, so a caller stops on the spot rather than
  having to check. Also `derive_uid`, which turns a Wrike task ID into the
  8-character base32 uid that names the run everywhere outside Wrike — 40 bits,
  HMAC-SHA256, so it is stable, unguessable, and safe in a path and a URL, none
  of which a raw Wrike ID is — plus `is_valid_uid`, which every script that
  builds a path or an S3 prefix out of one checks first, `escape_html`, for the
  task name that heads both published pages, and `run_results_url`, the one
  place the address written onto a Wrike task is spelled.
- [`scripts/wrike_api.sh`](../scripts/wrike_api.sh) — `call_wrike_api` plus the
  `update_wrike_*` / `add_wrike_task_comment` helpers, which read `TASK_ID` from
  the environment rather than taking it as an argument. **It also defines every
  Wrike object ID the system works against:**
  - `WRIKE_DASHBOARDS_FOLDER_ID` — the folder the webhook watches
  - `WRIKE_PIPELINE_NAME_CFID`, `WRIKE_S3_RESULTS_URL_CFID` — custom fields the
    bot writes the pipeline name and results URL into, which is part of what the
    Wrike Dashboards view renders
  - `WRIKE_CUSTOM_STATUS_IDS` — the status map described in
    [Progress is the task's Status](wrike/status.md)
  - `WRIKE_NXFPIPE_SPACE_ID`, `WRIKE_NXFPIPE_WORKFLOW_ID`,
    `WRIKE_NXFPIPE_REQUEST_FORM_ID` — not read by the running system; they are
    what you need to re-inspect the workflow and form, as
    [the Wrike API responses](wrike/responses.md) does

**`.env` deliberately does not touch `PATH`.** Everything in this project is
invoked by its absolute path — `"$NEXTFLOW_DIR/scripts/wrike_job.sh"`, and
likewise for the handlers the daemon dispatches and the `PRE_PROCESS_CMDS` /
`POST_PROCESS_CMDS` a pipeline names. That costs a little verbosity and buys two
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
