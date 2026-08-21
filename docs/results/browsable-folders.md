# Browsable folders

The report links to folders as well as to files, and S3 serves objects rather
than directories, so those links land on nothing once the results are published.
[`index_directories.sh`](../../scripts/index_directories.sh) fills that gap in before
the upload: it walks the results folder and renders
[`templates/listing.html`](../../templates/listing.html) into every subdirectory below it,
listing what that folder holds — subfolders first, then files with their sizes,
every entry linked, and a link back up. Names are HTML-escaped for the page and
percent-encoded for the href beside it, a byte at a time, since a filename is
bytes and a `#` in one would otherwise cut its own link short.

**Those pages are only reachable because CloudFront maps a folder URL onto the
`index.html` beneath it.** A viewer request function does it — see
[CloudFront](cloudfront.md) — and without it every folder link in a
report is a 404, whatever `index_directories.sh` wrote.

A directory that already carries an `index.html` keeps it, so pages the pipeline
published itself are left alone and a second pass over the same results folder
changes nothing. The results folder itself is skipped — that `index.html` is the
landing page in [The results page](index.md), which goes up last. Like the progress page, none of this is
worth failing a run over: results nobody can browse are still results.
