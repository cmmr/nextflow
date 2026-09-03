#!/usr/bin/env Rscript
#
# ampliseq_tables.R - Assemble a run's feature table, and everything read off it.
#
# Author: Daniel Smith
# Date:   September 2nd, 2026
#
# Run inside the rbiom container by ampliseq_composition.sh, which owns the
# numbers that come from outside the feature table. This owns the feature table
# itself and everything derived from it, so the file a requester downloads and
# the numbers the Overview plots are the same object read twice.
#
# The run's ASVs are assembled from what the pipeline published - the counts and
# sequences as its last filter left them, DADA2's taxonomy, and the phylogeny
# EPA-NG placed them on - into one rbiom object.
# That object is then written out three ways, and summarised two ways:
#
#   feature_table/feature-table.tsv         counts and taxonomy, classic tabular
#   feature_table/feature-table.json.biom   BIOM 1.0
#   feature_table/feature-table.hdf5.biom   BIOM 2.1, and the only one of the
#                                           three that carries the tree - the
#                                           spec's own place for it is
#                                           observation/group-metadata/phylogeny
#   abundance_tables/L<n>-<rank>-counts.tsv     counts collapsed to each rank
#   abundance_tables/L<n>-<rank>-relative.tsv   the same as sample shares
#   alpha_diversity.tsv                     per-sample diversity, unrarefied,
#                                           every index rbiom offers that a
#                                           denoised table supports
#   <plot data>                             what the Overview's charts draw
#   <statistics>                            counts for the Overview's sidebar
#
# Taxa named in exclude_taxa are dropped before any of that, so every file here
# describes the same set of ASVs. The match is a case-insensitive substring
# against the whole lineage, which is what QIIME 2's own filter did before this
# replaced it.
#
# Nothing is rarefied. These runs have no experimental grouping to compare, and
# a delivery platform is the wrong place to decide a sampling depth on a
# requester's behalf. The read depth every index was computed at is published
# beside it, and the feature table is there to be rarefied downstream.
#
# Usage: ampliseq_tables.R <results_dir> <plot_data.json> <statistics.tsv>
#            [exclude_taxa] [method]
#        exclude_taxa is a comma-separated list, or "none"; method is the
#        sentence the composition chart is captioned with, or empty
#
# Requires: rbiom (>= 3.1.0), and h5lite for the HDF5 output

suppressPackageStartupMessages(library(rbiom))

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 3)
    stop("usage: ampliseq_tables.R <results_dir> <plot_data.json> <statistics.tsv> [exclude_taxa]")

results_dir  <- sub("/$", "", args[[1]])
plot_data    <- args[[2]]
stats_file   <- args[[3]]
exclude_taxa <- if (length(args) >= 4) args[[4]] else "none"
method       <- if (length(args) >= 5) args[[5]] else ""

# The eleven the palette carries; everything rarer is summed into "Other"
TOP_TAXA <- 11

# What a rank is called on the page, by its depth in the lineage
RANK_NAMES <- c("Domain", "Phylum", "Class", "Order", "Family", "Genus", "Species")


# -- Reading what DADA2 published --------------------------------------------

# The first file a glob matches, or NULL. DADA2 names its taxonomy after the
# database the run used, so those are matched rather than spelled out.
first_file <- function (...) {
    hits <- Sys.glob(file.path(results_dir, ...))
    hits <- hits[file.exists(hits)]

    if (length(hits) == 0) NULL else hits[[1]]
}

read_tsv <- function (path)
    utils::read.table(
        path, sep = "\t", header = TRUE, quote = "", comment.char = "",
        check.names = FALSE, stringsAsFactors = FALSE, na.strings = c("NA", ""))

# One named character vector of sequences, from the fasta DADA2 wrote
read_seqs <- function (path) {
    lines  <- readLines(path, warn = FALSE)
    lines  <- lines[nzchar(lines)]
    starts <- which(startsWith(lines, ">"))

    if (length(starts) == 0) return (NULL)

    ends <- c(starts[-1] - 1, length(lines))
    seqs <- vapply(
        seq_along(starts),
        function (i) paste0(lines[(starts[[i]] + 1):ends[[i]]], collapse = ""),
        character(1))

    # The header is the ASV id, up to the first space
    names(seqs) <- sub("^>\\s*", "", sub("\\s.*$", "", lines[starts]))

    seqs
}

