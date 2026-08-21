# The ampliseq pipelines

[`ampliseq_samplesheet.sh`](../../scripts/ampliseq_samplesheet.sh) turns the lab's
whitespace-delimited `sample fastq_1 fastq_2` sheet into what ampliseq requires:
it recompresses `.bz2` and plain FASTQ to `.gz`, merges entries sharing a sample
name, and sanitizes names to `[A-Za-z][A-Za-z0-9_]*`. Everything lands in
`raw-sequences/` as `<sample>_{1,2}.fq.gz`; already-gzipped inputs are symlinked
rather than copied, so the directory is nearly free in the common case. It also
derives ampliseq's `run` column by hashing each sample's source directory, which
groups samples that were sequenced together for error-model training. It records
the post-merge sample count in `sample_count.txt` for the results page to show.

[`ampliseq_upload.sh`](../../scripts/ampliseq_upload.sh) zips `raw-sequences/` into the
results folder (`zip -0` — the reads are already compressed), gives every folder
in it a listing page, uploads the folder to `s3://$AWS_S3_BUCKET/nxf/<uid>/`, and
writes the report URL to a Wrike custom field. Nextflow's `work/` directory is
deliberately left behind.

Everything published lives under one `nxf/` prefix (`S3_RUN_PREFIX` in `.env`),
so that runs do not crowd the top of the bucket and a site can be built around
them later.

What the requester actually opens — the landing page, and the live progress view
it starts out as — is [The results page](../results/index.md).
