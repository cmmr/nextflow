# The Wrike side

A bot account exists under `dpsmith@bcm.edu` ("Cluster Bot", `KUAYXHNY`),
distinct from Daniel's normal `Daniel.Smith@bcm.edu` account.

**The bot is a regular user**, so it holds a license seat and everything in this
system runs as it: commenting, attaching files, writing custom fields, setting
task status, and creating tasks — which is what lets [`run`](../../run) file a request
on a caller's behalf rather than making every user bring a token of their own.

It was a Collaborator until August 2026. That costs no seat, but Collaborators
may not create tasks (`403 not_allowed`, a license restriction rather than a
permission grantable on the folder) *or edit custom fields* — and a rejected
custom field write comes back `200` with the change quietly dropped, which is why
`update_wrike_custom_field` reads the reply back and warns when Wrike did not
apply what it was asked for.

To check which account a token belongs to:

```bash
curl -sS -H "Authorization: bearer $WRIKE_API_TOKEN" "https://www.wrike.com/api/v4/contacts?me=true" | jq '.data[0].profiles'
```

A "Nextflow Pipelines" space holds the
"Dashboards" folder that tracks every submitted job, and the "Bioinformatics
Pipeline" request form that creates tasks in it — see
[the Wrike API responses](responses.md) for the form's definition. Everything
the bot sees, it sees because the request form put it in that folder.

## The request form's questions

Every question is listed in `WRIKE_FORM_ANSWERS` in
[`wrike_api.sh`](../../scripts/wrike_api.sh), as
`key | title in Wrike | custom field ID | allowed answers`:

| Key | Custom field | Answers |
| --- | --- | --- |
| `pipeline` | Nextflow Pipeline | `ampliseq`, `taxprofiler`, `prev_run_id` |
| `retention` | Dashboard Retention | 1, 3, 6, 12, 24 Months, or Unlimited |
| `previous_run` | Nextflow Previous Run ID | a run's uid — checked by shape, not by list |
| `dada_ref_taxonomy` | Ampliseq --dada_ref_taxonomy | 11 values, SILVA as `silva=138.2` |
| `qiime_ref_taxonomy` | Ampliseq --qiime_ref_taxonomy | silva=138, greengenes2=2024.09 |
| `kraken2_ref_taxonomy` | Ampliseq --kraken2_ref_taxonomy | silva=138, rdp=18, greengenes=13.5, standard=20240904 |
| `picrust` | Ampliseq --picrust | No, Yes |
| `exclude_taxa` | Ampliseq --exclude_taxa | mitochondria, chloroplast, Francisella |
| `hostremoval_reference` | Taxprofiler --hostremoval_reference | None, PhiX, Human + PhiX, Mouse + PhiX |

**Every key but the first three names the nextflow parameter its field is titled
after**, so a pipeline applies one by asking for its own parameter name — see
[the form's answers](../pipelines/index.md#the-forms-answers).

**An optional question the requester leaves at its default is not on the task at
all.** That is what the form's `Settings: Default` does, and it is why an absent
answer means "the pipeline's own default" rather than an error. There is no
`Settings` field for the system to read, and none is needed.

### Answers are checked twice

Every answer ends up in a nextflow parameters file, so `wrike_task_handler.sh`
rejects the request unless it passes both of:

1. **Shape.** Only the characters that appear in the answers above, plus the `:`
   and `/` of a results link — `[A-Za-z0-9 ,.:+=/_-]`, no `..`, at most 256
   characters. This one applies to *every* answer, including
   `previous_run`, which has no list of its own.
2. **The list.** Exact membership, naming the answers that would have worked. A
   multiple-choice answer arrives comma-separated and every part has to be
   allowed.

**The first check is the one that does not trust Wrike.** The lists are
exact-match, so while Wrike sends only what its dropdowns offer the character
check adds nothing — but that is an assumption rather than a guarantee. A
dropdown can be switched to free text in one click, `Nextflow Pipeline` already
accepts values outside its list (`allowOtherValues`), and a custom field can be
written by anything holding a token. Neither check is load-bearing alone.

A malformed answer is refused without being quoted back on the task, so nothing
unchecked is reflected into a Wrike comment; `.request` in the run's
`run_state.json` has it if you need to see it.

There is no free-text parameter field: what a requester can ask for is exactly
what is listed above.

Checked answers are recorded verbatim under `.answers` in the run's state file
and left there. Nothing in the handler interprets one — pipelines read them with
`form_answer`, so which answers mean anything stays a
[pipeline's business](../pipelines/index.md#the-forms-answers).

**Fields are addressed by ID, not by title.** The account carries over a hundred
custom fields from every CMMR workflow and several share a title, so matching on
one can silently read another team's field. These nine all live in the "Nextflow
Pipelines" space:

```bash
call_wrike_api GET spaces/$WRIKE_SPACE_ID/customfields \
    | jq -r '.data[] | "\(.id)\t\(.title)"'
```

Adding a question is: create the custom field, point the form at it, and add a
row to `WRIKE_FORM_ANSWERS`. A row with an empty ID reads as never answered, and
the handler warns once per request naming it.

`.request` in the run's state file records which field each question resolved
through and what came back, so an answer that did not arrive can be told from one
that was never given.

Two more fields the system writes are not questions, so they have IDs of their
own rather than rows in that table: `WRIKE_DASHBOARD_URL_CFID` ("Dashboard URL")
and `WRIKE_EXPIRATION_CFID` ("Dashboard Expiration").

### The pipeline question

Its options carry a description after the name:

```
ampliseq    :: 16S full length or variable region amplicons
taxprofiler :: WGS metagenomic profiling
prev_run_id :: process new data using the same settings as before
```

**Only the first word is read**, so the descriptions can be reworded freely. The
first two resolve to `pipelines/AMPLISEQ.sh` and `pipelines/TAXPROFILER.sh`; the
third names no pipeline, and means the settings come from the run named in
"Nextflow Previous Run ID".

Adding a fourth option means adding `pipelines/<NAME>.sh` and the option to both
the form and `WRIKE_FORM_ANSWERS` — see
[Adding a pipeline](../pipelines/index.md#adding-a-pipeline).

### Dashboard Retention

The one answer besides "Nextflow Pipeline" that the handler reads rather than
leaving to a pipeline. `wrike_task_handler.sh` turns it into a date — today plus
the number of months it names — and writes that to the task's **"Dashboard
Expiration"** field (`WRIKE_EXPIRATION_CFID`); "Unlimited" leaves that blank,
which means kept indefinitely. It is also recorded in the run's manifest.

`wrike_expiration.sh` reads that date off every task in "Dashboards" once a day:
two weeks out it comments, mentioning the author and the task's followers; on the
date it deletes the published results, leaves an expired page in their place, and
sets the task's Status to `Expired`. **The date on the task is what it acts on**,
so editing "Dashboard Expiration" is how a dashboard is kept longer. See
[Expiring a dashboard](../operations/expiration.md).
