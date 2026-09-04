
# Shotgun metagenomics: fastp trimming, then kraken2, bracken, metaphlan, mOTUs
# and sylph, with nonpareil measuring how much of each community was sequenced.
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

# The shortest read worth keeping, against taxprofiler's own default of 15.
#
# 35 is kraken2's k: a read shorter than that contains no 35-mer, so the
# classifier cannot place it however good it is, and bracken inherits that.
# Keeping them only pads the total every share on the dashboard is taken
# against.
#
# It is also what nonpareil needs. Its k-mer mode counts 24-mers and dies -
# "Reads are required to have a minimum length of kmer size" - the moment one of
# the 10,000 reads it samples is shorter than that, which is a failure that
# lands on some samples and not others depending on what the sample caught. 35
# clears it with room.
params_set shortread_qc_minlength           35

# Homopolymer runs, poly-G tails and microsatellite carry no taxonomic signal
# and land on the repeat-rich human, protozoan and fungal sequence PlusPF
# carries. fastp rather than the bbduk default: taxprofiler appends
# --low_complexity_filter to the fastp call already running, so this is the same
# task rather than a second pass over every read.
params_set perform_shortread_complexityfilter         true
params_set shortread_complexityfilter_tool            "fastp"
params_set shortread_complexityfilter_fastp_threshold 30

params_set perform_longread_qc              true
params_set perform_runmerging               true
params_set run_kraken2                      true
params_set run_bracken                      true
params_set run_metaphlan                    true
params_set run_motus                        true

# GTDB rather than RefSeq, so the run sees the species representatives that
# exist only as metagenome-assembled genomes. Minutes per sample against the
# hours the other profilers take.
params_set run_sylph                        true
params_set sylph_data_type                  "relative_abundance"
params_set sylph_taxonomy                   "$NEXTFLOW_DIR/db/sylph/gtdb_r220_metadata.tsv.gz"

params_set run_krona                        true
params_set run_profile_standardisation      true
params_set standardisation_taxpasta_format  "tsv"
params_set taxpasta_taxonomy_dir            "$NEXTFLOW_DIR/db/kraken2/pluspf_20260626"
params_set taxpasta_add_name                true
params_set taxpasta_add_rank                true

# The lineage columns make the merged tables self-contained: a reader collapses
# to any rank without joining back to a taxonomy dump they do not have.
params_set taxpasta_add_lineage             true
params_set taxpasta_add_ranklineage         true

# How varied each sample was, which no classifier here answers honestly: half a
# WGS sample's reads reach no taxon, so an index computed over the half a
# database names describes the database as much as the sample. Nonpareil reads
# redundancy off the reads themselves and needs no database at all; mOTUs counts
# the species-level clusters it finds in universal marker genes, which reaches
# species no reference genome has been assembled for.
#
# Nonpareil sees the reads fastp left, before host removal and before a sample's
# runs are merged - that is where taxprofiler 2.0.1 wires it - so it measures
# what was sequenced rather than what was classified.
params_set perform_shortread_redundancyestimation true
params_set shortread_redundancyestimation_mode    "kmer"

# "Taxprofiler --hostremoval_reference" answers "None", "PhiX", "Human + PhiX"
# and "Mouse + PhiX", so the first word names the host and the rest is the PhiX
# every depleting answer includes. PhiX when unanswered.
TAXPROFILER_HOST=$(form_answer hostremoval_reference)
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
#
# Human is depleted only when the answer asks for it. A host the requester did
# not name is not depleted against on this pipeline's own initiative.
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
