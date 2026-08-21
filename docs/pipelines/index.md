# Pipelines

A pipeline file is **not** a script — it is a set of variable assignments that
`wrike_job.sh` sources:

| Variable | Required | Purpose |
| --- | --- | --- |
| `NEXTFLOW_ARGS` | yes | Bash array; the full nextflow command line, already split |
| `PIPELINE_NAME` | no | Exact version recorded on the Wrike task, e.g. `16Sv4_01` |
| `PRE_PROCESS_CMD` | no | Runs before nextflow, in the run directory |
| `POST_PROCESS_CMD` | no | Runs after nextflow succeeds |

Sourcing (rather than executing) is what lets a pipeline file also write its own
params file as a side effect — see the `cat << EOF > ampliseq_args.yaml` block in
any of the `_01` files.

**Each versioned pipeline pins its own nextflow arguments as well as its params.**
Nothing about the command line is defaulted by `wrike_job.sh`. That is the point:
re-running `16SV4_01` a year from now reproduces this run exactly.

## Naming

Two names resolve to the same run, by chained `source`:

```
16SV4.sh  →  16SV4_01.sh      (the actual definition)
```

`16SV4_01.sh` is immutable once it has been used in production. To change
parameters, add `16SV4_02.sh` and repoint `16SV4.sh` at it; old tasks keep
reproducing their original run. The request form's pipeline field is matched
case-insensitively (`16sv4` works) and the resolved name is uppercased, so a user
who needs a specific version can type `16Sv4_01` instead of taking the dropdown's
default.

Currently defined: **16SV1V3** (27f/534r), **16SV3V5** (357f/926r),
**16SV4** (515f/806r), **16SV5V6** (806f/1053r) — all nf-core/ampliseq 2.18.0
against SILVA 138.2 — and **TAXPROFILER** (PhiX only), **TAXPROFILER_HUMAN**
and **TAXPROFILER_MOUSE**, all nf-core/taxprofiler 2.0.1 running kraken2,
bracken and metaphlan over shotgun reads and differing only in which host genome
is depleted; see [the taxprofiler pipelines](taxprofiler.md).

**Pipeline files are named in upper case.** `wrike_task_handler.sh` uppercases
whatever the user typed and looks for exactly that filename, so `taxprofiler` on
the form resolves to `pipelines/TAXPROFILER.sh` and a lower-case file would never
be found.

## Adding a pipeline

1. Write `pipelines/<NAME>_01.sh` setting the variables above.
2. Add `pipelines/<NAME>.sh` containing
   `source "$NEXTFLOW_DIR/pipelines/<NAME>_01.sh"`.
3. Add `<NAME>` as an option to Wrike's "Pipeline Name" custom field.
4. Add `docs/pipelines/<name>.md` describing it, and list the page under
   `Pipelines` in [`mkdocs.yml`](../../mkdocs.yml).
