
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
# Applied by scripts/R/ampliseq_tables.R rather than by the pipeline: the
# filter was a QIIME 2 step, and QIIME 2's downstream no longer runs. Still
# declared here so it lands in ampliseq_args.yaml and in the run's manifest,
# which is where that script reads it from.
params_set exclude_taxa          "mitochondria,chloroplast,Francisella"

# QIIME 2's downstream is skipped whole: its abundance tables, its barplot, its
# diversity indices, its alpha rarefaction and its taxon filter. Everything
# those produced is now built from DADA2's own tables by
# scripts/R/ampliseq_tables.R, which assembles one feature table and writes it
# out three ways - so the file a requester downloads and the numbers the
# Overview plots are the same object rather than two renderings of it.
#
# The QIIME 2 classifier is not affected: it sits outside this switch, so a
# requester who asks for --qiime_ref_taxonomy as a second opinion still gets it.
params_set skip_qiime_downstream true

# ampliseq builds these from whichever table it has to hand, which is now the
# unfiltered DADA2 one - a different set of ASVs from the feature table this run
# publishes. One feature table per run, so these are left out; rbiom's
# convert_to_phyloseq() can rebuild the phyloseq object from the published BIOM
# whenever it is wanted.
params_set skip_phyloseq         true
params_set skip_tse              true

# Barrnap classifies each ASV's small-subunit gene, and anything that is neither
# bacterial nor archaeal is dropped. A 16S primer pair also amplifies host and
# organellar DNA, and those products carry no SSU at all; left in, each becomes a
# long branch of its own that unweighted UniFrac and Faith's PD weigh like any
# other. Archaea are kept, so they stay in the abundance tables and the taxonomy
# - the tree below is bacterial, and places them near its root.
params_set filter_ssu            "bac,arc"

# Pinned because this revision changed its default from "independent", and
# because Savont rejects the third value, "pseudo"
params_set sample_inference      "pooled"

# Phylogenetic placement in place of the de novo MAFFT/FastTree phylogeny. EPA-NG
# grafts the ASVs onto the GTDB bacterial 16S tree build_pplace_reference.sh
# fetched, and ampliseq_prune_tree.sh cuts that back to this run's own ASVs.
# scripts/R/ampliseq_tables.R writes it into the HDF5 feature table and computes
# Faith's PD from it.
#
# This is the only tree the run produces: ampliseq builds its de novo one inside
# the QIIME2 diversity subworkflow, which no longer runs.
#
# --pplace_taxonomy is left unset. ampliseq takes it in preference to DADA2,
# which would replace SILVA with GTDB in every abundance table and barplot.
params_set pplace_name           "gtdb_bac16s"
params_set pplace_tree           "$NEXTFLOW_DIR/db/pplace/bac16s.newick"
params_set pplace_aln            "$NEXTFLOW_DIR/db/pplace/bac16s.alnfna"
params_set pplace_model          "GTR+F+I+G4"
params_set pplace_alnmethod      "clustalo"

# ampliseq analyses only the samples its metadata sheet lists.
# ampliseq_samplesheet.sh writes this one beside the samplesheet, from the same
# samples. It carries no experimental grouping - the request form collects none
# - so nothing here is compared between groups; the sheet is what keeps the
# sample set explicit.
params_set metadata              "ampliseq_metadata.tsv"

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
PARAMS_LOCKED=(input outdir metadata)

PRE_PROCESS_CMDS=(
    "$NEXTFLOW_DIR/scripts/ampliseq_samplesheet.sh"
    "$NEXTFLOW_DIR/scripts/ampliseq_detect_region.sh"
)

POST_PROCESS_CMDS=(
    "$NEXTFLOW_DIR/scripts/ampliseq_prune_tree.sh"
    "$NEXTFLOW_DIR/scripts/ampliseq_upload.sh"
)
