
# Shotgun metagenomics with the bioBakery tools: bowtie2 depletes the host,
# KneadData trims the reads and removes tandem repeats, MetaPhlAn profiles the
# taxonomy, and HUMAnN the functions.
# mOTUs and Nonpareil measure each sample's diversity for the Overview, and
# Marker-MAGu profiles phages alongside bacteria and archaea. EsViritu, which
# detects human, animal and plant viruses, is off.
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
params_set run_humann     true
params_set run_motus      true
params_set run_nonpareil  true
params_set run_esviritu   false
params_set run_markermagu true

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

# bowtie2 end to end over every read, then in local mode, KneadData's own
# setting, over the pairs left
params_set host_prefilter_bowtie2_options "--fast"
params_set host_bowtie2_options           "--very-sensitive-local"

params_set kneaddata_sequencer_source "NexteraPE"

# The read sets the download carries beside the results: any of "Raw", "Host
# Depleted" and "Cleaned", or none. The workflow publishes the last two;
# biobakery_upload.sh reads "Raw" itself. A run that depletes no host has no
# host-depleted reads.
params_set host_depleted_outdir ""
params_set cleaned_outdir ""

if form_answer_includes delivered_reads "Host Depleted"; then
    if [[ -n "$BIOBAKERY_HOST_REFERENCE" ]]; then
        params_set host_depleted_outdir "host-depleted-sequences"
    else
        state_append notes "No host was removed from these reads, so there are no host-depleted reads in the download."
    fi
fi

if form_answer_includes delivered_reads "Cleaned"; then
    params_set cleaned_outdir "cleaned-sequences"
fi

# The newest MetaPhlAn database HUMAnN 3.9 accepts profiles from
params_set metaphlan_db "$NEXTFLOW_DB_DIR/metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403"

params_set humann_chocophlan      "$NEXTFLOW_DB_DIR/humann/v201901b/chocophlan"
params_set humann_uniref          "$NEXTFLOW_DB_DIR/humann/v201901b/uniref90"
params_set humann_utility_mapping "$NEXTFLOW_DB_DIR/humann/v201901b/utility_mapping"

# The database mOTUs 3.1.0 accepts, shared with taxprofiler
params_set motus_db "$NEXTFLOW_DB_DIR/motus/db_mOTU_v3.1.0/db_mOTU"

params_set nonpareil_mode "kmer"

# Named only when EsViritu runs, so the manifest does not record a database the
# run never read. A rerun brings its own from the parameters it recorded.
if [[ "$(params_get run_esviritu)" == true ]]; then
    params_set esviritu_db "$NEXTFLOW_DB_DIR/esviritu/v3.2.4"
fi

params_set markermagu_db "$NEXTFLOW_DB_DIR/markermagu/v1.1"
params_set markermagu_detection "default"

# Changing the first two would leave the workflow reading a samplesheet nothing
# wrote, or publishing where biobakery_upload.sh does not look. The read sets
# delivered are this request's answer, not those of a run it repeats.
PARAMS_LOCKED=(input outdir host_depleted_outdir cleaned_outdir)

PRE_PROCESS_CMDS=(
    "$NEXTFLOW_DIR/scripts/biobakery_samplesheet.sh"
)

POST_PROCESS_CMDS=(
    "$NEXTFLOW_DIR/scripts/biobakery_upload.sh"
)
