# Downloading a whole run

A dashboard is a few hundred files across a dozen folders, and the thing a
client most wants to do before their [expiration date](../operations/expiration.md)
is take a copy of all of it. One address does that:

```
https://$AWS_S3_BUCKET/download/<uid>
```

It answers with the whole of `nxf/<uid>/` as a single zip, named for the run
rather than for its uid — `PQ9999999-3xk9mp2q.zip`. Unpacking it and opening
`index.html` gives the same dashboard: every link in it is relative, so the
navigation bar, the Overview, the file index and the folder listings all still
resolve against the extracted folder.

**A copy read off a disk still wants a network**, because the three pages of the
dashboard fetch Tailwind and their fonts from a CDN — see [How the pages are
styled](index.md#how-the-pages-are-styled). Everything is there and every link
works; with no network at all it is the styling that is missing, not the
results.

The **Download Everything** button points here, under the quick downloads in the
Overview's sidebar. It is the one absolute link on the page, since the zip is
served by a behavior of the distribution rather than sitting beside the page —
which is also why it is the one link that does not resolve in an unpacked copy.

## Why it is not just a Lambda that returns a zip

The obvious shape — one function that reads the objects and returns the archive
— cannot carry this data, and the ceiling is low enough to hit on the first
real run:

| Route | Response limit |
|---|---|
| Lambda, buffered | 6 MB |
| API Gateway | 10 MB |
| Lambda response streaming | 200 MB, and 2 MB/s past the first 6 MB |

A run's `raw-sequences.zip` alone is routinely larger than all three. So the
function never touches the bytes on their way to the reader: it writes the zip
into the bucket and hands back a presigned link, and **S3 serves the download**,
at S3's bandwidth and with no size limit or timeout of its own.

That leaves the wait. A multi-gigabyte zip takes minutes to build, and no
CloudFront request will stay open that long, so the address answers immediately
with one of three things.

## The three answers

[`nxf_download.py`](../../lambda/nxf_download.py) is the dispatcher, and it is
the only thing behind the URL. It checks for `zip/<uid>.zip` and answers:

- **The zip is built** — `302` to a presigned S3 URL for it, carrying a
  `Content-Disposition` that names the file after the run. The reader's browser
  starts downloading and never sees the redirect.
- **A build is already running** — a page that says so, with a progress bar.
- **Neither** — the same page, after invoking the builder asynchronously.

The waiting page polls `?status` beside it, which is the same function answering
the same three cases as JSON. When the poll comes back `ready`, the page
navigates to the URL it was given and the download starts on its own. Without
scripting, a `<noscript>` meta refresh reloads the address every twenty seconds
and eventually collects the `302` instead.

The build is claimed by writing `zip/<uid>.json` *before* the builder is
invoked, so a reader who clicks twice, or reloads the waiting page, does not
start a second one.

A `uid` that is not eight base32 characters, and a `uid` with nothing published
under it, are both answered with a page saying so rather than a build. An
expired dashboard falls into the second case: its `index.html` is the expired
page, so the run is still found — which is why the check is for the dashboard,
not for the prefix.

## Building the zip

[`nxf_download_builder.py`](../../lambda/nxf_download_builder.py) does the work,
and does it without ever holding the run. It streams each object out of S3 and
into a zip that is itself streamed into an S3 multipart upload, so what is in
memory at any moment is the read-ahead buffer plus the parts in flight — a few
hundred MB — whatever the size of the run.

That is possible because `zipfile` finds no `seek()` on the sink it is given and
falls back to writing each entry with a trailing data descriptor, which is the
format's way of recording a size and a CRC that were not known when the entry
started. Entries at or above 2 GB get zip64 headers.

**Already-compressed objects are stored, not deflated.** The reads arrive
gzipped and the QIIME 2 artifacts are themselves zips; deflating them again
would spend the whole time budget to save nothing. `STORED_EXTENSIONS` is that
list. Everything else — the reports, the tables, the logs — is deflated at level
1, which is fast enough not to be the bottleneck and still turns a 250 MB
MultiQC log into a few MB.

Reading and uploading overlap: a reader thread fills a bounded queue while the
main thread writes the zip, and finished parts go up through a small thread
pool. Without that, every part upload would stall the read behind it.

Progress goes to `zip/<uid>.json` every couple of seconds — files done, bytes
done, and the totals — which is what the waiting page draws its bar from.

### When it cannot

A build has Lambda's fifteen minutes and no more, so the builder refuses a run
it could not finish rather than spending the time discovering that:
`MAX_TOTAL_BYTES` defaults to 100 GB. It also stops with 45 seconds to spare if
the run is going to overrun anyway.

Either way the multipart upload is aborted — so no half-written zip is ever
completed — and the reason is written to `zip/<uid>.json` as a `failed` state.
The waiting page reloads, and the address then serves a page carrying that
reason and pointing back at the individual download links on the results page.
Messages the reader is meant to read are raised as `DownloadError`; anything
else is logged in full and reported as a generic sentence, so an S3 error code
never lands on a client's screen.

The async invocation is configured with **no retries** — a build that failed
will fail the same way again, and the reason is already recorded for the page to
read.

## Where the zip lives, and when it goes

The cache is `s3://$AWS_S3_BUCKET/$S3_ZIP_PREFIX/<uid>.zip`, alongside its
`<uid>.json`. It is a prefix of its own rather than a folder inside the run,
which keeps it out of the dashboard's file index, out of the folder listings,
and out of its own next rebuild.

Being outside `nxf/<uid>/` also means the tear-downs do not reach it on their
own, and a zip that outlived its dashboard would break the promise the
expiration notice makes — *this page and every file it links to are deleted on
this date*. So both tear-downs delete it explicitly:

- [`wrike_expiration.sh`](../operations/expiration.md) adds the two keys to the
  batch it deletes when a dashboard reaches its date.
- [`wrike_delete_handler.sh`](../../scripts/wrike_delete_handler.sh) removes
  them when the task is deleted or unfiled.

A lifecycle rule of three days on the prefix is the backstop, and is also what
keeps a cache from accumulating for runs nobody ever asks about again. The same
rule should abort incomplete multipart uploads after a day, which is what
collects a build that died between its last part and its completion.

## What it is made of

Six things, none of which exist until somebody builds them:

| | |
|---|---|
| `nxf-download` | the dispatcher Lambda, behind the URL |
| `nxf-download-builder` | the packaging Lambda it invokes |
| `nxf-download` (role) | the execution role they share |
| a function URL | on the dispatcher, invokable only by CloudFront |
| an origin and a `/download/*` behavior | on the existing distribution |
| a lifecycle rule | on the zip prefix |

**[Setting up the download URL](downloads-setup.md)** walks through all of it in
the AWS console, with the policies to paste. It is a one-time job of about half
an hour; nothing in it is repeated per run.

Both functions are a single file each, standard library plus the `boto3` already
in the runtime, so changing one afterwards is pasting the new code into the
console and pressing Deploy — no build step and no dependencies.

Two settings there are worth knowing about even if you never touch the rest.
`CachingDisabled` on the behavior, because every answer this address gives is
either a per-request redirect carrying a signature or a progress report seconds
old. And **no CloudFront function on that behavior**: the
[directory-URL function](cloudfront.md) redirects any path with no trailing
slash and no dot — which `/download/3xk9mp2q` is — and would bounce every
download link once before it reached the dispatcher. Attaching functions per
behavior is what keeps the two apart; the function itself needs no change.

## Tuning

Both functions read their settings from the environment, so a change is a
console edit rather than a redeploy:

| Variable | Default | |
|---|---|---|
| `MAX_TOTAL_BYTES` | 100 GB | the run size the builder refuses above |
| `PART_SIZE_BYTES` | 16 MB | grown automatically if 9,000 parts would not cover the run |
| `READ_AHEAD_BYTES` | 128 MB | how far the reader may run ahead of the zip |
| `UPLOAD_THREADS` | 4 | parts uploading at once |
| `DEFLATE_LEVEL` | 1 | for the entries that are compressed at all |
| `URL_TTL_SECONDS` | 3600 | how long a redirect stays good for |
| `BUILD_STALE_SECONDS` | 300 | before a silent build is taken for dead and restarted |

The builder's **reserved concurrency**, set to 5 at
[setup](downloads-setup.md#2-the-builder-function), is the cap on how many runs
can be packaged at once, and so on what this can cost per minute. Its memory —
3008 MB — is bought for the network bandwidth that comes with it rather than for
the footprint, which stays in the hundreds of MB whatever the size of the run.

A run too large for one pass is the case this design does not cover. The
escape hatch is to move the builder to Fargate, which has neither the fifteen
minutes nor the memory ceiling; everything above it, including the dispatcher
and the waiting page, would be unchanged.
