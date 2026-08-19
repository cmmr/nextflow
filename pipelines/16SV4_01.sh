
# 515f and 806r primers
PIPELINE_NAME="16Sv4_01"

NEXTFLOW_ARGS=(
    -log nextflow.log
    run nf-core/ampliseq
    -r 2.18.0
    -profile apptainer
    -resume
    -c "$NEXTFLOW_DIR/config/slurm.config"
    -params-file ampliseq_args.yaml
)

cat << EOF > ampliseq_args.yaml
input: "ampliseq_samplesheet.tsv"
outdir: "results"
skip_cutadapt: true
dada_ref_taxonomy: "silva=138.2"
FW_primer: "GTGCCAGCMGCCGCGGTAA"
RV_primer: "GGACTACHVGGGTWTCTAAT"
cut_dada_ref_taxonomy: true
ref_taxonomy_storage: "$NEXTFLOW_DIR/db/ampliseq"
EOF

PRE_PROCESS_CMD="$NEXTFLOW_DIR/scripts/ampliseq_samplesheet.sh"
POST_PROCESS_CMD="$NEXTFLOW_DIR/scripts/ampliseq_upload.sh"
