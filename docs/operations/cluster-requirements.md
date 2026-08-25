# Requirements on the cluster

Two live in `$NEXTFLOW_DIR/bin` and are invoked by absolute path: **`nextflow`**
and **`lbzip2`** (the latter only for `.bz2` inputs). The rest are expected on
`PATH`: `apptainer`, Slurm (`sbatch`/`squeue`/`scancel`/`sinfo`), `jq`, `curl`,
`aws` CLI, `pigz`, `md5sum`, and `zip`.
Bash 5.1+ (the scripts use `${var^^}`, `${var,,}`, and associative arrays).
`jq` and `curl` are needed on the compute nodes as well as the login node,
because the Wrike helpers run there too, and `apptainer` is needed there for
`AMPLISEQ`'s region detection, which runs `vsearch` from a pinned container.

Two references have to be built once before the pipelines that read them will
run: `scripts/build_16s_reference.sh` for
[the ampliseq region detector](../pipelines/ampliseq.md#building-the-landmark-reference),
and `scripts/build_host_reference.sh` plus `scripts/fetch_taxprofiler_db.sh` for
[the taxprofiler pipelines](../pipelines/taxprofiler.md).