# The ASV set the run actually settled on. Every filter ampliseq applies
# republishes the table and the sequences under its own name, so the last one
# that ran is the run's answer - and the one EPA-NG placed on the tree. DADA2's
# own table is the fallback and still holds everything barrnap and the length
# window removed, so reading it would publish ASVs the pipeline had thrown out
# and leave the phylogeny covering only some of them.
#
# Most filtered first, and the table and the sequences are taken from the same
# stage so they cannot describe different ASVs.
ASV_SOURCES <- list(
    list(dir = "asv_length_filter", table = "ASV_table.len.tsv",
         fasta = "ASV_seqs.len.fasta", step = "the ASV length filter"),
    list(dir = "barrnap",           table = "ASV_table.ssu.tsv",
         fasta = "ASV_seqs.ssu.fasta", step = "the rRNA filter"),
    list(dir = "dada2",             table = "ASV_table.tsv",
         fasta = "ASV_seqs.fasta",    step = "DADA2"))

source      <- NULL
counts_file <- NULL

for (candidate in ASV_SOURCES) {
    counts_file <- first_file(candidate$dir, candidate$table)

    if (!is.null(counts_file)) {
        source <- candidate
        break
    }
}

if (is.null(source))
    stop("no ASV table under ", results_dir)

message("Reading the ASVs as ", source$step, " left them: ",
        sub(paste0("^", results_dir, "/"), "", counts_file))

counts_df <- read_tsv(counts_file)

if (!"ASV_ID" %in% colnames(counts_df))
    stop("dada2/ASV_table.tsv has no ASV_ID column")

otus   <- as.character(counts_df[["ASV_ID"]])
counts <- as.matrix(counts_df[, setdiff(colnames(counts_df), "ASV_ID"), drop = FALSE])
counts[is.na(counts)] <- 0
storage.mode(counts)  <- "double"
rownames(counts)      <- otus

# The taxonomy with species where the run reached it, and without where it did
# not. Everything that is not a rank goes: DADA2 writes its bootstrap
# confidences and the sequence itself into the same table.
tax_file <- first_file("dada2", "ASV_tax_species.*.tsv")
if (is.null(tax_file)) tax_file <- first_file("dada2", "ASV_tax.*.tsv")

taxonomy <- NULL

if (!is.null(tax_file)) {
    tax_df <- read_tsv(tax_file)
    ranks  <- setdiff(colnames(tax_df), c("ASV_ID", "confidence", "sequence"))
    ranks  <- ranks[!endsWith(ranks, "_confidence")]

    # addSpecies renames DADA2's own species column when it adds its exact
    # matches, so at most one of the two is kept as "Species"
    if ("Species_exact" %in% ranks) {
        if ("Species" %in% ranks) {
            ranks <- setdiff(ranks, "Species_exact")
        } else {
            colnames(tax_df)[colnames(tax_df) == "Species_exact"] <- "Species"
            ranks[ranks == "Species_exact"] <- "Species"
        }
    }

    taxonomy <- data.frame(
        .otu = as.character(tax_df[["ASV_ID"]]),
        tax_df[, ranks, drop = FALSE],
        check.names      = FALSE,
        stringsAsFactors = FALSE)

    taxonomy <- taxonomy[match(otus, taxonomy[[".otu"]]), , drop = FALSE]
    taxonomy[[".otu"]] <- otus

    # Reordering by a permutation turns R's automatic row names into explicit
    # ones, and rbiom refuses a taxonomy that carries both row names and an
    # .otu column. DADA2 does not publish its taxonomy in the table's order, so
    # this is the ordinary case rather than an edge of one.
    rownames(taxonomy) <- NULL
}

seqs_file <- first_file(source$dir, source$fasta)
sequences <- if (is.null(seqs_file)) NULL else read_seqs(seqs_file)

if (!is.null(sequences)) {
    sequences <- sequences[otus]

    # An incomplete fasta is worse than none: rbiom refuses a partial set, and
    # the sequences are published beside this either way
    if (anyNA(names(sequences)) || any(is.na(sequences))) sequences <- NULL
}

