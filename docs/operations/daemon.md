# The Daemon

[`wrike_sqs_listener.sh`](../../scripts/wrike_sqs_listener.sh) is the only
long-lived process in this system. It never returns, so something has to start
it, restart it when it dies, and bring it back after the login node reboots.
That something is systemd, running it as a **user** unit —
[`systemd/wrike-sqs-listener.service`](../../systemd/wrike-sqs-listener.service) —
on one login node, as the account that owns `/data/prod/nextflow`.

[Installing](#installing) it is a one-time job. Everything below is what running
it involves afterwards.


## Running it

`log` and `warn` write to stdout and stderr, which systemd captures, so the
journal is the daemon log. There is no log file, and nothing to rotate.

```bash
journalctl --user -u wrike-sqs-listener -f
```

```bash
journalctl --user -u wrike-sqs-listener --since today
```

A healthy daemon is silent. It logs at startup and then says nothing until a
webhook arrives, so an empty tail means it is long-polling SQS, not that it has
stopped. What it is doing right now:

```bash
systemctl --user status wrike-sqs-listener
```

Handler output arrives in the journal too, since handlers are backgrounded
children of the daemon and inherit its streams. A run's own records are
elsewhere: `$NEXTFLOW_DIR/log/` for Slurm job output, `$NEXTFLOW_DIR/tmp/<uid>/`
for per-run state.


### Getting a change running

The daemon executes [`wrike_sqs_listener.sh`](../../scripts/wrike_sqs_listener.sh)
once, at startup, and holds it for as long as it runs. **Editing that script
changes nothing until the daemon is restarted** — pull the change onto the
cluster, then restart:

```bash
git -C /data/prod/nextflow pull && systemctl --user restart wrike-sqs-listener
```

Not everything needs that, because not everything is read at startup:

| Changed | What it takes |
| --- | --- |
| `scripts/wrike_sqs_listener.sh` | Restart — executed once, at startup |
| `.env`, `secrets/.env`, `utilities.sh`, `wrike_api.sh` | Restart — sourced once, at startup |
| `systemd/wrike-sqs-listener.service` | `systemctl --user daemon-reload`, then restart |
| The handlers, `wrike_job.sh`, the pipelines | Nothing — executed fresh per message |

`daemon-reload` is for the unit file alone. It makes systemd re-read
`wrike-sqs-listener.service`; it does not touch the running process, which is
why a unit change takes both commands:

```bash
systemctl --user daemon-reload && systemctl --user restart wrike-sqs-listener
```

The journal shows whether a restart took: the `Stopped`/`Started` pair, then a
fresh `Starting Wrike SQS Listener Daemon...` under a new PID.


### Stopping

```bash
systemctl --user stop wrike-sqs-listener
```

Stop rather than kill the process. `Restart=always` means a killed daemon comes
back 30 seconds later, which looks like it ignored you.

Neither stopping nor restarting is instant, by design. `SIGTERM` reaches the
listener immediately, but its trap does not run until the command in flight
returns — up to 20 seconds for an SQS long poll, up to 60 while it sleeps out a
Slurm pause. `KillMode=mixed` then leaves any handler it had backgrounded
running, so a job already being submitted is not killed underneath itself, and
`TimeoutStopSec=300` gives those five minutes before systemd kills the rest of
the cgroup.

`Restart=always` also covers the daemon aborting on its own — `set -euo
pipefail` means an unhandled failure exits non-zero. It will not restart-loop
against a down cluster: the daemon checks `sinfo` itself and pauses polling
rather than exiting.


## Installing

A user unit rather than a system one because nothing here needs root: the daemon
submits Slurm jobs, reads `secrets/.env`, and writes under `$NEXTFLOW_DIR`, all
as the account that owns them. Running it as root would make every file it
touches root's.

**Install it on exactly one login node.** Two listeners polling the same queue
would race for messages, and each request would land on whichever one won.

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
reads, and a `git pull` that changes it needs no reinstalling — only the
`daemon-reload` and restart above. `enable` is what starts it at boot; `--now`
also starts it immediately.


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


## The unit's environment

[`.env`](../../.env) does not touch `PATH`; everything in this repository is
invoked by absolute path. The external binaries are not: `aws`, `jq`, and
`sinfo` are bare words in the daemon, as are `sbatch` and `scancel` in the
handlers it dispatches, which inherit its environment.

A user unit does not read the login shell, so `~/.bashrc`, `~/.bash_profile`,
and the `module load slurm` in them do not apply. **Whatever that module sets
and Slurm needs, the unit has to set itself** — on `cmmr-login01`, that is two
of the things `module show slurm` lists:

```ini
Environment=PATH=/cm/shared/apps/slurm/current/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin
Environment=SLURM_CONF=/cm/shared/apps/slurm/var/etc/slurm/slurm.conf
```

`PATH` finds the Slurm client commands, which are a Bright Cluster Manager
install under `/cm/shared/apps/slurm/`; `aws` and `jq` come from `/usr/bin`. The
`current` symlink is used rather than the versioned directory beneath it, so a
Slurm upgrade does not take `sinfo` out of the daemon's reach.

`SLURM_CONF` is the one that is easy to miss, because nothing on the command
line needs it: with the module loaded it is already in the environment, and
without it every Slurm command falls back to locating its configuration over
DNS, which does not answer here:

```
sinfo: error: resolve_ctls_from_dns_srv: res_nsearch error: Unknown host
sinfo: fatal: Could not establish a configuration source
```

The module's `LD_LIBRARY_PATH` is deliberately not repeated. The binaries under
`/cm/shared/apps/slurm/current/bin` find their libraries without it, which the
error above proves — `sinfo` got far enough to complain about configuration.

To check any of this the way the daemon sees it, run the command with the unit's
environment and nothing else:

```bash
env -i PATH=/cm/shared/apps/slurm/current/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin SLURM_CONF=/cm/shared/apps/slurm/var/etc/slurm/slurm.conf HOME=$HOME sinfo
```

```bash
systemctl --user show wrike-sqs-listener -p Environment
```

The second reads back what the running service actually has, which is not the
file's contents until a `daemon-reload` and a restart have picked them up.


## When it is not working

| Symptom | Cause |
| --- | --- |
| Daemon gone after logout | Lingering not enabled; `loginctl show-user $USER --property=Linger` |
| `Failed to connect to bus` | No user manager for this session — same cause, or you are on a different login node |
| Starts, then `command not found` in the journal | `aws`, `jq`, `sinfo`, `sbatch`, or `scancel` off the unit's `PATH` |
| "Slurm cluster is unreachable" while Slurm is up | `SLURM_CONF` unset, so the Slurm commands look their config up over DNS |
| `status=203/EXEC` | Script not executable, or `/data/prod/nextflow` not mounted on this node |
| Requests picked up twice | A second listener running on another login node |
| Queue drains with nothing happening | The daemon deletes each message before dispatching; look for the routing line in the journal |
