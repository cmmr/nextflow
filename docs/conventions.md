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
- **`nextflow_command.sh` is the record.** `wrike_job.sh` writes the fully
  expanded nextflow command to that file and then executes it, rather than
  running nextflow directly — so the record can never drift from what actually
  ran. It is copied into the published results.
