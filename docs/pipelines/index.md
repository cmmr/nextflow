# Pipelines

A pipeline file is **not** a script — it is a set of variable assignments and
`params_set` calls that `wrike_job.sh` sources:

| Variable | Required | Purpose |
| --- | --- | --- |
| `NEXTFLOW_ARGS` | yes | Bash array; the full nextflow command line, already split |
| `PIPELINE_NAME` | yes | Exact version recorded on the Wrike task, e.g. `ampliseq_01` |
| `PARAMS_FILE` | no | Where `wrike_job.sh` writes the params file, e.g. `ampliseq_args.yaml` |
| `PARAMS_LOCKED` | no | Bash array; parameter names a requester may not override |
| `PRE_PROCESS_CMDS` | no | Bash array; commands run in order before nextflow, in the run directory |
| `POST_PROCESS_CMDS` | no | Bash array; commands run in order after nextflow succeeds |

`PIPELINE_NAME` upper-cased must name the file itself — `ampliseq_01` →
`pipelines/AMPLISEQ_01.sh`. That is how the run manifest records the *version*
that ran rather than the shortcut that was asked for, which is what lets a rerun
a year later reproduce it.

## Parameters

The pipeline declares its defaults with `params_set`, one call per parameter:

```bash
PARAMS_FILE="ampliseq_args.yaml"

params_reset
params_set input                 "ampliseq_samplesheet.tsv"
params_set outdir                "results"
params_set exclude_taxa          "mitochondria,chloroplast,Francisella"
```

`wrike_job.sh` writes the file **after** the pre-process stage, from three layers.
Each overwrites only the keys it names, and later layers win:

1. the pipeline's own `params_set` defaults, including whatever it makes of the
   request form's answers
2. `detected_params.yaml` — anything a pre-process step measured from the data,
   such as the primers [`ampliseq_detect_region.sh`](ampliseq.md) found
3. `rerun_params.yaml` — a reproduced run's recorded parameters, which pin
   everything

Then every name in `PARAMS_LOCKED` is put back to the pipeline's own value, with
a warning if something had changed it. Those name files the run itself creates:
overriding `input` would point nextflow at a samplesheet nothing wrote, and
overriding `outdir` would publish where the upload step does not look.

Values are scalars. `true`, `false`, `null` and numbers are written bare so
nextflow types them; everything else is written as a quoted string. There are no
YAML lists — nf-core takes a comma-separated string wherever this system needs
more than one value.

## The form's answers

A pipeline reads the request form with `form_answer <key>`, which returns an
answer `wrike_task_handler.sh` has already
[checked against the list](../wrike/account.md#the-request-forms-questions) the
form offers, or nothing when the question went unanswered. A pipeline turns those
into whatever parameters it uses:

```bash
if [[ "$(form_answer settings)" == "Custom" ]]; then
    AMPLISEQ_ANSWER=$(form_answer dada_ref)
    if [[ -n "$AMPLISEQ_ANSWER" ]]; then
        params_set dada_ref_taxonomy "$AMPLISEQ_ANSWER"
    fi
fi
```

**The mapping lives in the pipeline, not in the handler**, which knows no
pipeline from another. That is also what keeps the answers versioned: this
revision of ampliseq calls its primers `primer_fwd` and `primer_rev` where the
last one called them `FW_primer` and `RV_primer`, and only the pipeline file has
to know which.

`Settings: Default` is what a requester picks to leave the pipeline's own
defaults alone; `Custom` is what makes the database and filter answers apply.

**Each versioned pipeline pins its own nextflow arguments as well as its
defaults.** Nothing about the command line is defaulted by `wrike_job.sh`.

**`-r` names a commit, not a tag or a branch.** A branch moves by design and a
tag can be moved by accident, and either would mean a rerun of a year-old run
executing different code. Both pipelines pin a SHA with a comment saying which
release or branch it came from.

## Naming

Two names resolve to the same run, by chained `source`:

```
AMPLISEQ.sh  →  AMPLISEQ_01.sh      (the actual definition)
```

`AMPLISEQ_01.sh` is immutable once it has been used in production. To change
parameters, add `AMPLISEQ_02.sh` and repoint `AMPLISEQ.sh` at it; old runs keep
reproducing their original settings, and a
[rerun](#reproducing-an-earlier-run) still names the version rather than the
shortcut.

The request form's pipeline field is matched on its **first word only** — its
options read `ampliseq :: 16S full length or variable region amplicons` — and
case-insensitively, so `ampliseq`, `Ampliseq` and `AMPLISEQ` all resolve to
`pipelines/AMPLISEQ.sh`. See [the pipeline field](../wrike/account.md#the-pipeline-field).

Currently defined:

- **AMPLISEQ** — nf-core/ampliseq against SILVA 138.2, pinned to a `dev` commit
  for its unreleased Oxford Nanopore support. One pipeline for every 16S library:
  the platform and the variable region are both measured from the reads rather
  than requested, and a samplesheet with no `fastq_2` column is single-end. See
  [the ampliseq pipeline](ampliseq.md).
- **TAXPROFILER** — nf-core/taxprofiler 2.0.1 running kraken2, bracken and
  metaphlan over shotgun reads. Which host genome is depleted first is the form's
  "Host Depletion" follow-up answer rather than a separate pipeline. See
  [the taxprofiler pipeline](taxprofiler.md).

**Pipeline files are named in upper case.** `wrike_task_handler.sh` uppercases
whatever the user typed and looks for exactly that filename, so `taxprofiler` on
the form resolves to `pipelines/TAXPROFILER.sh` and a lower-case file would never
be found.

## Reproducing an earlier run

Every run writes `pipeline_manifest.json` before nextflow starts and publishes it
with its results, at `nxf/<uid>/pipeline_manifest.json`. It records the pipeline
version, the nextflow command line, and every parameter as resolved — plus the
sample count, which rides along because this file outlives the results it was
published with: it is one of the few things
[an expired dashboard](../operations/expiration.md) keeps.

A request that picks `prev_run_id` on the form and names a run in the "Previous
Run ID" field — or `run --rerun <run_id> samples.txt` — is handled by fetching
that manifest from S3 and using it in place of everything the request would
otherwise decide, the "Host Depletion" answer included. The
requester supplies new samples; nothing else about the analysis changes. For
ampliseq that also means region detection is skipped, since the primers are
already fixed.

A run that never finished published no manifest, and so cannot be reproduced;
the request is rejected saying so.

## Adding a pipeline

1. Write `pipelines/<NAME>_01.sh` setting the variables above, with
   `PIPELINE_NAME="<name>_01"`.
2. Add `pipelines/<NAME>.sh` containing
   `source "$NEXTFLOW_DIR/pipelines/<NAME>_01.sh"`.
3. Add `<NAME>` as an option to Wrike's "Pipeline Name" custom field.
4. Add `docs/pipelines/<name>.md` describing it, and list the page under
   `Pipelines` in [`mkdocs.yml`](../../mkdocs.yml).
