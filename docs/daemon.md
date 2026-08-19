# The Daemon

[`wrike_sqs_listener.sh`](../scripts/wrike_sqs_listener.sh) is the only
long-lived process in this system. It never returns, so something has to start
it, restart it when it dies, and bring it back after the login node reboots.
That something is systemd, running it as a **user** unit —
[`systemd/wrike-sqs-listener.service`](../systemd/wrike-sqs-listener.service).

A user unit rather than a system one because nothing here needs root: the
daemon submits Slurm jobs, reads `secrets/.env`, and writes under
`$NEXTFLOW_DIR`, all as the account that owns them. Running it as root would
make every file it touches root's.

**Install it on exactly one login node.** Two listeners polling the same queue
would race for messages, and each request would land on whichever one won.


## Installing

With the repository deployed to `/data/prod/nextflow`, as the account that owns
it:

```bash
mkdir -p ~/.config/systemd/user && ln -sf /data/prod/nextflow/systemd/wrike-sqs-listener.service ~/.config/systemd/user/
```

```bash
loginctl enable-linger $USER
```

```bash
systemctl --user daemon-reload && systemctl --user enable --now wrike-sqs-listener
```

```bash
systemctl --user status wrike-sqs-listener
```

The unit is symlinked rather than copied, so the file in git is the file systemd
reads and a `git pull` that changes it needs only a `daemon-reload`. `enable`
is what starts it at boot; `--now` also starts it immediately.


## Lingering

Lingering is what keeps the daemon running after logout, and it is the step
that most often has to be arranged with an admin.

A systemd user manager normally exists only while the user has a session on the
machine. Log out of the last one and the manager is torn down, taking the daemon
with it. Lingering makes the manager start at boot and stay up regardless of
sessions, which is both what survives logout and what brings the daemon back
after a reboot.

```bash
loginctl show-user $USER --property=Linger
```

must answer `Linger=yes`. If `enable-linger` failed, that is polkit: a user may
self-enable lingering from an *active* session, and an SSH session does not
always count as one. An admin can set it from outside:

```bash
sudo loginctl enable-linger <user>
```

Without lingering the unit still works, but only for as long as a session is
open — useful for testing, useless in production.


## PATH

[`.env`](../.env) does not touch `PATH`; everything in this repository is
invoked by absolute path. The external binaries are not: `aws`, `jq`, and
`sinfo` are bare words in the daemon, as are `sbatch` and `scancel` in the
handlers it dispatches, which inherit its environment.

A user unit does not read the login shell, so `~/.bashrc`, `~/.bash_profile`,
and any `module load` in them do not apply. The unit carries its own `PATH`
instead:

```ini
Environment=PATH=/cm/shared/apps/slurm/current/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin
```

On `cmmr-login01` that covers all five — `aws` and `jq` are in `/usr/bin`,
and Slurm is a Bright Cluster Manager install under `/cm/shared/apps/slurm/`.
The `current` symlink is used rather than the versioned directory beneath it, so
a Slurm upgrade does not silently take `sinfo` out of the daemon's reach.
Confirm on any node before installing there:

```bash
command -v aws jq sinfo sbatch scancel
```

A missing binary does not fail at startup. The daemon starts, then fails on its
first poll, and the journal records `sinfo: command not found`.


## Logs

`log` and `warn` write to stdout and stderr, which systemd captures, so the
journal is the daemon log. There is no log file to rotate.

```bash
journalctl --user -u wrike-sqs-listener -f
```

```bash
journalctl --user -u wrike-sqs-listener --since today
```

Handler output arrives here too, since handlers are backgrounded children of
the daemon and inherit its streams. A run's own records are elsewhere:
`$NEXTFLOW_DIR/log/` for Slurm job output, `$NEXTFLOW_DIR/tmp/<uid>/` for
per-run state.


## Day to day

Restarting is how edits are picked up. The daemon sources `.env` once at
startup, and the handler paths it dispatches are read per message, so a change
to `.env`, `wrike_api.sh`, or `utilities.sh` needs a restart while a change to a
handler script does not:

```bash
systemctl --user restart wrike-sqs-listener
```

```bash
systemctl --user stop wrike-sqs-listener
```

Stopping is deliberately unhurried. `KillMode=mixed` sends `SIGTERM` to the
listener alone, so a handler already submitting a job is not killed underneath
itself; `TimeoutStopSec=300` gives anything still running five minutes before
systemd kills the rest of the cgroup. The listener's own exit can lag by up to
20 seconds regardless, because its trap does not run until the in-flight SQS
long poll returns.

`Restart=always` with `RestartSec=30` covers the case where the daemon aborts —
`set -euo pipefail` means an unhandled failure exits non-zero. It does not
restart-loop against a down cluster: the daemon checks `sinfo` itself and pauses
polling rather than exiting.


## When it is not working

| Symptom | Cause |
| --- | --- |
| Daemon gone after logout | Lingering not enabled; `loginctl show-user $USER --property=Linger` |
| `Failed to connect to bus` | No user manager for this session — same cause, or you are on a different login node |
| Starts, then `command not found` in the journal | `aws`, `jq`, `sinfo`, `sbatch`, or `scancel` off the unit's `PATH` |
| `status=203/EXEC` | Script not executable, or `/data/prod/nextflow` not mounted on this node |
| Requests picked up twice | A second listener running on another login node |
| Queue drains with nothing happening | The daemon deletes each message before dispatching; look for the routing line in the journal |