tree_file <- first_file("pplace", "asv_tree.newick")
tree      <- NULL

if (!is.null(tree_file)) {
    tree <- try(rbiom::read_tree(tree_file), silent = TRUE)

    if (inherits(tree, "try-error")) {
        message("NOTE: the phylogeny could not be read; leaving it out.")
        tree <- NULL
    } else if (!all(otus %in% tree$tip.label)) {
        #    Faith's PD needs every ASV on the tree, and rbiom will not take a
        #    tree that covers only some of them. Reaching here means the tree
        #    and the table came from different stages of the run.
        message("NOTE: the phylogeny covers ", sum(otus %in% tree$tip.label),
                " of ", length(otus), " ASVs; leaving it out.")
        tree <- NULL
    }
}


# -- The one object everything else is read from -----------------------------

biom <- rbiom::as_rbiom(
    biom      = counts,
    taxonomy  = taxonomy,
    tree      = tree,
    sequences = sequences,
    id        = "16S rRNA amplicon sequencing analysis")

# Taxa the run was told to exclude, matched the way QIIME 2 matched them: a
# case-insensitive substring against the whole lineage.
if (!identical(tolower(exclude_taxa), "none") && nzchar(exclude_taxa) &&
    !is.null(biom$taxonomy)) {

    patterns <- trimws(strsplit(exclude_taxa, ",", fixed = TRUE)[[1]])
    patterns <- patterns[nzchar(patterns)]

    if (length(patterns) > 0) {
        lineages <- apply(
            biom$taxonomy[, -1, drop = FALSE], 1,
            function (row) paste(row[!is.na(row)], collapse = ";"))

        drop <- Reduce(`|`, lapply(
            patterns,
            function (p) grepl(p, lineages, ignore.case = TRUE, fixed = FALSE)))

        keep <- biom$taxonomy[[".otu"]][!drop]

        if (length(keep) == 0)
            stop("excluding ", exclude_taxa, " removed every ASV")

        message("Excluded ", sum(drop), " of ", length(drop),
                " ASVs matching: ", exclude_taxa)

        biom <- biom$clone()
        biom$counts <- biom$counts[keep, , drop = FALSE]
    }
}

# Samples the exclusion emptied describe nothing, and a zero column breaks
# every share taken against it
depths <- rbiom::sample_sums(biom)
if (any(depths <= 0)) {
    kept <- names(depths)[depths > 0]

    if (length(kept) == 0) stop("no sample has any reads left")

    message("Dropped ", sum(depths <= 0), " sample(s) with no reads.")
    biom <- biom$clone()
    biom$counts <- biom$counts[, kept, drop = FALSE]
}


# -- The feature table, three ways -------------------------------------------

table_dir <- file.path(results_dir, "feature_table")
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)

for (spec in list(
        list(file = "feature-table.tsv",       format = "tab"),
        list(file = "feature-table.json.biom", format = "json"),
        list(file = "feature-table.hdf5.biom", format = "hdf5"))) {

    path <- file.path(table_dir, spec$file)
    unlink(path)

    written <- try(
        rbiom::write_biom(biom, path, format = spec$format),
        silent = TRUE)

    if (inherits(written, "try-error"))
        message("WARNING: could not write ", spec$file, ": ",
                conditionMessage(attr(written, "condition")))
}


# -- Counts collapsed to each rank -------------------------------------------

# The lineage of every ASV, one column per rank, as plain strings. An
# unclassified rank is empty rather than NA, so a truncated lineage reads the
# same as it did in the tables this replaces.
lineage_matrix <- function (biom) {
    if (is.null(biom$taxonomy)) return (NULL)

    mtx <- as.matrix(biom$taxonomy[, -1, drop = FALSE])
    mtx[is.na(mtx)] <- ""
    rownames(mtx) <- biom$taxonomy[[".otu"]]

    mtx
}

