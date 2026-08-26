"""
nxf_download.py - Answer a request for one run's results as a single zip.

Author: Daniel Smith
Date:   August 26th, 2026

Behind https://$AWS_S3_BUCKET/download/<uid>, which is a CloudFront behavior
pointed at this function's Lambda function URL. Three answers:

  the zip is built     302 to a presigned S3 URL for it
  it is being built    a page that waits, polling ?status
  it is not            nxf_download_builder is invoked, then the same page

None of the results pass through here. The zip is served by S3 itself, so
neither Lambda's response size limit nor its streaming bandwidth cap applies.

?status answers the same three cases as JSON, for that page to poll.

Env: AWS_S3_BUCKET, S3_RUN_PREFIX, S3_ZIP_PREFIX, BUILDER_FUNCTION,
     URL_TTL_SECONDS, BUILD_STALE_SECONDS
"""

import json
import os
import re
import time
from urllib.parse import parse_qs

import boto3
from botocore.exceptions import ClientError

s3 = boto3.client("s3")
awslambda = boto3.client("lambda")

BUCKET = os.environ["AWS_S3_BUCKET"]
RUN_PREFIX = os.environ.get("S3_RUN_PREFIX", "nxf").strip("/")
ZIP_PREFIX = os.environ.get("S3_ZIP_PREFIX", "zip").strip("/")
BUILDER_FUNCTION = os.environ["BUILDER_FUNCTION"]

# How long a redirect to the zip stays good for. The reader follows it at once.
URL_TTL_SECONDS = int(os.environ.get("URL_TTL_SECONDS", "3600"))

# How long a build may go without touching its progress file before it is taken
# for dead and started again. The builder writes every couple of seconds.
BUILD_STALE_SECONDS = int(os.environ.get("BUILD_STALE_SECONDS", "300"))

# The uid is the last segment, under whatever path the behavior is mounted at.
# A segment ahead of it is required: "download" is itself eight letters a uid
# could be spelled with, so /download/ would otherwise read as a run id.
ROUTE = re.compile(r"^(?:/[^/]+)+/([a-z2-7]{8})/?$")

PALETTE = """
:root {
  color-scheme: light dark;
  --bg: #ffffff; --panel: #f4f6f8; --border: #d7dde3; --text: #1b2733;
  --muted: #5c6b7a; --accent: #1f6feb; --accent-text: #ffffff; --track: #e3e8ed;
  --alert-bg: #fdeceb; --alert-border: #e3a6a1; --alert-text: #8a2018;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #12171d; --panel: #1a2129; --border: #2c3742; --text: #e6edf3;
    --muted: #9aa7b4; --accent: #3b82f6; --accent-text: #ffffff; --track: #263039;
    --alert-bg: #351a19; --alert-border: #7d3730; --alert-text: #f7bdb6;
  }
}
html, body { height: 100%; }
body {
  margin: 0; display: flex; flex-direction: column;
  background: var(--bg); color: var(--text);
  font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
        Helvetica, Arial, sans-serif;
}
code, .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
a { color: var(--accent); }
header {
  flex: 0 0 auto; display: flex; flex-wrap: wrap; align-items: center;
  justify-content: space-between; gap: 12px 24px; padding: 14px 22px;
  background: var(--panel); border-bottom: 1px solid var(--border);
}
header h1 { margin: 0; font-size: 17px; font-weight: 600; overflow-wrap: anywhere; }
main { flex: 1 1 auto; padding: 30px 22px; max-width: 620px; }
main h2 { margin: 0 0 8px; font-size: 20px; font-weight: 600; }
main p { margin: 0 0 14px; }
.muted { color: var(--muted); }
.track {
  height: 8px; margin: 22px 0 10px; border-radius: 4px;
  background: var(--track); overflow: hidden;
}
.track .bar {
  width: 0; height: 100%; border-radius: 4px;
  background: var(--accent); transition: width 0.4s ease;
}
.status { font-size: 13.5px; color: var(--muted); font-variant-numeric: tabular-nums; }
.alert {
  padding: 11px 14px; border: 1px solid var(--alert-border); border-radius: 6px;
  background: var(--alert-bg); color: var(--alert-text); font-size: 14px;
}
"""

POLL_SCRIPT = """
(function () {
  var bar = document.getElementById("bar");
  var status = document.getElementById("status");
  var misses = 0;

  function human(n) {
    var unit = ["B", "KB", "MB", "GB", "TB"], i = 0;
    while (n >= 1024 && i < 4) { n /= 1024; i++; }
    return (i === 0 ? n : n.toFixed(1)) + " " + unit[i];
  }

  function poll() {
    fetch("?status", { cache: "no-store" })
      .then(function (r) { return r.json(); })
      .then(function (s) {
        misses = 0;

        if (s.state === "ready") {
          status.textContent = "Starting the download...";
          location.href = s.url;
          return;
        }

        // The failure is explained by the page this address serves once the
        // builder has recorded it
        if (s.state === "failed") { location.reload(); return; }

        if (s.bytes_total) {
          var pct = Math.min(100, Math.round(s.bytes_done / s.bytes_total * 100));
          bar.style.width = pct + "%";
          status.textContent = human(s.bytes_done) + " of " + human(s.bytes_total)
            + " packaged, " + s.files_done + " of " + s.files_total + " files";
        }

        setTimeout(poll, 2000);
      })
      .catch(function () {
        if (++misses < 12) { setTimeout(poll, 5000); }
        else { status.textContent = "Lost contact while packaging. Reload to try again."; }
      });
  }

  poll();
})();
"""


