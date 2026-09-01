# CloudFront

The results bucket is served through a CloudFront distribution, which is what
`$AWS_S3_BUCKET` names — `utilities.sh` builds the results URL as
`https://$AWS_S3_BUCKET/$S3_RUN_PREFIX/<uid>/index.html`.

One CloudFront **function** sits in front of it, on the viewer request event of
the default behavior. Without it every folder link in a published report is a
404, because S3 stores objects and a request for a folder matches none of them.

## Two filenames, two meanings

Everything the function does follows from this. Across a published run these two
names never collide, and neither is ever the other:

| | |
|---|---|
| `index.html` | a page something wrote to be read — the run's [landing page](index.md) at the top of a run, QIIME 2's barplot under `qiime2/barplot/` |
| `directory_listing.html` | the listing of the folder it sits in, written into **every** directory of the results tree by [`index_directories.sh`](browsable-folders.md) |

So the function has one decision to make: a request for a folder is either the
top of a run, which means the dashboard, or it is any other folder, which means
that folder's listing.

Every link this system writes names the file outright — a folder row in a
listing points at `subfolder/directory_listing.html`, not at `subfolder/`. The
function is for the links it does *not* write: the folder links inside
nf-core's own report, and a reader editing the address bar. Naming the file is
also what lets an unpacked copy of [`dashboard.zip`](../operations/globus.md)
browse the same way the published run does, with no server involved at all.

## The function

```js
function handler(event) {
    var request = event.request;
    var uri = request.uri;

    // 1. A folder URL missing its trailing slash. Answer with a 301 that adds
    //    one, so the browser ends up on the folder itself and the relative
    //    links inside the page it gets resolve against that folder rather than
    //    against its parent.
    if (!uri.endsWith('/') && !uri.includes('.')) {
        return {
            statusCode: 301,
            statusDescription: 'Moved Permanently',
            headers: {
                'location': { value: uri + '/' }
            }
        };
    }

    // 2. A folder URL. The top of a run is its dashboard; every folder below
    //    one is the listing written into it. Rewritten internally, so the
    //    address bar keeps saying what the reader asked for.
    if (uri.endsWith('/')) {
        request.uri += isRunRoot(uri) ? 'index.html' : 'directory_listing.html';
    }

    return request;
}

// "/nxf/<uid>/" and nothing deeper. Splitting that on "/" gives four fields,
// the last of them empty, and a uid is eight characters. RUN_PREFIX below has
// to match S3_RUN_PREFIX in .env.
function isRunRoot(uri) {
    var RUN_PREFIX = 'nxf';
    var parts = uri.split('/');

    return parts.length === 4 && parts[1] === RUN_PREFIX && parts[2].length === 8;
}
```

Worked through, for a run published at `/nxf/vg7dyqwv/`:

| Request | Answer |
|---|---|
| `/nxf/vg7dyqwv/index.html` | the dashboard, untouched — this is the address on the Wrike task |
| `/nxf/vg7dyqwv/` | the dashboard, rewritten to `index.html` |
| `/nxf/vg7dyqwv` | 301 to `/nxf/vg7dyqwv/`, then as above |
| `/nxf/vg7dyqwv/qiime2/` | `qiime2/directory_listing.html` |
| `/nxf/vg7dyqwv/qiime2` | 301, then as above |
| `/nxf/vg7dyqwv/qiime2/barplot/index.html` | QIIME 2's barplot, untouched |
| `/nxf/vg7dyqwv/summary_report/summary_report.html` | untouched |

**The one address the function cannot get right** is `/nxf/<uid>/`, because two
readers mean two different things by it: someone trimming a results link wants
the dashboard, and ampliseq's report — which writes "the base results folder" as
`href="../"` — wants the file listing. The dashboard wins, since that is the
address a person types. `ampliseq_upload.sh` repoints that one link at
`../directory_listing.html` before the upload, so the report reaches the listing
by name.

## Setting it up

**CloudFront → Functions → Create function.** Name it `nxf-directory-index`,
runtime **cloudfront-js-2.0**.

1. Paste the code above into **Build**, substituting `RUN_PREFIX` if
   `S3_RUN_PREFIX` in `.env` is not `nxf`. **Save changes.**
2. **Publish** tab → **Publish function**. An unpublished function cannot be
   associated with anything.
3. **Associate** tab → **Add association**:

    | | |
    |---|---|
    | Distribution | the one in front of the results bucket |
    | Event type | **Viewer request** |
    | Cache behavior | **Default (\*)** |

**Associate it with the default behavior only.** A CloudFront function is
configured per cache behavior. If you add behaviors later, this function belongs
on the behavior that serves published results, and on no other — an address with
no trailing slash and no dot would otherwise be redirected once by rule 1 before
it reached whatever the new behavior points at.

## Checking it

Against any published run:

```bash
curl -sI https://$AWS_S3_BUCKET/nxf/<uid>/qiime2 | head -3
```

Expect `301` and a `location:` ending in `qiime2/`. Then:

```bash
curl -s https://$AWS_S3_BUCKET/nxf/<uid>/qiime2/ | grep -o '<title>[^<]*'
```

Expect `<title>qiime2` — the listing names the folder it describes. The run root
should answer with the task name instead:

```bash
curl -s https://$AWS_S3_BUCKET/nxf/<uid>/ | grep -o '<title>[^<]*'
```
