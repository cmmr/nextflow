// MetaPhlAn 4.1.1 taxonomic profiling, and every sample's profile merged.
//
// Pinned to 4.1.1 and the mpa_vJun23 database because HUMAnN 3.9 accepts only
// profiles that name vJun23. Profiles are written with -t rel_ab_w_read_stats
// and --unclassified_estimation, so each row carries coverage and an estimated
// read count, and relative abundance is a share of every read processed.
// Published to <outdir>/metaphlan/.

process METAPHLAN {
    tag "${meta.id}"

    container 'quay.io/biocontainers/metaphlan:4.1.1--pyhdfd78af_0'

    publishDir "${params.outdir}/metaphlan/profiles", mode: 'copy', pattern: '*.metaphlan_profile.txt'

    input:
    tuple val(meta), path(reads)
    path db

    output:
    tuple val(meta), path("${meta.id}.metaphlan_profile.txt"), emit: profile

    script:
    def input = [reads].flatten().join(',')
    """
    # The release named by the directory when it holds that index, otherwise the
    # one index the directory holds
    INDEX=${db.name}

    if ! ls ${db}/\$INDEX.rev.1.bt2* > /dev/null 2>&1; then
        INDEX=\$(find -L ${db} -maxdepth 1 -name '*.rev.1.bt2*' \\
            | sed 's#.*/##; s#\\.rev\\.1\\.bt2.*##' | sort -u)

        if [ "\$(printf '%s\\n' "\$INDEX" | grep -c .)" -ne 1 ]; then
            echo "Expected one MetaPhlAn index in ${db}, found: \$INDEX" >&2
            exit 1
        fi
    fi

    metaphlan ${input} \\
        --input_type fastq \\
        --bowtie2db ${db} \\
        --index \$INDEX \\
        --nproc ${task.cpus} \\
        --bowtie2out ${meta.id}.bowtie2out.txt \\
        --sample_id ${meta.id} \\
        -t rel_ab_w_read_stats \\
        --unclassified_estimation \\
        ${params.metaphlan_args ?: ''} \\
        -o ${meta.id}.metaphlan_profile.txt

    rm -f ${meta.id}.bowtie2out.txt
    """

    stub:
    """
    {
        printf '#mpa_vJun23_CHOCOPhlAnSGB_202403\\n'
        printf '#metaphlan stub\\n'
        printf '#2000 reads processed\\n'
        printf '#SampleID\\t${meta.id}\\n'
        printf '#estimated_reads_mapped_to_known_clades:1500\\n'
        printf '#clade_name\\tclade_taxid\\trelative_abundance\\tcoverage\\testimated_number_of_reads_from_the_clade\\n'
        printf 'UNCLASSIFIED\\t-1\\t25.0\\t\\n'
        printf 'k__Bacteria\\t2\\t75.0\\t-\\t1500\\n'
        printf 'k__Bacteria|p__Bacillota\\t2|1239\\t75.0\\t-\\t1500\\n'
        printf 'k__Bacteria|p__Bacillota|c__Clostridia\\t2|1239|186801\\t75.0\\t-\\t1500\\n'
        printf 'k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales\\t2|1239|186801|186802\\t75.0\\t-\\t1500\\n'
        printf 'k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales|f__Lachnospiraceae\\t2|1239|186801|186802|186803\\t75.0\\t-\\t1500\\n'
        printf 'k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales|f__Lachnospiraceae|g__Blautia\\t2|1239|186801|186802|186803|572511\\t75.0\\t-\\t1500\\n'
        printf 'k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales|f__Lachnospiraceae|g__Blautia|s__Blautia_obeum\\t2|1239|186801|186802|186803|572511|40520\\t75.0\\t12.5\\t1500\\n'
        printf 'k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales|f__Lachnospiraceae|g__Blautia|s__Blautia_obeum|t__SGB4810\\t2|1239|186801|186802|186803|572511|40520|\\t75.0\\t12.5\\t1500\\n'
    } > ${meta.id}.metaphlan_profile.txt
    """
}

// The per-sample profiles as one table of relative abundances, sample by
// column, and the same restricted to species rows
process METAPHLAN_MERGE {
    container 'quay.io/biocontainers/metaphlan:4.1.1--pyhdfd78af_0'

    publishDir "${params.outdir}/metaphlan", mode: 'copy'

    input:
    path profiles, stageAs: 'profiles/*'

    output:
    path 'metaphlan-relab.tsv'        , emit: merged
    path 'metaphlan-species-relab.tsv', emit: species

    script:
    """
    # merge_metaphlan_tables.py names each column after its file, so each
    # profile is linked in under its sample name
    mkdir named

    for profile in profiles/*.metaphlan_profile.txt; do
        name=\${profile##*/}
        ln -s ../\$profile named/\${name%.metaphlan_profile.txt}.txt
    done

    merge_metaphlan_tables.py named/*.txt > metaphlan-relab.tsv

    awk -F'\\t' 'NR <= 2 || (\$1 ~ /\\|s__/ && \$1 !~ /\\|t__/)' metaphlan-relab.tsv \\
        > metaphlan-species-relab.tsv
    """
}
