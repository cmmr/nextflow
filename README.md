# nextflow

<img src="images/bot_100px.png" alt="Cluster Bot avatar" width="100" align="right">

Amplicon (16S) and WGS pipelines for CMMR, driven from Wrike.

A user submits the **"Bioinformatics Pipeline"** Wrike request form, naming a
pipeline and attaching a samplesheet — or runs **`run ampliseq samples.txt`** on the
login node, which files the same request. A few seconds later the bot replies on
the resulting task that the job is queued; when it finishes, the task carries a
link to an S3-hosted report and a zip of the raw reads. Everything in between is
what this repository does.

There is no web service and no database. The whole system is bash scripts on the
cluster login node plus a Slurm queue, glued to Wrike by an SQS queue.

## Documentation

**<https://cmmr.github.io/nextflow/>** — built from [`docs/`](docs) on every push
to `main`.

| | |
| --- | --- |
| [Overview](https://cmmr.github.io/nextflow/) | What happens between a request and a report |
| [Conventions](https://cmmr.github.io/nextflow/conventions/) | The uid, the run directory, and the other invariants |
| [Repository layout](https://cmmr.github.io/nextflow/layout/) | What every file here is for |
| [Configuration](https://cmmr.github.io/nextflow/configuration/) | `.env` and everything it sources |
| [Pipelines](https://cmmr.github.io/nextflow/pipelines/) | The pipeline file format, versioning, and adding one |
| [Results](https://cmmr.github.io/nextflow/results/) | The published landing page, progress view, and folder listings |
| [Wrike](https://cmmr.github.io/nextflow/wrike/account/) | The bot account, task status, webhook bridge, API responses |
| [Operations](https://cmmr.github.io/nextflow/operations/) | The daemon, the logs, running a pipeline by hand |

## Running a pipeline

```bash
/data/prod/nextflow/run ampliseq /path/to/somesamples.txt
```

`run` files a Wrike request and exits; progress, rejections, and the final
result all appear on the task it prints. See
[Running a pipeline by hand](https://cmmr.github.io/nextflow/operations/running-by-hand/).

## Reading the code

Every script carries a header block naming its caller, what it submits, what it
requires, and which environment variables it expects. Start with
[`wrike_task_handler.sh`](scripts/wrike_task_handler.sh) — it is the whole
system's front door, and its numbered steps are the request lifecycle.

## Working on the docs

```bash
pip install -r requirements-docs.txt && mkdocs serve
```
