// KneadData 0.12.4: Trimmomatic trimming, tandem repeat removal and bowtie2
// depletion against one host index, with FastQC before and after, and every
// sample's read counts as one table. Published to <outdir>/kneaddata/.

process KNEADDATA {
    tag "${meta.id}"

    container 'quay.io/biocontainers/kneaddata:0.12.4--pyhdfd78af_0'

    publishDir "${params.outdir}/kneaddata/logs", mode: 'copy', pattern: '*.log'
    publishDir "${params.outdir}/kneaddata", mode: 'copy', pattern: 'fastqc/*.{html,zip}'
    publishDir "${params.outdir}/kneaddata", mode: 'copy', pattern: 'clean/*.fastq.gz', enabled: params.save_clean_reads

    input:
    tuple val(meta), path(fastq_1, stageAs: 'raw/1/?/*'), path(fastq_2, stageAs: 'raw/2/?/*')
    path db

    output:
    tuple val(meta), path('clean/*.fastq.gz'), emit: reads
    path "${meta.id}.log"                    , emit: log
    path 'fastqc/*.zip'                      , emit: fastqc, optional: true
    path 'fastqc/*.html'                     , emit: fastqc_html, optional: true

    script:
    def id       = meta.id
    def input    = meta.single_end ? "--unpaired ${id}_R1.fastq" : "--input1 ${id}_R1.fastq --input2 ${id}_R2.fastq"
    def database = db ? "--reference-db ${db}" : ''
    def heap     = task.memory ? "--max-memory ${(task.memory.toMega() * 3 / 4) as long}m" : ''
    """
    # A sample's runs, in samplesheet order, as one file per mate
    gzip -cdf ${fastq_1} > ${id}_R1.fastq
    ${meta.single_end ? '' : "gzip -cdf ${fastq_2} > ${id}_R2.fastq"}

    # KneadData applies --max-memory only when it runs Trimmomatic's jar itself.
    # Found on PATH, it runs the bioconda wrapper, which caps the heap at 1 GB.
    mkdir trimmomatic
    ln -s "\$(find -L /usr/local/share -name 'trimmomatic*.jar' | head -n 1)" trimmomatic/

    kneaddata ${input} \\
        --output out \\
        --output-prefix ${id} \\
        ${database} \\
        --threads ${task.cpus} \\
        --trimmomatic trimmomatic \\
        ${heap} \\
        --sequencer-source ${params.kneaddata_sequencer_source} \\
        --run-fastqc-start \\
        --run-fastqc-end \\
        --remove-intermediate-output \\
        ${params.kneaddata_args ?: ''}

    rm -f ${id}_R1.fastq ${id}_R2.fastq

    # The files the log lists as final. Their names depend on whether a host
    # was depleted, and intermediates are left beside them either way.
    mkdir clean

    awk '/Final output files? created/ { final = 1; next }
         final && /^\\// { print; next }
         { final = 0 }' out/${id}.log > final.txt

    while read -r path; do
        gzip -1 -c "out/\${path##*/}" > "clean/\${path##*/}.gz"
    done < final.txt

    ls clean/*.fastq.gz > /dev/null

    # With no host KneadData logs no count after Tandem Repeats Finder, so the
    # final files are counted into the log in its own READ COUNT format
    if ! grep -q 'READ COUNT: final ' out/${id}.log; then
        while read -r path; do
            name=\${path##*/}

            case "\$name" in
                *unmatched[._][12].fastq|*single[._][12].fastq) type="orphan\${name: -7:1}" ;;
                *[._]1.fastq) type=pair1 ;;
                *[._]2.fastq) type=pair2 ;;
                *)            type=single ;;
            esac

            printf 'INFO: READ COUNT: final %s : Total reads counted by the workflow in the final output ( %s ): %d.0\\n' \\
                "\$type" "\$path" \$(( \$(wc -l < "out/\$name") / 4 )) >> out/${id}.log
        done < final.txt
    fi

    rm final.txt

    mv out/${id}.log ${id}.log
    mv out/fastqc fastqc
    """

    stub:
    """
    mkdir clean fastqc

    for mate in 1 2; do
        printf '@r1\\nACGT\\n+\\nIIII\\n' | gzip > clean/${meta.id}_paired_\$mate.fastq.gz
    done

    printf 'INFO: READ COUNT: raw pair1 : Initial number of reads ( x ): 2000.0\\n' > ${meta.id}.log
    printf 'INFO: READ COUNT: final pair1 : Total reads after merging results from multiple databases ( x ): 1500.0\\n' >> ${meta.id}.log
    touch fastqc/${meta.id}_R1_fastqc.zip
    """
}

// Every sample's READ COUNT log lines as one table: a row per sample, a column
// per stage and file type ("raw pair1", "decontaminated host orphan2", ...)
// ordered raw, trimmed, decontaminated, final. A count a sample has no line
// for is NA. kneaddata_read_count_table is not used: it names a sample by its
// log file name up to the first dot.
process KNEADDATA_COUNTS {
    container 'quay.io/biocontainers/kneaddata:0.12.4--pyhdfd78af_0'

    publishDir "${params.outdir}/kneaddata", mode: 'copy'

    input:
    path logs, stageAs: 'logs/*'

    output:
    path 'read-counts.tsv'                , emit: table
    path 'kneaddata_read_counts_mqc.tsv'  , emit: multiqc

    script:
    """
    LC_ALL=C awk -F': ' '
        FNR == 1 {
            sample = FILENAME
            sub(/^.*\\//, "", sample)
            sub(/\\.log\$/, "", sample)
            samples[++n] = sample
        }

        /READ COUNT: / {
            type = \$0
            sub(/.*READ COUNT: /, "", type)
            sub(/ : .*/, "", type)

            if (!(type in seen)) {
                seen[type] = 1
                types[++t] = type
            }

            count[sample, type] = sprintf("%d", \$NF)
        }

        END {
            split("raw trimmed decontaminated final", stages, " ")

            for (s = 1; s <= 4; s++)
                for (i = 1; i <= t; i++)
                    if (index(types[i], stages[s] " ") == 1) order[++m] = types[i]

            printf "sample"
            for (i = 1; i <= m; i++) printf "\\t%s", order[i]
            printf "\\n"

            for (j = 1; j <= n; j++) {
                printf "%s", samples[j]
                for (i = 1; i <= m; i++)
                    printf "\\t%s", ((samples[j], order[i]) in count) ? count[samples[j], order[i]] : "NA"
                printf "\\n"
            }
        }
    ' logs/*.log > read-counts.tsv

    # The same table as a MultiQC section of its own
    {
        printf '# id: "kneaddata"\\n'
        printf '# section_name: "KneadData"\\n'
        printf '# description: "Reads per sample after each KneadData step."\\n'
        printf '# plot_type: "table"\\n'
        cat read-counts.tsv
    } > kneaddata_read_counts_mqc.tsv
    """
}
