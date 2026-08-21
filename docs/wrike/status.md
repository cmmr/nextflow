# Progress is the task's Status

How far a run has got is reported as the task's own **Status**, not as a custom
field, so the board groups jobs by what they are actually doing:

```
Submitted → Validating → Queued → Initializing → Pre-Processing → Running → Post-Processing → Completed / Failed
```

`Submitted` is where a request starts: the form leaves its task there, and
[`run`](../../run) sets it explicitly when creating the task. `Validating` covers the
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
[`scripts/wrike_api.sh`](../../scripts/wrike_api.sh). The account is rate limited to
400 calls a minute; reporting progress now costs nothing but the `PUT` itself.

**That map is a copy of state that lives in Wrike, so editing the workflow
desyncs it.** Regenerate it from the live workflow — the full response is kept in
[the Wrike API responses](responses.md):

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