# What one ASV is called at a given rank: the deepest rank it was named to,
# marked "Unclassified" when that is shallower than the rank being read, and
# "Unassigned" when the classifier named nothing at all. A species is written
# beside its genus, which is the only way an epithet reads as a species.
taxon_label <- function (row, depth, genus_at, species_at) {
    for (i in depth:1) {
        if (!nzchar(row[[i]])) next

        name <- row[[i]]

        if (i == species_at && genus_at >= 1 && nzchar(row[[genus_at]]))
            name <- paste(row[[genus_at]], name)

        if (i != depth) name <- paste("Unclassified", name)

        # A sequence placed in a domain and no deeper says as little as one
        # placed nowhere
        if (identical(name, "Unclassified Bacteria") ||
            identical(name, "Unclassified Archaea")) name <- "Unassigned"

        return (name)
    }

    "Unassigned"
}

# What sits above that name, for the line under it in the legend
taxon_lineage <- function (row, depth, genus_at, species_at) {
    deepest <- 0
    for (i in depth:1) if (nzchar(row[[i]])) { deepest <- i; break }

    if (deepest <= 1) return ("")

    above <- row[1:(deepest - 1)]

    # The genus belongs to the species name rather than to the path above it
    if (deepest == species_at && genus_at >= 1 && genus_at < deepest)
        above <- above[-genus_at]

    paste(above[nzchar(above)], collapse = "; ")
}

lineages <- lineage_matrix(biom)
levels   <- list()
rank_dir <- file.path(results_dir, "abundance_tables")

if (!is.null(lineages) && ncol(lineages) > 0) {

    dir.create(rank_dir, recursive = TRUE, showWarnings = FALSE)

    ranks      <- colnames(lineages)
    genus_at   <- match("Genus",   ranks, nomatch = 0)
    species_at <- match("Species", ranks, nomatch = 0)

    mtx    <- as.matrix(biom$counts)
    totals <- colSums(mtx)

    for (depth in seq_along(ranks)) {

        labels <- vapply(
            seq_len(nrow(lineages)),
            function (i) taxon_label(lineages[i, ], depth, genus_at, species_at),
            character(1))

        collapsed <- rowsum(mtx[rownames(lineages), , drop = FALSE], labels)

        #    Published for anyone who wants every row, at every rank the
        #    classifier reached
        stem <- sprintf("L%d-%s", depth, tolower(ranks[[depth]]))

        utils::write.table(
            data.frame(taxon = rownames(collapsed), collapsed,
                       check.names = FALSE),
            file.path(rank_dir, paste0(stem, "-counts.tsv")),
            sep = "\t", quote = FALSE, row.names = FALSE, na = "")

        shares <- sweep(collapsed, 2, totals, "/")
        shares[!is.finite(shares)] <- 0

        utils::write.table(
            data.frame(taxon = rownames(shares), round(shares, 8),
                       check.names = FALSE),
            file.path(rank_dir, paste0(stem, "-relative.tsv")),
            sep = "\t", quote = FALSE, row.names = FALSE, na = "")

        #    And the eleven the chart draws, in ten-thousandths, with the tail
        #    summed into "Other" so a column always closes at ten thousand
        parts <- round(shares * 10000)
        means <- rowMeans(parts)
        order <- order(means, decreasing = TRUE)

        drawn <- head(order, TOP_TAXA)
        drawn <- drawn[means[drawn] > 0]

        first_of <- match(rownames(parts)[drawn], labels)

        taxa <- lapply(seq_along(drawn), function (k) {
            i <- drawn[[k]]
            list(
                label      = rownames(parts)[[i]],
                lineage    = taxon_lineage(lineages[first_of[[k]], ], depth,
                                           genus_at, species_at),
                mean       = unname(round(means[[i]])),
                prevalence = unname(round(sum(parts[i, ] > 0) /
                                          ncol(parts) * 100)))
        })

        values <- lapply(drawn, function (i) unname(parts[i, ]))

        drawn_total <- Reduce(`+`, values, rep(0, ncol(parts)))
        rest        <- 10000 - drawn_total

        #    Every share is rounded on its own, so a column can come out a
        #    ten-thousandth or two over. The excess comes off the tallest band
        #    drawn, which is where it is least visible, rather than leaving the
        #    stack taller than the axis it is read against.
        if (any(rest < 0) && length(values) > 0) {
            over <- which(rest < 0)

            for (i in over) {
                tallest <- which.max(vapply(values, function (v) v[[i]], numeric(1)))
                values[[tallest]][[i]] <- values[[tallest]][[i]] + rest[[i]]
            }

            rest[over] <- 0
        }

        taxa[[length(taxa) + 1]] <- list(
            label = "Other", lineage = "",
            mean = max(0, 10000 - sum(round(means[drawn]))), prevalence = 0)
        values[[length(values) + 1]] <- rest

        #    Domain is published like every other rank, but not offered as a
        #    chart: every sequence in a 16S run is expected to land in one
        if (depth < 2) next

        levels[[length(levels) + 1]] <- list(
            rank   = depth,
            name   = if (depth <= length(RANK_NAMES)) RANK_NAMES[[depth]]
                     else ranks[[depth]],
            taxa   = taxa,
            values = values)
    }
}


