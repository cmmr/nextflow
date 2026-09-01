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
  `wrike_task_handler.sh` records the task ID as `.wrike.task_id` in the run's
  state file, and everything on the compute node reads it back with
  `read_wrike_task_id` rather than recovering it from `$PWD`. Scripts that only
  need the uid take it from `$PWD` — it is the directory's name.
- **`run_state.json` is the run's state, all of it.** One JSON document in the
  run directory, created by `wrike_task_handler.sh` and read and written through
  the `state_*` helpers in `scripts/run_state.sh`, which drive `jq`. Values are
  addressed by a dotted path — `state_get wrike.task_id`, `state_set_number
  samples.count 10` — and every write is serialized on `.run_state.lock` and
  lands by rename, so the progress watcher publishing every ten seconds always
  reads a whole document. What is *not* in it is bulk: samplesheets, params
  files, nextflow's logs, the region detection report, and the composition plot
  data stay files of their own.
- **The state file is published.** `nextflow_progress.sh` uploads it to
  `nxf/<uid>/run_state.json` every time it publishes the page, so a reader
  holding the results link holds the whole account of how the run was set up and
  how it went. Nothing in it is secret, and nothing that must stay secret may go
  in it — `secrets/.env` is where those live. Record too much rather than too
  little: everything the system knows about a run is worth having beside the
  results it produced.
- **The state file is the message bus.** `.status` (last stage reached;
  `Completed` only on success) and `.message` (optional user-facing text) are how
  a compute node tells `wrike_followup.sh` what happened. The `fail` helper
  records `.message` wherever it finds a state file — which is what makes any
  script in the run, down to a pipeline's own pre- and post-process steps, able
  to explain itself to the requester without knowing anything about Wrike.
- **`.request` says how the request was read.** Recorded before any validation:
  the SQS event, every question with the custom field it resolved through and the
  value that came back, and the field titles Wrike actually has. A rejected
  request keeps its directory, so this is what an unexpected rejection is
  diagnosed from — and it is the only place the difference between *the requester
  left it blank* and *the field is titled something else* is visible. It is not
  published with the results.
- **The request form's answers reach a pipeline through `.answers`.**
  `wrike_task_handler.sh` checks each against the list Wrike offers and records
  the survivors; pipelines read them with `form_answer`. The handler never
  interprets one, which is what keeps it ignorant of pipelines and keeps each
  pipeline version owning its own parameter names.
- **`.stage` is what the progress page says the run is doing.** One sentence,
  overwritten by `set_run_stage` as each stage begins, and read by
  `nextflow_progress.sh` for the line under the run's name. It is kept beside
  `nextflow.out` rather than in it: that file is nextflow's own output, and the
  parser that reads it should never have to tell our lines from nextflow's.
- **`.notes` is where a stage reports success.** An array stages *append* to —
  the region `ampliseq_detect_region.sh` measured arrives that way.
  `wrike_followup.sh` posts it whether the run succeeded or failed, where
  `.message` explains only failures.
- **Reporting to Wrike and recording state are separate calls.**
  `set_wrike_status` moves the task; `set_run_status` records the same
  name in the state file. A stage that wants both makes both calls, in that
  order — so the task can be moved without touching the run's record, and the
  other way round.
- **`nextflow_command.sh` is the record.** `wrike_job.sh` writes the fully
  expanded nextflow command to that file and then executes it, rather than
  running nextflow directly — so the record can never drift from what actually
  ran. It is copied into the published results.
- **`.manifest` is what a rerun is rebuilt from.** A section of the state file
  holding the pipeline *version* (`AMPLISEQ_01`, never the `AMPLISEQ` shortcut),
  the nextflow arguments, and every parameter as finally resolved. A request
  naming a previous run ID is answered by fetching that run's `run_state.json`
  off S3 and reading `.manifest` out of it, so a run that never got as far as
  recording one cannot be reproduced. Runs published before the state file
  carried it as `pipeline_manifest.json`, which is still tried second. The record
  also outlives the results: [expiring a
  dashboard](operations/expiration.md) deletes everything under the prefix except
  `run_state.json` and the rest of the run's record, which is what lets an
  expired run still be repeated.
