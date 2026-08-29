# Operating it

Two things run on a schedule of their own: the daemon, continuously, and
[the expiration pass](expiration.md), once a day under a systemd timer. Both are
user units on one login node.

The daemon is the only long-lived process. It never returns, and handles
`INT`/`TERM` cleanly, so it runs under systemd as a **user** unit —
[`systemd/wrike-sqs-listener.service`](../../systemd/wrike-sqs-listener.service).
Nothing here needs root, and lingering is what keeps the unit alive once you log
out. Installation, the environment the unit has to carry in place of
`module load slurm`, and what to check when it will not start are in
[the daemon](daemon.md).

```bash
systemctl --user status wrike-sqs-listener
```

`log` and `warn` write to stdout and stderr, so the journal is the daemon log:

```bash
journalctl --user -u wrike-sqs-listener -f
```

Restarting picks up edits to `.env` and to the files it sources, both read once
at startup; a change to a handler script needs nothing, since the daemon
executes it fresh per message:

```bash
systemctl --user restart wrike-sqs-listener
```

The daily pass that retires dashboards past their expiration date logs the same
way, under its own unit:

```bash
systemctl --user list-timers wrike-expiration.timer
```

```bash
journalctl --user -u wrike-expiration --since "7 days ago"
```

Slurm output goes to `$NEXTFLOW_DIR/log/job_<uid>_<jobid>.out` and
`followup_<uid>_<jobid>.out` — one file per run, since `--job-name` is the
uid, and one file per job rather than two, since `--output` and `--error`
name the same path and both streams interleave there. Per-run state lives in
`$NEXTFLOW_DIR/tmp/<uid>/`, which is created as soon as a request is picked up
and removed only when its job succeeds or its Wrike task goes away: a directory
still present after a run ended means the run failed or the request was never
accepted, and `run_state.json` and `nextflow.log` there say why — the state
file's `.status` and `.message` carrying the account of it, and its
`.wrike.task_id` naming the Wrike task it came from, since the uid does not lead
back to one.