# -- Per-sample diversity ----------------------------------------------------

# Every index rbiom offers that means anything on a denoised ASV table, in the
# order the chart offers them: Shannon first, since that is the one a requester
# asks for by name, and the rest behind it.
#
# ace, chao1 and squares are left out. All three estimate the richness a sample
# would have shown if it had been read deeper, and all three read that off the
# ASVs seen exactly once and twice - which DADA2's denoising is built to remove.
# On this data they collapse towards the observed count and describe the
# denoiser rather than the sample.
#
# "depth" is rbiom's first column and is the read total, not an index; it is
# reported as "reads" everywhere else here.
ADIV <- list(
    list(key = "shannon",     title = "Shannon index",
         note = "richness and evenness together", places = 2),
    list(key = "observed",    title = "Observed ASVs",
         note = "distinct ASVs seen in the sample", integer = TRUE),
    list(key = "reads",       title = "Read depth",
         note = "reads assigned to ASVs", integer = TRUE, scale = "sqrt"),
    list(key = "simpson",     title = "Simpson index",
         note = "the chance two reads are different ASVs", places = 3),
    list(key = "inv_simpson", title = "Inverse Simpson",
         note = "effective number of equally common ASVs", places = 2),
    list(key = "faith",       title = "Faith's PD",
         note = "branch length of the phylogeny this sample covers", places = 2),
    list(key = "berger",      title = "Berger-Parker dominance",
         note = "the share of the sample held by its most abundant ASV", places = 3),
    list(key = "brillouin",   title = "Brillouin index",
         note = "Shannon's index for a community counted in full", places = 3),
    list(key = "fisher",      title = "Fisher's alpha",
         note = "richness fitted to a log-series abundance model", places = 2),
    list(key = "margalef",    title = "Margalef richness",
         note = "richness adjusted for how deeply the sample was read", places = 2),
    list(key = "menhinick",   title = "Menhinick richness",
         note = "ASVs per square root of read depth", places = 3),
    list(key = "mcintosh",    title = "McIntosh evenness",
         note = "evenness from the Euclidean norm of the abundances", places = 3))

# Faith's PD is the one index here that reads the phylogeny, so a run without
# one simply does not offer it
wanted <- vapply(ADIV, function (spec) spec$key, character(1))
wanted <- setdiff(wanted, "reads")

if (is.null(biom$tree)) wanted <- setdiff(wanted, "faith")

adiv <- rbiom::adiv_matrix(biom, adiv = wanted)

# An index rbiom could not compute for this run is dropped rather than
# published as a column of nothing
have <- intersect(wanted, colnames(adiv))
have <- have[vapply(have, function (k) any(is.finite(adiv[, k])), logical(1))]

rounding <- function (key) {
    for (spec in ADIV) if (identical(spec$key, key)) return (spec)
    list(places = 4)
}

alpha <- data.frame(
    sample = rownames(adiv),
    reads  = as.integer(round(adiv[, "depth"])),
    stringsAsFactors = FALSE)

for (key in have) {
    spec   <- rounding(key)
    values <- adiv[, key]
    values[!is.finite(values)] <- 0

    alpha[[key]] <- if (isTRUE(spec$integer)) as.integer(round(values))
                    else round(values, spec$places)
}

# The column DADA2's own tables call it, kept as the name the file has always
# carried
if ("observed" %in% have)
    colnames(alpha)[colnames(alpha) == "observed"] <- "observed_asvs"

alpha <- alpha[order(alpha$sample), , drop = FALSE]

