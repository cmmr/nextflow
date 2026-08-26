# CloudFront

The results bucket is served through a CloudFront distribution, which is what
`$AWS_S3_BUCKET` names — `utilities.sh` builds the results URL as
`https://$AWS_S3_BUCKET/$S3_RUN_PREFIX/<uid>/index.html`.


## Viewer Request Function for Directory URLs

S3 stores objects, not directories, so a request for a folder matches nothing on
its own. [`index_directories.sh`](../../scripts/index_directories.sh) writes an
`index.html` into every published folder; this function is the half that makes
those pages reachable by folder URL, and without it every folder link in a
report is a 404.

Attach it to the **viewer request** event of the default behavior — and of that
behavior only. A CloudFront function is configured per cache behavior, and the
`/download/*` behavior that serves
[the whole-run download](downloads.md) must not carry this one: a download
address has no trailing slash and no dot, so rule 1 below would redirect every
one of them once before it reached the function behind it.

It handles the two shapes a folder URL arrives in:

- `/nxf/<uid>/qiime2` — no trailing slash and no extension, so it is taken for a
  directory and answered with a 301 that adds the slash. The redirect is what
  puts the browser on the folder itself, so the relative links inside
  `listing.html` resolve against that folder rather than its parent.
- `/nxf/<uid>/qiime2/` — rewritten internally to `index.html` beneath it. The
  address bar is left alone, since the reader asked for the folder.

```js
function handler(event) {
    var request = event.request;
    var uri = request.uri;
    
    // 1. If it's a directory request missing a trailing slash, send a 301 Redirect.
    // This updates the browser's address bar so relative links work correctly.
    if (!uri.endsWith('/') && !uri.includes('.')) {
        return {
            statusCode: 301,
            statusDescription: 'Moved Permanently',
            headers: {
                'location': { value: uri + '/' }
            }
        };
    }
    
    // 2. If the URI already has a trailing slash, internally rewrite to index.html.
    if (uri.endsWith('/')) {
        request.uri += 'index.html';
    }
    
    return request;
}
```
