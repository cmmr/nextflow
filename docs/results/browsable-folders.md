# Browsable folders

The report and the dashboard's file index both link to folders as well as to
files, and S3 serves objects rather than directories, so those links land on
nothing once the results are published.
[`index_directories.sh`](../../scripts/index_directories.sh) fills that gap in
before the upload: it walks the results folder and renders
[`templates/listing.html`](../../templates/listing.html) into **every**
directory of it, the results folder included — subfolders first, then files with
their sizes, every entry linked, and a link back up.

Names are HTML-escaped for the page and percent-encoded for the href beside it,
a byte at a time, since a filename is bytes and a `#` in one would otherwise cut
its own link short.

## The listings are never called `index.html`

They are `directory_listing.html`, and that is the whole convention:

| | |
|---|---|
| `index.html` | a page something wrote to be read — the [landing page](index.md) at the top of a run, QIIME 2's barplot under `qiime2/barplot/` |
| `directory_listing.html` | the listing of the folder it sits in, written here |

Because the two never collide, the script has no special cases: it writes a
listing into every directory it finds, whether or not the pipeline published a
page of its own there, and a second pass over the same results folder just
rewrites them. `qiime2/barplot/` ends up with both — QIIME's visualisation, and
a listing of the per-level CSVs beside it.

**Every link is written by name.** A folder row points at
`subfolder/directory_listing.html`, not at `subfolder/`, and "up one folder"
points at `../directory_listing.html`. Nothing depends on the server rewriting a
folder URL, which is what lets an unpacked copy of
[the download zip](downloads.md) browse exactly the way the published run does.

**Folder URLs are reachable too**, because CloudFront maps one onto the listing
beneath it — see [CloudFront](cloudfront.md). That is what catches the folder
links inside nf-core's own report, which this system does not write, and a
reader editing the address bar.

## Where "up one folder" ends

At the results folder, whose listing is the one page that leaves the frame: its
link out is `↑ Results dashboard`, carrying `target="_top"`. The listings below
it link up normally and stay in the frame.

That matters because the landing page reads these listings *inside itself*, and
the top of a run is the dashboard — so a chain that walked up into it without
breaking out would open a second copy of the dashboard in the dashboard's own
frame. The root listing also leaves `index.html` out of its rows for the same
reason.

The one link that would otherwise reach the same dead end is in ampliseq's
report: its `Final notes` section says the read count report "can be found in
the base results folder" and writes that as `href="../"`, which CloudFront
resolves to the dashboard. `ampliseq_upload.sh` repoints it at
`../directory_listing.html` before the upload.

## What a link on a listing does

**Whether it opens or downloads is not decided here.** It follows from the
content type each object was uploaded with — see
[What a link does when you click it](index.md#what-a-link-does-when-you-click-it).
A `.tsv` or `.log` opens in the browser because it was uploaded as `text/plain`,
not because the listing says anything about it.

Like the progress page, none of this is worth failing a run over: a listing that
cannot be built is warned about and whatever rows did come out are kept, so the
link that led there still resolves. Results nobody can browse are still results.
