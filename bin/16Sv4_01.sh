#!/bin/bash
#SBATCH --job-name=16Sv4
#SBATCH --nodelist=cmp09
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=48:00:00
#SBATCH --output=16Sv4_%j.log

VER="01"
NXF="/data/prod/nextflow"

# Automatically cleanup temporary files
export TMPDIR="/tmp/${USER}_16Sv4_${SLURM_JOB_ID:-$$}"
export APPTAINERENV_TMPDIR="$TMPDIR"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

# Nextflow Persistent Asset and Container Cache Directories
export NXF_ASSET_DIR="$NXF/assets"
export NXF_APPTAINER_CACHEDIR="$NXF/cache/apptainer"
export NXF_SINGULARITY_CACHEDIR="$NXF/cache/apptainer"

# Dynamically set the config file based on execution context
if [ -n "$SLURM_JOB_ID" ]; then
  CONFIG_FILE="$NXF/config/slurm"
else
  CONFIG_FILE="$NXF/config/local"
fi

# Execute Nextflow
"$NXF/bin/nextflow" run nf-core/ampliseq \
    -r 2.18.0 -profile apptainer -resume \
    -c "$CONFIG_FILE" \
    --input samplesheet.tsv \
    --outdir "ampliseq_16Sv4_$VER" \
    --skip_cutadapt \
    --sample_inference pooled \
    --dada_ref_taxonomy silva=138.2 \
    --ref_taxonomy_storage "$NXF/db/ampliseq" \
    --cut_dada_ref_taxonomy \
    --FW_primer GTGCCAGCMGCCGCGGTAA \
    --RV_primer GGACTACHVGGGTWTCTAAT
