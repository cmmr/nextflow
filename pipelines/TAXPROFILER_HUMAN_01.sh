
# Shotgun metagenomics with human (T2T-CHM13v2.0 + PhiX) depletion
PIPELINE_NAME="taxprofiler_human_01"

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
databases: "taxprofiler_database.csv"
outdir: "results"
perform_shortread_qc: true
shortread_qc_tool: "fastp"
perform_shortread_hostremoval: true
hostremoval_reference: "$NEXTFLOW_DIR/db/hostremoval/chm13v2phix.fa"
shortread_hostremoval_index: "$NEXTFLOW_DIR/db/hostremoval/chm13v2phix"
perform_longread_qc: true
perform_longread_hostremoval: true
longread_hostremoval_index: "$NEXTFLOW_DIR/db/hostremoval/chm13v2phix.mmi"
run_kraken2: true
run_bracken: true
run_metaphlan: true
run_krona: true
run_profile_standardisation: true
standardisation_taxpasta_format: "tsv"
taxpasta_taxonomy_dir: "$NEXTFLOW_DIR/db/kraken2/pluspf_20260626"
taxpasta_add_name: true
taxpasta_add_rank: true
EOF

PRE_PROCESS_CMD="$NEXTFLOW_DIR/scripts/taxprofiler_samplesheet.sh"
POST_PROCESS_CMD="$NEXTFLOW_DIR/scripts/taxprofiler_upload.sh"
