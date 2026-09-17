// bioBakery shotgun metagenomics: KneadData, then MetaPhlAn, then HUMAnN, with
// mOTUs and Nonpareil beside them for diversity, EsViritu for viruses and
// Marker-MAGu for phages.
//
// KneadData and MetaPhlAn run on every sample. HUMAnN, mOTUs, Nonpareil,
// EsViritu, Marker-MAGu and any add-on module run behind a run_<tool> parameter
// of their own. Modules are in modules/ and
// read two channels: ch_reads, KneadData's cleaned reads as [meta, reads], and
// ch_profiles, MetaPhlAn's profile per sample as [meta, profile]. An add-on
// publishes under <outdir>/<tool>/.
//
// Every database is a parameter; nothing here names a path on any host.
// See docs/pipelines/biobakery.md.

nextflow.enable.dsl = 2

include { KNEADDATA; KNEADDATA_COUNTS }                           from '../../modules/kneaddata.nf'
include { METAPHLAN; METAPHLAN_MERGE }                            from '../../modules/metaphlan.nf'
include { HUMANN_PREPARE_PROFILE; HUMANN_PROFILE; HUMANN_TABLES } from '../../modules/humann.nf'
include { MOTUS; MOTUS_MERGE }                                    from '../../modules/motus.nf'
include { NONPAREIL; NONPAREIL_CURVES }                           from '../../modules/nonpareil.nf'
include { ESVIRITU; ESVIRITU_SUMMARY }                            from '../../modules/esviritu.nf'
include { MARKERMAGU; MARKERMAGU_MERGE }                          from '../../modules/markermagu.nf'
include { MULTIQC }                                               from '../../modules/multiqc.nf'

// A database parameter as a path, failing the run before any task starts when
// it is unset or missing
def database(name) {
    if (!params[name]) {
        error "--${name} is required by the modules this run enables"
    }

    return file(params[name], checkIfExists: true)
}

def short_read(row) {
    return (row.instrument_platform ?: 'ILLUMINA').toUpperCase() == 'ILLUMINA'
}

workflow {
    if (!params.input)  { error "No samplesheet: pass --input" }
    if (!params.outdir) { error "No output directory: pass --outdir" }

    // One row per sequencing run: sample, run_accession, instrument_platform,
    // fastq_1 and fastq_2
    ch_rows = Channel
        .fromPath(params.input, checkIfExists: true)
        .splitCsv(header: true)

    ch_rows
        .filter { row -> !short_read(row) }
        .map { row -> row.sample }
        .unique()
        .subscribe { sample -> log.warn "Skipping ${sample}: its reads are not short reads" }

    // [meta, [fastq_1 of each run], [fastq_2 of each run]], with the second list
    // empty for single-end samples
    ch_raw = ch_rows
        .filter { row -> short_read(row) }
        .map { row ->
            [ row.sample,
              file(row.fastq_1, checkIfExists: true),
              row.fastq_2 ? file(row.fastq_2, checkIfExists: true) : null ]
        }
        .groupTuple()
        .map { sample, fastq_1, fastq_2 ->
            def mates = fastq_2.findAll { it != null }

            if (mates && mates.size() != fastq_1.size()) {
                error "Sample ${sample} mixes paired and single-end runs"
            }

            [ [ id: sample, single_end: !mates ], fastq_1, mates ]
        }

    KNEADDATA(
        ch_raw,
        params.kneaddata_db ? file(params.kneaddata_db, checkIfExists: true) : []
    )

    KNEADDATA_COUNTS(KNEADDATA.out.log.collect())

    ch_reads = KNEADDATA.out.reads

    METAPHLAN(ch_reads, database('metaphlan_db'))
    METAPHLAN_MERGE(METAPHLAN.out.profile.map { meta, profile -> profile }.collect())

    ch_profiles = METAPHLAN.out.profile

    ch_multiqc = KNEADDATA.out.fastqc.mix(KNEADDATA_COUNTS.out.multiqc)

    if (params.run_motus) {
        def motus_db = database('motus_db')

        MOTUS(ch_reads, motus_db)
        MOTUS_MERGE(MOTUS.out.profile.map { meta, profile -> profile }.collect(), motus_db)

        ch_multiqc = ch_multiqc.mix(MOTUS.out.log)
    }

    if (params.run_nonpareil) {
        NONPAREIL(ch_reads)
        NONPAREIL_CURVES(NONPAREIL.out.npo.map { meta, npo -> npo }.collect())

        ch_multiqc = ch_multiqc.mix(NONPAREIL_CURVES.out.json)
    }

    if (params.run_esviritu) {
        ESVIRITU(ch_reads, database('esviritu_db'))
        ESVIRITU_SUMMARY(ESVIRITU.out.results.map { meta, results -> results }.collect())
    }

    if (params.run_markermagu) {
        MARKERMAGU(ch_reads, database('markermagu_db'))

        MARKERMAGU_MERGE(
            MARKERMAGU.out.profile.map { meta, profile -> profile }.collect(),
            MARKERMAGU.out.stats.collect()
        )
    }

    if (params.run_humann) {
        HUMANN_PREPARE_PROFILE(ch_profiles.map { meta, profile -> [ meta.id, profile ] })

        HUMANN_PROFILE(
            ch_reads
                .map { meta, reads -> [ meta.id, reads ] }
                .join(HUMANN_PREPARE_PROFILE.out),
            database('humann_chocophlan'),
            database('humann_uniref')
        )

        HUMANN_TABLES(
            HUMANN_PROFILE.out.genefamilies.collect(),
            HUMANN_PROFILE.out.pathabundance.collect(),
            HUMANN_PROFILE.out.pathcoverage.collect(),
            HUMANN_PROFILE.out.log.collect(),
            database('humann_utility_mapping')
        )
    }

    MULTIQC(ch_multiqc.flatten().collect())
}
