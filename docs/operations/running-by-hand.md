# Running a pipeline by hand

Nothing to set up: `run` acts as the bot, like everything else here, and the bot
may create tasks.

```bash
/data/prod/nextflow/run 16Sv4 /path/to/somesamples.txt
```

The task it files is therefore authored by the bot **on the caller's behalf**,
and `$(whoami)` goes into the task description — the only record of who asked,
since a command-line request has no browser session behind it.

**Personal Wrike tokens are not used, and cannot be.** `.env` unsets any
`WRIKE_API_TOKEN` in the environment before sourcing the bot's, so exporting one
changes nothing about what `run` does. Every request is the bot's to answer for,
which is what keeps a submission's rights and its history the same for everyone —
rather than depending on the Wrike account whoever ran the command happens to
hold, and on that account still existing when someone comes back to the task.

[`run`](../../run) does not run a pipeline. It builds the same task the request form
builds — pipeline in the custom field, samplesheet attached — files it under
"Dashboards", and then stops. The request is picked up by
`wrike_task_handler.sh` like any other. Nothing downstream can tell a
command-line request from a form submission, which is the whole idea: there is
one code path and one set of failure modes, not two.

It prints the task ID and permalink and exits as soon as the request is filed.
Progress, rejections, and the final result all show up on that task, not in your
terminal.

**It stages the task in the bot's Personal space first.** Create it there, attach
the samplesheet, *then* add "Dashboards" as a parent. Nothing watches the bot's
own space, so this buys two things:

- **No attachment race.** The samplesheet is always in place before the webhook
  fires, so the handler never has to wait for it. (A form submission still can
  race — Wrike delivers the task and its attachment as separate events with no
  promised order — which is why the handler retries for a few seconds.)
- **Clean rollback.** A failure before the move leaves a task nothing downstream
  has ever seen, so `run` just deletes it. Once the task is on the dashboard,
  failures belong to the bot and get reported on the task instead.

The staging space is deliberately *left* as a parent. Removing it would fire
`TaskParentsRemoved`, and `wrike_delete_handler.sh` listens for that.

This is also why the Wrike task ID being the primary key for everything (run
directory, job name, S3 prefix, and the target of every `update_wrike_*` call)
stopped being an obstacle for a CLI: `run` gets a real task ID by creating a real
task, so nothing needs a synthetic ID or a way to no-op the Wrike reporting.

**On "submitting the request form":** Wrike's API cannot do that.
[`/request_forms`](https://developers.wrike.com/api/v4/request-forms/) is
read-only and form submission is UI-only, regardless of what the bot account is
permissioned to do in the browser. But a request form is only a template for a
task in a folder, so `run` builds that task directly — `POST /folders/<id>/tasks`,
`POST /tasks/<id>/attachments`, then `PUT /tasks/<id>` with `addParents`. The
result is identical from the webhook down.

`run` validates the pipeline name and the samplesheet locally first, using the
same rules as the handler, so an obvious mistake fails in your terminal instead
of a round trip through Wrike.
