# Databases

Every reference database the pipelines read lives under `db/` —
`NEXTFLOW_DB_DIR`, which `.env` sets to `$NEXTFLOW_DIR/db` — and none of it is in
git: it is a few hundred gigabytes. What *is* in git is the record of it,
[`config/databases.json`](../../config/databases.json): one entry per database,
saying what it is, what reads it, where it came from, and the command that puts
it back.

The setup scripts write a `<release>.manifest.json` beside everything they fetch
or build — source URLs, checksums, sizes, who fetched it and when — and a run
copies the manifest of every database it touches into its own `run_state.json`.
Those manifests are the provenance of one copy on one disk.
`config/databases.json` is the index over them that survives the disk.

## What is there

| Path under `db/` | What | Read by | Rebuilt with |
|---|---|---|---|
| `kraken2/pluspf_20260626` | Kraken2 + Bracken PlusPF, 2026-06-26 | taxprofiler | `scripts/fetch_taxprofiler_db.sh kraken2` |
| `metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403` | MetaPhlAn 4 markers and SGB phylogeny | taxprofiler, biobakery | `scripts/fetch_taxprofiler_db.sh metaphlan` |
| `motus/db_mOTU_v3.1.0` | mOTUs 3.1.0 | taxprofiler, biobakery | `scripts/fetch_taxprofiler_db.sh motus` |
| `humann/v201901b` | ChocoPhlAn v201901_v31, UniRef90 v201901b, utility mapping | taxprofiler, biobakery | `scripts/fetch_taxprofiler_db.sh humann` |
| `esviritu/v3.2.4` | EsViritu virus pathogen database v3.2.4 | biobakery | `scripts/fetch_taxprofiler_db.sh esviritu` |
| `markermagu/v1.1` | Marker-MAGu marker genes v1.1 | biobakery | `scripts/fetch_taxprofiler_db.sh markermagu` |
| `hostremoval/phix` | PhiX (GCF_000819615.1) | taxprofiler, biobakery | `scripts/build_host_reference.sh phix GCF_000819615.1` |
| `hostremoval/chm13v2phix` | T2T-CHM13v2.0 (GCF_009914755.1) + PhiX | taxprofiler, biobakery | `scripts/build_host_reference.sh chm13v2phix GCF_009914755.1 GCF_000819615.1` |
| `hostremoval/grcm39phix` | GRCm39 (GCF_000001635.27) + PhiX | taxprofiler, biobakery | `scripts/build_host_reference.sh grcm39phix GCF_000001635.27 GCF_000819615.1` |
| `ampliseq` | SILVA 138.2 formatted for DADA2 | ampliseq | fetched by nf-core/ampliseq itself into `ref_taxonomy_storage` |
| `pplace` | SBDI GTDB bacterial 16S alignment and tree, R11-RS232-1 | ampliseq | `scripts/build_pplace_reference.sh` |
| `16s` | 16S landmarks from eight RefSeq genomes | `ampliseq_detect_region.sh` | `scripts/build_16s_reference.sh` |
| `sylph` | sylph GTDB r220 sketch and taxonomy | nothing | `fetch_taxprofiler_db.sh sylph` as of commit `d7b7500` |
| `test-fastq` | seven small runs from nf-core/test-datasets, all one ancient paleofeces sample | runs by hand | `curl` from the URLs in the entry |
| `test-fastq/PRJEB27054` | five paired runs of untreated sewage, one per country | runs by hand | `scripts/fetch_taxprofiler_db.sh sewage` |

**`sylph/` is unused.** sylph came out of taxprofiler when HUMAnN went in
(commit `adeee55`), and its fetch function went with it. The entry keeps its
sources so the 13 GB sketch can be deleted without losing track of what it was.

**`ampliseq/` has no manifest.** nf-core/ampliseq downloads what
`ref_taxonomy_storage` lacks on its own, from the Zenodo record the entry names,
and writes nothing beside it.

## An entry

```json
{
  "path": "hostremoval/chm13v2phix",
  "name": "Human T2T-CHM13v2.0 + PhiX",
  "release": "...",
  "description": "...",
  "used_by": ["biobakery: kneaddata_db", "..."],
  "setup": "scripts/build_host_reference.sh chm13v2phix GCF_009914755.1 GCF_000819615.1",
  "manifest": "hostremoval/chm13v2phix.manifest.json",
  "sources": [
    { "label": "human T2T-CHM13v2.0", "accession": "GCF_009914755.1", "cite": ["nurk2022"] }
  ],
  "components": { "<subdirectory>": { "name": "...", "release": "...", "cite": ["..."] } },
  "doi": null,
  "cite": ["oleary2016"]
}
```

| Field | Holds |
|---|---|
| `path` | where it is under `db/`, which is how a run's parameter is matched to it |
| `name`, `release` | what the Methods page calls it: "the *name* database (*release*)", or just the release when the name already contains it |
| `used_by` | the pipeline and the parameter or file that names it |
| `setup` | the command that rebuilds it from nothing |
| `manifest` | the provenance file the setup script wrote, under `db/`, or `null` |
| `sources` | what it was built from: URLs and checksums, or genome accessions with the `label` the Methods page names each by |
| `components` | a database read as several directories, keyed by subdirectory — `humann/v201901b/uniref90` is the `uniref90` component of `humann/v201901b` |
| `doi` | the dataset's own DOI where the publisher minted one; the Methods page writes it beside the release |
| `cite` | ids in [`config/references.json`](../../config/references.json) for the papers to cite it by |

`config/references.json` holds each citation once, as fields rather than
formatted text, so the Methods page can write the same reference both formatted
and as BibTeX:

| Field | Holds |
|---|---|
| `type` | `article`, or `misc` for software and datasets |
| `author` | `"Family, Initials"` per person — `"Di Tommaso, P"` — or an organisation as written |
| `et_al` | `true` when `author` is cut short; formatted as "et al", BibTeX as `and others` |
| `title`, `year` | as published |
| `journal`, `journal_abbrev` | the full name for BibTeX, the NLM abbreviation for the formatted list |
| `volume`, `number`, `pages` | an article's; pages with an en dash |
| `publisher` | a `misc` entry's |
| `doi`, or `url` | where the reference links to |
| `cite` | the in-text citation, only where the authors cannot give it — "SBDI, 2021" |

## Adding a database

1. Fetch or build it with a script that writes a manifest beside it, as
   `fetch_taxprofiler_db.sh` and `build_host_reference.sh` do.
2. Add its entry to `config/databases.json`, and any paper it should be cited by
   to `config/references.json`.
3. Point the pipeline at it with a path under `$NEXTFLOW_DB_DIR`.

A path a run reads that has no entry still runs; the Methods page names it by its
directory and `biobakery_methods.sh` warns.
