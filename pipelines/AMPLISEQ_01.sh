
# 16S amplicons, Illumina or Oxford Nanopore. Neither the platform nor the region
# is requested: ampliseq_detect_region.sh measures both from the reads and
# supplies sequencing_type, primer_fwd, primer_rev, skip_cutadapt, and the Savont
# settings an ONT run needs.
PIPELINE_NAME="ampliseq_01"

# nf-core/ampliseq's development branch, pinned to the commit rather than to the
# branch: ONT support is unreleased, and "dev" would move under a rerun. This is
# 2.19.0dev, which the changelog also calls 3.0.0dev, from 2026-08-20.
AMPLISEQ_REVISION="827a6b77be8e9252ef3ae99aed32b807dd703fc0"

NEXTFLOW_ARGS=(
    -log nextflow.log
    run nf-core/ampliseq
    -r "$AMPLISEQ_REVISION"
    -profile apptainer
    -c "$NEXTFLOW_DIR/config/slurm.config"
    -params-file ampliseq_args.yaml
)

PARAMS_FILE="ampliseq_args.yaml"

params_reset
params_set input                 "ampliseq_samplesheet.tsv"
params_set outdir                "results"
params_set dada_ref_taxonomy     "silva=138.2"
params_set cut_dada_ref_taxonomy true
params_set ref_taxonomy_storage  "$NEXTFLOW_DIR/db/ampliseq"
params_set exclude_taxa          "mitochondria,chloroplast,Francisella"

# Pinned because this revision changed its default from "independent", and
# because Savont rejects the third value, "pseudo"
params_set sample_inference      "pooled"

# The report keeps its own styling; what is replaced is what it says - a title,
# and an opening section naming who produced the analysis and where the rest of
# it is.
params_set report_title          "Amplicon sequencing analysis"
params_set report_abstract       "$NEXTFLOW_DIR/templates/ampliseq/abstract.md"

# The form's optional questions are titled after the parameters they set, and a
# question the requester left at its default is not on the task at all. Every
# answer was checked against the list wrike_api.sh offers before it got here.
for AMPLISEQ_PARAM in dada_ref_taxonomy qiime_ref_taxonomy kraken2_ref_taxonomy exclude_taxa; do
    AMPLISEQ_ANSWER=$(form_answer "$AMPLISEQ_PARAM")

    if [[ -n "$AMPLISEQ_ANSWER" ]]; then
        params_set "$AMPLISEQ_PARAM" "$AMPLISEQ_ANSWER"
    fi
done

# The one that is a switch rather than a value
if [[ "$(form_answer picrust)" == "Yes" ]]; then
    params_set picrust true
fi

# Changing either would leave ampliseq reading a samplesheet nothing wrote, or
# publishing where ampliseq_upload.sh does not look
PARAMS_LOCKED=(input outdir)

PRE_PROCESS_CMDS=(
    "$NEXTFLOW_DIR/scripts/ampliseq_samplesheet.sh"
    "$NEXTFLOW_DIR/scripts/ampliseq_detect_region.sh"
)

POST_PROCESS_CMDS=(
    "$NEXTFLOW_DIR/scripts/ampliseq_upload.sh"
)
