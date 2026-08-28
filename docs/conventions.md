# Conventions

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
- **`request.json` says how the request was read.** Written into the run
  directory before any validation: the SQS event, every question with the custom
  field it resolved through and the value that came back, and the field titles
  Wrike actually has. A rejected request keeps its directory, so this is what an
  unexpected rejection is diagnosed from — and it is the only place the
  difference between *the requester left it blank* and *the field is titled
  something else* is visible. It is not published with the results.
- **The request form's answers reach a pipeline through the run directory.**
  `wrike_task_handler.sh` checks each against the list Wrike offers and writes
  the survivors to `form_answers.tsv`; pipelines read them with `form_answer`.
  The handler never interprets one, which is what keeps it ignorant of pipelines
  and keeps each pipeline version owning its own parameter names.
- **`stage.txt` is what the progress page says the run is doing.** One sentence,
  overwritten by `report_stage` as each stage begins, and read by
  `nextflow_progress.sh` for the line under the run's name. It is written beside
  `nextflow.out` rather than into it: that file is nextflow's own output, and
  the parser that reads it should never have to tell our lines from nextflow's.
- **The run directory is also where a stage reports success.** `notes.txt` is
  created empty beside `message.out`, and stages *append* to it — the region
  `ampliseq_detect_region.sh` measured arrives that way. `wrike_followup.sh`
  posts it whether the run succeeded or failed, where `message.out` explains
  only failures.
- **`nextflow_command.sh` is the record.** `wrike_job.sh` writes the fully
  expanded nextflow command to that file and then executes it, rather than
  running nextflow directly — so the record can never drift from what actually
  ran. It is copied into the published results.
- **`pipeline_manifest.json` is what a rerun is rebuilt from.** Written beside
  it, published to `nxf/<uid>/pipeline_manifest.json`, and holding the pipeline
  *version* (`AMPLISEQ_01`, never the `AMPLISEQ` shortcut), the nextflow
  arguments, and every parameter as finally resolved. A request naming a previous
  run ID is answered by fetching this file, so a run that never finished — and
  therefore never published — cannot be reproduced. It also outlives the results:
  [expiring a dashboard](operations/expiration.md) deletes everything under the
  prefix except this file and the rest of the run's record, which is what lets an
  expired run still be repeated.
