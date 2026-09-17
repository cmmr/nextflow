
# Shotgun metagenomics with the bioBakery tools: KneadData trims reads and
# depletes the host, MetaPhlAn profiles the taxonomy, and HUMAnN the functions.
# mOTUs and Nonpareil measure each sample's diversity for the Overview, and
# EsViritu detects human, animal and plant viruses.
# Which host is depleted is the request form's hostremoval_reference answer;
# PhiX alone when the form never asked.
PIPELINE_NAME="biobakery_01"

NEXTFLOW_ARGS=(
    -log nextflow.log
    run "$NEXTFLOW_DIR/workflows/biobakery"
    -profile apptainer
    -c "$NEXTFLOW_DIR/config/biobakery/slurm.config"
    -params-file biobakery_args.yaml
)

PARAMS_FILE="biobakery_args.yaml"

params_reset
params_set input  "biobakery_samplesheet.csv"
params_set outdir "results"

# HUMAnN is optional; add-on modules are switched on here the same way
params_set run_humann    true
params_set run_motus     true
params_set run_nonpareil true
params_set run_esviritu  true

# "None", "PhiX", "Human + PhiX" or "Mouse + PhiX": the first word names the
# host, and the references are the ones build_host_reference.sh built
BIOBAKERY_HOST=$(form_answer hostremoval_reference)
BIOBAKERY_HOST=${BIOBAKERY_HOST:-PhiX}
BIOBAKERY_HOST=${BIOBAKERY_HOST,,}
BIOBAKERY_HOST=${BIOBAKERY_HOST%% *}

case "$BIOBAKERY_HOST" in
    none)  BIOBAKERY_HOST_REFERENCE="" ;;
    phix)  BIOBAKERY_HOST_REFERENCE="phix" ;;
    human) BIOBAKERY_HOST_REFERENCE="chm13v2phix" ;;
    mouse) BIOBAKERY_HOST_REFERENCE="grcm39phix" ;;
    *)     fail "\"$BIOBAKERY_HOST\" is not a host this pipeline can deplete against." ;;
esac

# The bowtie2 index directory; empty trims without depleting anything
if [[ -n "$BIOBAKERY_HOST_REFERENCE" ]]; then
    params_set kneaddata_db "$NEXTFLOW_DB_DIR/hostremoval/$BIOBAKERY_HOST_REFERENCE"
else
    params_set kneaddata_db ""
fi

params_set kneaddata_sequencer_source "NexteraPE"

# The newest MetaPhlAn database HUMAnN 3.9 accepts profiles from
params_set metaphlan_db "$NEXTFLOW_DB_DIR/metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403"

params_set humann_chocophlan      "$NEXTFLOW_DB_DIR/humann/v201901b/chocophlan"
params_set humann_uniref          "$NEXTFLOW_DB_DIR/humann/v201901b/uniref90"
params_set humann_utility_mapping "$NEXTFLOW_DB_DIR/humann/v201901b/utility_mapping"

# The database mOTUs 3.1.0 accepts, shared with taxprofiler
params_set motus_db "$NEXTFLOW_DB_DIR/motus/db_mOTU_v3.1.0/db_mOTU"

params_set nonpareil_mode "kmer"

params_set esviritu_db "$NEXTFLOW_DB_DIR/esviritu/v3.2.4"

# Changing either would leave the workflow reading a samplesheet nothing wrote,
# or publishing where biobakery_upload.sh does not look
PARAMS_LOCKED=(input outdir)

PRE_PROCESS_CMDS=(
    "$NEXTFLOW_DIR/scripts/biobakery_samplesheet.sh"
)

POST_PROCESS_CMDS=(
    "$NEXTFLOW_DIR/scripts/biobakery_upload.sh"
)
