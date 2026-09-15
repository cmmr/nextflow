#!/bin/bash
#
# biobakery_samplesheet.sh - Stage the reads and write the biobakery samplesheet.
#
# Author: Daniel Smith
# Date:   September 15th, 2026
#
# Runs taxprofiler_samplesheet.sh, which validates the lab samplesheet, stages
# every read into ./raw-sequences/ and records the sample count and platform,
# and keeps the CSV it writes as ./biobakery_samplesheet.csv. The Bracken
# database sheet it also writes is deleted. A run whose reads are not Illumina
# short reads is refused.
#
# Usage:     biobakery_samplesheet.sh [input_samplesheet]
#            defaults to ./original_samplesheet.tsv, as downloaded by wrike_job.sh
# Called by: wrike_job.sh, as the PRE_PROCESS_CMDS entry of the biobakery pipelines
# Runs:      taxprofiler_samplesheet.sh
# Env:       NEXTFLOW_DIR, the fail helper and the run state helpers, sourced
#            from .env
# Outputs:   ./biobakery_samplesheet.csv, ./raw-sequences/, and the samples
#            section of ./run_state.json

set -euo pipefail

source /data/prod/nextflow/.env

"$NEXTFLOW_DIR/scripts/taxprofiler_samplesheet.sh" "$@"

mv taxprofiler_samplesheet.csv biobakery_samplesheet.csv
rm -f taxprofiler_database.csv

PLATFORM=$(state_get samples.platform)

if [[ "$PLATFORM" != "ILLUMINA" ]]; then
    fail "These reads look like $PLATFORM reads. KneadData, MetaPhlAn and HUMAnN take Illumina short reads only."
fi
