#!/usr/bin/env python3
"""markermagu_tables.py - Marker-MAGu's profile as the tables MetaPhlAn's are published as.

Author: Daniel Smith
Date:   September 17th, 2026

Marker-MAGu reports one row per species-level genome bin (SGB) per sample, in
long form. This turns that into the same three levels of detail
METAPHLAN_MERGE publishes, so the two profiles can be read side by side:

  virus-counts.tsv, virus-relab.tsv    every clade from kingdom to SGB, one
                                       column per sample, as reads and as a
                                       percentage
  virus-taxa-counts.*                  the SGB rows as a feature table, in
                                       classic tabular BIOM, BIOM 1.0 JSON and
                                       BIOM 2.1 HDF5, keyed by the SGB's own
                                       name - vSGB_8081 for a phage,
                                       GGB60231_SGB82174 for a bacterium - with
                                       its lineage as the taxonomy

A clade's value is the sum of its SGBs'. The counts are reads aligned to marker
genes, not an estimate of every read an organism contributed the way MetaPhlAn's
are, so a sample's column totals its marker gene reads rather than its
sequencing depth. There is no UNCLASSIFIED row: Marker-MAGu reports no
unclassified share, and rescales each sample's abundances to 100% of what it
identified.

The samples and their order come from the read counts rather than from the
profile, so a sample Marker-MAGu detected nothing in is a column of zeros
rather than a column missing.

Marker-MAGu publishes no phylogeny of its SGBs - its phage genera and species
are clusters rather than named clades - so the BIOM tables carry no tree, and
UniFrac and Faith's PD cannot be computed from them.

Usage:     markermagu_tables.py <profile_tsv> <read_counts_tsv> <database>
Called by: MARKERMAGU_TABLES, in modules/markermagu.nf
Requires:  biom-format, h5py and numpy, in the biom-format container
Outputs:   virus-counts.tsv, virus-relab.tsv, virus-taxa-counts.tsv,
           virus-taxa-counts.json.biom and virus-taxa-counts.hdf5.biom
"""

import sys

import h5py
import numpy
from biom.table import Table

GENERATED_BY = "markermagu_tables.py"
TABLE_ID = "Marker-MAGu SGB read counts"

COUNTS = "virus-counts.tsv"
RELAB = "virus-relab.tsv"
TAXA = "virus-taxa-counts"

# lineage, total_genes, detected_genes, total_length, total_aligned_reads,
# RPKM, rel_abundance, sampleID
READS_COLUMN = 4
SHARE_COLUMN = 6
SAMPLE_COLUMN = 7


def note(message):
    print(f"{GENERATED_BY}: {message}", file=sys.stderr)


# The samples in the order the read counts list them
def read_samples(path):
    with open(path) as handle:
        handle.readline()

        return [line.split("\t")[0] for line in handle if line.strip()]


# Every clade from kingdom to SGB as [lineage, reads, share], the reads and the
# percentage summed over the SGBs under it, sorted so that each clade follows
# the one it sits under
def read_clades(path, samples):
    column = {sample: index for index, sample in enumerate(samples)}
    reads = {}
    share = {}

    with open(path) as handle:
        handle.readline()

        for line in handle:
            fields = line.rstrip("\n").split("\t")

            if len(fields) <= SAMPLE_COLUMN:
                continue

            sample = fields[SAMPLE_COLUMN]

            if sample not in column:
                note(f"the profile has a row for {sample}, which the read counts do not list")
                continue

            ranks = fields[0].split("|")

            for depth in range(1, len(ranks) + 1):
                clade = "|".join(ranks[:depth])

                if clade not in reads:
                    reads[clade] = numpy.zeros(len(samples), dtype=int)
                    share[clade] = numpy.zeros(len(samples))

                reads[clade][column[sample]] += int(fields[READS_COLUMN])
                share[clade][column[sample]] += float(fields[SHARE_COLUMN]) * 100

    return [[clade, reads[clade], share[clade]] for clade in sorted(reads)]


def write_profile(path, database, samples, rows, values, template):
    with open(path, "w") as handle:
        handle.write(f"#{database}\n")
        handle.write("\t".join(["clade_name"] + samples) + "\n")

        for row in rows:
            handle.write("\t".join([row[0]] + [template % value for value in row[values]]) + "\n")


def write_biom(prefix, samples, sgbs):
    data = numpy.array([row[1] for row in sgbs], dtype=int).reshape(len(sgbs), len(samples))

    table = Table(
        data,
        [row[0].split("|")[-1][3:] for row in sgbs],
        samples,
        observation_metadata=[{"taxonomy": row[0].split("|")} for row in sgbs] or None,
        table_id=TABLE_ID,
        type="Taxon table",
    )

    # Classic tabular BIOM, written here so the counts stay whole numbers
    with open(prefix + ".tsv", "w") as handle:
        handle.write("# Constructed from biom file\n")
        handle.write("\t".join(["#OTU ID"] + samples + ["taxonomy"]) + "\n")

        for lineage, counts, _ in sgbs:
            ranks = lineage.split("|")
            handle.write("\t".join([ranks[-1][3:]] + [str(count) for count in counts]
                                   + ["; ".join(ranks)]) + "\n")

    # biom-format writes an empty table as JSON no reader accepts
    if not sgbs:
        note("no SGB to tabulate; only the empty classic table is written")
        return

    with open(prefix + ".json.biom", "w") as handle:
        handle.write(table.to_json(GENERATED_BY))

    with h5py.File(prefix + ".hdf5.biom", "w") as handle:
        table.to_hdf5(handle, GENERATED_BY, compress=True)


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {GENERATED_BY} <profile_tsv> <read_counts_tsv> <database>", file=sys.stderr)
        return 2

    profile_tsv, read_counts_tsv, database = sys.argv[1:]

    samples = read_samples(read_counts_tsv)
    clades = read_clades(profile_tsv, samples)

    write_profile(COUNTS, database, samples, clades, 1, "%d")
    write_profile(RELAB, database, samples, clades, 2, "%.5f")

    sgbs = [row for row in clades if row[0].split("|")[-1].startswith("s__")]

    write_biom(TAXA, samples, sgbs)

    note(f"wrote {len(clades)} clades, {len(sgbs)} of them SGBs, over "
         f"{len(samples)} samples, from {database}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