def zip_key(uid):
    return f"{ZIP_PREFIX}/{uid}.zip"


def state_key(uid):
    return f"{ZIP_PREFIX}/{uid}.json"


def dashboard_key(uid):
    return f"{RUN_PREFIX}/{uid}/index.html"


def head(key):
    """The object's metadata, or None where there is no such object."""
    try:
        return s3.head_object(Bucket=BUCKET, Key=key)
    except ClientError:
        return None


def read_state(uid):
    """The builder's progress file, or None if it has not written one."""
    try:
        body = s3.get_object(Bucket=BUCKET, Key=state_key(uid))["Body"].read()
        return json.loads(body)
    except (ClientError, ValueError):
        return None


def is_fresh(state):
    return time.time() - state.get("updated", 0) < BUILD_STALE_SECONDS


def presigned_url(uid, metadata):
    """A link straight to the zip, named for the run rather than for its uid."""
    folder = (metadata or {}).get("folder", uid)

    return s3.generate_presigned_url(
        "get_object",
        Params={
            "Bucket": BUCKET,
            "Key": zip_key(uid),
            "ResponseContentDisposition": 'attachment; filename="' + folder + '.zip"',
            "ResponseContentType": "application/zip",
        },
        ExpiresIn=URL_TTL_SECONDS,
    )


def start_build(uid):
    """Claim the build, then hand it to the builder function."""
    s3.put_object(
        Bucket=BUCKET,
        Key=state_key(uid),
        Body=json.dumps({"state": "building", "updated": time.time()}).encode(),
        ContentType="application/json",
        CacheControl="no-store",
    )

    awslambda.invoke(
        FunctionName=BUILDER_FUNCTION,
        InvocationType="Event",
        Payload=json.dumps({"uid": uid}).encode(),
    )


def render(status, title, body, extra_head=""):
    html = (
        "<!doctype html>\n"
        '<html lang="en">\n'
        "<head>\n"
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f"<title>{title}</title>{extra_head}\n"
        f"<style>{PALETTE}</style>\n"
        "</head>\n"
        "<body>\n"
        "<header><div><h1>Download results</h1></div></header>\n"
        f"<main>{body}</main>\n"
        "</body>\n"
        "</html>\n"
    )

    return {
        "statusCode": status,
        "headers": {"content-type": "text/html; charset=utf-8", "cache-control": "no-store"},
        "body": html,
    }


def as_json(payload):
    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json", "cache-control": "no-store"},
        "body": json.dumps(payload),
    }


def redirect(url):
    return {
        "statusCode": 302,
        "headers": {"location": url, "cache-control": "no-store"},
        "body": "",
    }


def unknown_run(uid):
    return render(
        404,
        "No such results",
        f"<h2>Nothing is published for <code>{uid}</code></h2>"
        '<p class="muted">These results were either never published, or have passed'
        " their expiration date and been deleted. Ask your CMMR contact if you need"
        " them back.</p>",
    )


def failed_page(uid, error):
    return render(
        500,
        "Download unavailable",
        "<h2>These results could not be packaged</h2>"
        f'<p class="alert">{error}</p>'
        '<p class="muted">You can still download the files one at a time from the'
        f' <a href="/{RUN_PREFIX}/{uid}/index.html">results page</a>. Tell your CMMR'
        " contact if you need the whole set.</p>",
    )


def waiting_page():
    """The page a reader watches the build from; it polls ?status beside it."""
    return render(
        200,
        "Preparing your download",
        "<h2>Preparing your download</h2>"
        '<p class="muted">Every file on this dashboard is being packaged into one'
        " zip. A large run takes a few minutes. The download starts on its own when"
        " it is ready - leave this page open.</p>"
        '<div class="track"><div class="bar" id="bar"></div></div>'
        '<p class="status" id="status">Listing the files...</p>'
        f"<script>{POLL_SCRIPT}</script>",
        extra_head='\n<noscript><meta http-equiv="refresh" content="20"></noscript>',
    )


def status_for(uid):
    """What the waiting page polls: ready with a link, still building, or failed."""
    built = head(zip_key(uid))

    if built:
        return as_json({"state": "ready", "url": presigned_url(uid, built.get("Metadata"))})

    return as_json(read_state(uid) or {"state": "building"})


def download_for(uid):
    built = head(zip_key(uid))

    if built:
        return redirect(presigned_url(uid, built.get("Metadata")))

    if not head(dashboard_key(uid)):
        return unknown_run(uid)

    state = read_state(uid)

    if state and is_fresh(state):
        if state.get("state") == "failed":
            return failed_page(uid, state.get("error", "The packaging job did not finish."))

        return waiting_page()

    start_build(uid)

    return waiting_page()


def lambda_handler(event, context):
    route = ROUTE.match(event.get("rawPath", ""))

    if not route:
        return render(
            404,
            "No such results",
            "<h2>That is not a results address</h2>"
            '<p class="muted">A download link ends in the eight-character run id'
            " shown on the results page.</p>",
        )

    uid = route.group(1)

    # keep_blank_values, or the valueless ?status the waiting page polls with is
    # dropped before it can be seen
    if "status" in parse_qs(event.get("rawQueryString", ""), keep_blank_values=True):
        return status_for(uid)

    return download_for(uid)