utils::write.table(
    alpha, file.path(results_dir, "alpha_diversity.tsv"),
    sep = "\t", quote = FALSE, row.names = FALSE, na = "")


# -- What the Overview draws -------------------------------------------------

# The samples in the order the alpha table lists them, which is the order every
# array below follows
samples <- alpha$sample
at      <- match(samples, colnames(biom$counts))

reorder <- function (values) lapply(values, function (v) unname(v[at]))

for (i in seq_along(levels)) levels[[i]]$values <- reorder(levels[[i]]$values)

# Which indices the diversity chart offers, and how each is written out. Only
# the ones this run actually has, in the order declared above.
metric_specs <- Filter(
    function (spec) identical(spec$key, "reads") || spec$key %in% have,
    ADIV)

alpha_values <- list()
for (key in have)
    alpha_values[[key]] <- alpha[[if (key == "observed") "observed_asvs" else key]]

data <- list(
    samples = samples,
    reads   = alpha$reads,
    alpha   = alpha_values,
    metrics = metric_specs,
    levels  = levels)

# How those numbers were made, for the caption under the composition chart. Read
# off DADA2's own record of the database by the caller, which is the only thing
# here that looks outside the feature table.
if (nzchar(method)) data <- c(list(method = method), data)

# Hand-rolled rather than pulling in a JSON package: the shapes here are known,
# and the container stays to rbiom and what it needs.
json <- local({

    esc <- function (s) {
        s <- gsub("\\", "\\\\", s, fixed = TRUE)
        s <- gsub("\"", "\\\"", s, fixed = TRUE)
        s <- gsub("\n", "\\n",  s, fixed = TRUE)
        s <- gsub("\t", "\\t",  s, fixed = TRUE)
        paste0("\"", s, "\"")
    }

    enc <- function (x) {
        if (is.null(x))                       return ("null")
        if (is.list(x) && !is.null(names(x))) {
            return (paste0("{", paste(
                sprintf("%s:%s", esc(names(x)), vapply(x, enc, character(1))),
                collapse = ","), "}"))
        }
        if (is.list(x))
            return (paste0("[", paste(vapply(x, enc, character(1)),
                                      collapse = ","), "]"))
        if (is.logical(x))   return (if (length(x) == 1) tolower(as.character(x))
                                     else paste0("[", paste(tolower(as.character(x)), collapse = ","), "]"))
        if (is.character(x)) return (if (length(x) == 1) esc(x)
                                     else paste0("[", paste(vapply(x, esc, character(1)), collapse = ","), "]"))

        x <- ifelse(is.finite(x), x, 0)
        num <- format(x, scientific = FALSE, trim = TRUE, digits = 10)
        if (length(x) == 1) num else paste0("[", paste(num, collapse = ","), "]")
    }

    enc(data)
})

writeLines(json, plot_data)


# -- What the sidebar counts -------------------------------------------------

# How far down the taxonomy the classifier got, as the number of ASVs that
# reached each rank
classified <- function (rank) {
    if (is.null(lineages)) return (NULL)

    at <- match(rank, colnames(lineages), nomatch = 0)
    if (at == 0) return (NULL)

    sum(nzchar(lineages[rownames(biom$counts), at]))
}

stats <- list(
    samples = length(samples),
    asvs    = nrow(biom$counts))

# Every read that reached an ASV and survived the taxon exclusion, which is what
# the sidebar's "Retained reads" bar is taken against the run's input total
stats$reads_retained <- sum(alpha$reads)

stats$reads_min    <- min(alpha$reads)
stats$reads_median <- round(stats::median(alpha$reads))
stats$reads_max    <- max(alpha$reads)

for (entry in list(c("phylum_asvs", "Phylum"),
                   c("genus_asvs",  "Genus"),
                   c("species_asvs", "Species"))) {
    value <- classified(entry[[2]])
    if (!is.null(value)) stats[[entry[[1]]]] <- value
}

writeLines(
    vapply(names(stats),
           function (k) paste(k, stats[[k]], sep = "\t"),
           character(1)),
    stats_file)

message("Wrote the feature table and its summaries for ", length(samples),
        " samples and ", nrow(biom$counts), " ASVs.")
