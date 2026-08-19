
# Shotgun metagenomics: fastp trimming, then kraken2, bracken and metaphlan
PIPELINE_NAME="taxprofiler_01"

NEXTFLOW_ARGS=(
    -log nextflow.log
    run nf-core/taxprofiler
    -r 2.0.1
    -profile apptainer
    -resume
    -c "$NEXTFLOW_DIR/config/taxprofiler/slurm.config"
    -params-file taxprofiler_args.yaml
)

cat << EOF > taxprofiler_args.yaml
input: "taxprofiler_samplesheet.csv"
databases: "$NEXTFLOW_DIR/config/taxprofiler/database.csv"
outdir: "results"
perform_shortread_qc: true
shortread_qc_tool: "fastp"
run_kraken2: true
run_bracken: true
run_metaphlan: true
run_krona: true
run_profile_standardisation: true
standardisation_taxpasta_format: "tsv"
EOF

PRE_PROCESS_CMD="$NEXTFLOW_DIR/scripts/taxprofiler_samplesheet.sh"
POST_PROCESS_CMD="$NEXTFLOW_DIR/scripts/taxprofiler_upload.sh"
