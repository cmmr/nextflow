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

**Reporting to Wrike and recording the run's own status are separate calls.**
`set_wrike_status` sets the task's status and nothing else;
`set_run_status`, in [`scripts/run_state.sh`](../../scripts/run_state.sh), writes
`.status` in the run's `run_state.json`, which `wrike_followup.sh` reads to find
out how far the run got. A stage inside a run directory calls both, the run's own
record first, so a task reading `Queued` is always backed by a run that says the
same.

To reduce Wrike notifications, Wrike only uses the following statuses:
```
Submitted → Running → Completed / Failed
```

They are separate so either can happen on its own. `Submitted` and `Validating`
happen before any run directory exists, so they only move the task — a status
recorded from wherever the user happened to invoke `run` would be litter at best.
`Completed` goes the other way: `wrike_job.sh` records it and stops, and
`wrike_followup.sh` moves the task once it has read it.

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
call_wrike_api GET "/spaces/$WRIKE_SPACE_ID/workflows"
```

A stage name that isn't a key of the map is logged and skipped, deliberately:
losing a progress update is not worth killing a twelve-hour pipeline over, and
`set_run_status` records the stage either way. So a rename in Wrike shows up only in
the daemon log:

```
WARNING: No Wrike custom status is mapped to "Pre-Processing"; progress not reported.
```

The workflow also defines `Expired` and `Cancelled`. `Expired` is what
`wrike_expiration.sh` leaves a task at once it has deleted the run's published
results — see [Expiring a dashboard](../operations/expiration.md) — and it is set
from the login node rather than from a run directory, since by then the run is
long over. `Cancelled` is mapped and available, but nothing sets it.
