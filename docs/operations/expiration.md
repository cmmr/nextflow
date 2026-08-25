# Expiring a dashboard

Published results are the only thing this system leaves lying around
indefinitely, and the sequencing data in them is the bulk of it. So a request
says how long it wants its dashboard kept, and
[`wrike_expiration.sh`](../../scripts/wrike_expiration.sh) — run once a day by
`systemd/wrike-expiration.timer` — is what holds it to that.

## The date lives on the Wrike task

The request form asks **"Availability"**: 1, 3, 6, 12 or 24 Months, or
Unlimited. `wrike_task_handler.sh` reads that answer while it is validating the
request and writes the date it works out to the task's **"Expiration"** custom
field, in the same pass that puts the results link on the task:

```
Availability = "6 Months"  →  Expiration = today + 6 months
Availability = "Unlimited" →  Expiration left blank
```

A blank field means kept indefinitely, so a request filed with
[`run`](running-by-hand.md) — which cannot ask the question — is never expired.
So is a task Wrike would not let the bot write the field on, which is the failure
mode to prefer: it keeps results rather than losing them.

**The date on the task is what counts, not the answer it came from.** Anyone can
open the task and change "Expiration" — that is the supported way to keep a
dashboard longer, and what the warning comment below asks for.

## What the daily pass does

It reads every task in "Dashboards" that is **`Completed`** and carries an
Expiration date. Tasks that are still running, failed, cancelled, already
expired, or have no date are left alone.

| When | What happens |
| --- | --- |
| 14 days out or nearer | A comment on the task, mentioning its assignees, naming the date and saying how to change it |
| The date has arrived or passed | The published results are deleted, an expired page is left in their place, a comment says so, and the task's Status becomes `Expired` |

The warning goes out **once per date, not once a day**. The comment already on
the task is the whole record kept of having warned: the pass looks for one of its
own comments naming that date, so pushing the date out earns a fresh warning
nearer the new one, and moving it back to a date already warned about does not
warn twice.

A dashboard is also never torn down less than two weeks after its run finished,
whatever the date says. Without that, a run that took longer than the window it
asked for would be expired the day it was published, with the warning arriving
alongside the deletion instead of ahead of it.

## What survives

Everything under `nxf/<uid>/` goes except the run's own records, which are what
lets an expired run still be repeated:

| Kept | |
| --- | --- |
| `pipeline_manifest.json` | What a `prev_run_id` request is rebuilt from |
| `nextflow_command.sh` | The command that ran, fully expanded |
| `*.yaml` | The params file, as finally resolved |
| `rerun_manifest.json`, `form_answers.tsv`, `region.txt`, `region_detection.txt` | The rest of the record, where a run has them |

Only the top level of the prefix is offered a match, so every results folder —
`summary_report/`, `qiime2/`, and the listing pages under them — goes, along with
`raw-sequences.zip`, which is most of the storage the tear-down is for.

`index.html` is deleted with the rest and immediately republished from
[`templates/expired.html`](../../templates/expired.html), so the results link on
the task, and any link a reader kept, still lead to an explanation rather than to
a `NoSuchKey`. That page carries the task title, the reference, the completion
date and the sample count, and says when the results came down.

**It is written for the client, not for us.** Whoever opens that link is most
likely the person whose data it was, arriving at an address that worked last
time — so the page names no files, no pipeline, and nothing from the table above,
and it asks them to contact their CMMR contact rather than telling them to
submit anything. It also does not offer to put the results back: the
configuration survives, but repeating an analysis needs the original sequencing
files, which are not stored here and may not exist anywhere. The records above
are kept for us, and are still at their own keys under the prefix.

The sample count comes from `pipeline_manifest.json`, which has carried it since
August 2026; for a run published before that it is read back out of the landing
page just before that page is deleted.

## Installing the timer

As the account that owns `/data/prod/nextflow`, on the same login node as
[the daemon](daemon.md):

```bash
mkdir -p ~/.config/systemd/user && ln -sf /data/prod/nextflow/systemd/wrike-expiration.{service,timer} ~/.config/systemd/user/
```

```bash
systemctl --user daemon-reload && systemctl --user enable --now wrike-expiration.timer
```

```bash
systemctl --user list-timers wrike-expiration.timer
```

The timer is the unit to enable; the service it starts is `Type=oneshot` and
belongs to no target of its own. Both files are symlinked rather than copied, so
the file in git is the file systemd reads, and a `git pull` that changes either
needs only a `daemon-reload`.

**Lingering applies here too** — see
[Lingering](daemon.md#lingering). Without it there is no user manager to fire the
timer once you log out. `Persistent=true` covers a login node that was down at
06:30: the pass runs when it comes back rather than skipping the day.

**Install it on exactly one login node**, for the same reason as the daemon. Two
passes would race to tear the same prefix down, and the loser would find half of
it gone.

### Or with cron

The script takes no arguments and needs no environment beyond what it sources, so
a user crontab does just as well:

```bash
30 6 * * * /data/prod/nextflow/scripts/wrike_expiration.sh >> /data/prod/nextflow/log/expiration.log 2>&1
```

Redirect it somewhere: with systemd the journal catches `log` and `warn`, and
cron would otherwise mail them.

## Watching it

```bash
journalctl --user -u wrike-expiration --since "7 days ago"
```

Every pass ends with a line counting what it looked at:

```
Checked 34 completed dashboard(s) with an expiration date: 2 near the date, 1 torn down.
```

**Nothing in a pass is fatal to the rest of it.** A task that cannot be read,
torn down, or commented on is logged and left for tomorrow, and the other tasks
are still handled. That is also what makes a tear-down safe to interrupt: a run
whose results were only half deleted is not marked `Expired`, so the next pass
finishes the job.

To see what a pass would do without touching anything:

```bash
/data/prod/nextflow/scripts/wrike_expiration.sh --dry-run
```

A dry run reads Wrike and S3 and reports the tasks it would warn and the objects
it would delete, but posts no comment, deletes nothing, and changes no status.
Worth running once after any change to `KEEP_PATTERNS`.
