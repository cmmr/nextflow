
# Shotgun metagenomics: fastp trimming, then kraken2, bracken and metaphlan.
# Which host is depleted first is the request form's follow-up answer, recorded
# by wrike_task_handler.sh; PhiX alone when the form never asked.
PIPELINE_NAME="taxprofiler_01"

# The commit the 2.0.1 tag points at, pinned rather than the tag itself so that a
# rerun cannot be answered by a tag that has since been moved
TAXPROFILER_REVISION="70ecc15e49b4f1fcf79d876643b5d14b65c66178"

NEXTFLOW_ARGS=(
    -log nextflow.log
    run nf-core/taxprofiler
    -r "$TAXPROFILER_REVISION"
    -profile apptainer
    -resume
    -c "$NEXTFLOW_DIR/config/taxprofiler/slurm.config"
    -params-file taxprofiler_args.yaml
)

PARAMS_FILE="taxprofiler_args.yaml"

params_reset
params_set input                            "taxprofiler_samplesheet.csv"
params_set databases                        "taxprofiler_database.csv"
params_set outdir                           "results"
params_set perform_shortread_qc             true
params_set shortread_qc_tool                "fastp"
params_set perform_longread_qc              true
params_set perform_runmerging               true
params_set run_kraken2                      true
params_set run_bracken                      true
params_set run_metaphlan                    true
params_set run_krona                        true
params_set run_profile_standardisation      true
params_set standardisation_taxpasta_format  "tsv"
params_set taxpasta_taxonomy_dir            "$NEXTFLOW_DIR/db/kraken2/pluspf_20260626"
params_set taxpasta_add_name                true
params_set taxpasta_add_rank                true

# "Host Depletion" answers "None", "PhiX", "Human + PhiX" and "Mouse + PhiX", so
# the first word names the host and the rest is the PhiX every depleting answer
# includes. PhiX when unanswered.
TAXPROFILER_HOST=$(form_answer host)
TAXPROFILER_HOST=${TAXPROFILER_HOST:-PhiX}
TAXPROFILER_HOST=${TAXPROFILER_HOST,,}
TAXPROFILER_HOST=${TAXPROFILER_HOST%% *}

# The references build_host_reference.sh was run for, named as it named them
case "$TAXPROFILER_HOST" in
    none)  TAXPROFILER_HOST_REFERENCE="" ;;
    phix)  TAXPROFILER_HOST_REFERENCE="phix" ;;
    human) TAXPROFILER_HOST_REFERENCE="chm13v2phix" ;;
    mouse) TAXPROFILER_HOST_REFERENCE="grcm39phix" ;;
    *)     fail "\"$TAXPROFILER_HOST\" is not a host this pipeline can deplete against." ;;
esac

# "None" skips host removal outright. Every other answer also strips PhiX, since
# the Illumina spike-in is never part of the sample and PlusPF carries viral
# genomes that would otherwise classify it.
if [[ -n "$TAXPROFILER_HOST_REFERENCE" ]]; then
    params_set perform_shortread_hostremoval  true
    params_set hostremoval_reference          "$NEXTFLOW_DIR/db/hostremoval/$TAXPROFILER_HOST_REFERENCE.fa"
    params_set shortread_hostremoval_index    "$NEXTFLOW_DIR/db/hostremoval/$TAXPROFILER_HOST_REFERENCE"
    params_set perform_longread_hostremoval   true
    params_set longread_hostremoval_index     "$NEXTFLOW_DIR/db/hostremoval/$TAXPROFILER_HOST_REFERENCE.mmi"
else
    params_set perform_shortread_hostremoval  false
    params_set perform_longread_hostremoval   false
fi

# Changing any of these would leave taxprofiler reading a samplesheet or database
# sheet nothing wrote, or publishing where taxprofiler_upload.sh does not look
PARAMS_LOCKED=(input databases outdir)

PRE_PROCESS_CMDS=(
    "$NEXTFLOW_DIR/scripts/taxprofiler_samplesheet.sh"
)

POST_PROCESS_CMDS=(
    "$NEXTFLOW_DIR/scripts/taxprofiler_upload.sh"
)
