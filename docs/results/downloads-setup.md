# Setting up the download URL

A one-time walk through the AWS console, start to finish, for the two functions
behind [the whole-run download](downloads.md). Allow about half an hour. Nothing
here needs the AWS CLI, and nothing here is repeated per run — once it is
standing, every uid the system publishes is downloadable.

Read [Downloading a whole run](downloads.md) first if you want to know why it is
shaped this way. This page is only the assembly.

## What you end up with

| | |
|---|---|
| `nxf-download` | a Lambda answering `/download/<uid>` with a redirect or a waiting page |
| `nxf-download-builder` | a Lambda that packages one run, invoked by the first |
| `nxf-download` (role) | the execution role both of them run as |
| a function URL | on the dispatcher, invokable only by CloudFront |
| an origin + behavior | on the existing distribution, routing `/download/*` at that URL |
| a lifecycle rule | on the bucket, expiring the cached zips |

## Before you start

Collect these. Every code block below uses them as placeholders, so keep the
list beside you and substitute as you paste.

| Placeholder | Where to find it | Example |
|---|---|---|
| `ACCOUNT_ID` | top-right account menu in the console | `123456789012` |
| `REGION` | the region the rest of the stack is in | `us-east-1` |
| `BUCKET` | `AWS_S3_BUCKET` in `secrets/.env` | `results.example.org` |
| `DISTRIBUTION_ID` | CloudFront → Distributions | `E1XXXXXXXXXXXX` |
| `RUN_PREFIX` | `S3_RUN_PREFIX` in `.env` | `nxf` |
| `ZIP_PREFIX` | `S3_ZIP_PREFIX` in `.env` | `zip` |

The bucket is the same one the dashboards are already served from, and the
distribution is the same one already in front of it. Nothing here creates a
second of either.

---

## 1. The execution role

Both functions share one role. **IAM → Roles → Create role.**

1. Trusted entity type **AWS service**, use case **Lambda**. Next.
2. Search for and tick **`AWSLambdaBasicExecutionRole`** — this is what lets
   either function write its own CloudWatch log group. Next.
3. Role name **`nxf-download`**. Create role.

Picking the Lambda use case writes the trust policy for you; you do not need to
paste one.

Now the access it actually needs. Open the new role, **Add permissions → Create
inline policy → JSON**, and paste this, substituting `BUCKET`, `RUN_PREFIX`,
`ZIP_PREFIX`, `REGION` and `ACCOUNT_ID`:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ReadPublishedResults",
            "Effect": "Allow",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::BUCKET/RUN_PREFIX/*"
        },
        {
            "Sid": "WriteTheZipCache",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:AbortMultipartUpload"
            ],
            "Resource": "arn:aws:s3:::BUCKET/ZIP_PREFIX/*"
        },
        {
            "Sid": "ListTheRunsBeingPackaged",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:ListBucketMultipartUploads"
            ],
            "Resource": "arn:aws:s3:::BUCKET",
            "Condition": {
                "StringLike": {
                    "s3:prefix": "RUN_PREFIX/*"
                }
            }
        },
        {
            "Sid": "StartABuild",
            "Effect": "Allow",
            "Action": "lambda:InvokeFunction",
            "Resource": "arn:aws:lambda:REGION:ACCOUNT_ID:function:nxf-download-builder"
        }
    ]
}
```

Name it **`nxf-download-access`** and create it.

The role reads the published results and can neither write nor delete them; it
writes only under the zip prefix. That is deliberate — the thing standing in
front of the internet should not be able to damage a client's results.

---

## 2. The builder function

**Lambda → Create function → Author from scratch.**

| Field | Value |
|---|---|
| Function name | `nxf-download-builder` |
| Runtime | Python 3.13 |
| Architecture | x86_64 |
| Execution role | **Use an existing role** → `nxf-download` |

Create function, then:

**The code.** Open the **Code** tab. In the file tree, rename
`lambda_function.py` to `nxf_download_builder.py` (right-click → Rename), then
paste in the whole of
[`lambda/nxf_download_builder.py`](../../lambda/nxf_download_builder.py) and
press **Deploy**. Under **Runtime settings → Edit**, set the handler to:

```
nxf_download_builder.lambda_handler
```

*If renaming gives you trouble, paste the code into `lambda_function.py` and
leave the handler at its default. Nothing depends on the filename — it only
keeps the console and the repository reading the same.*

**Configuration → General configuration → Edit:**

| Field | Value |
|---|---|
| Memory | `3008` MB |
| Timeout | `15` min `0` sec |

The memory is bought for the network bandwidth that comes with it, not for the
footprint — the function holds a few hundred MB whatever the size of the run.

**Configuration → Environment variables → Edit.** Add three:

| Key | Value |
|---|---|
| `AWS_S3_BUCKET` | `BUCKET` |
| `S3_RUN_PREFIX` | `RUN_PREFIX` |
| `S3_ZIP_PREFIX` | `ZIP_PREFIX` |

**Configuration → Concurrency and recursion detection → Edit.** Choose
**Reserve concurrency** and set it to `5`. This is the cap on how many runs can
be packaged at once, and so on what the feature can cost per minute.

**Configuration → Asynchronous invocation → Edit.** Set **Retry attempts** to
`0`. A build that failed will fail the same way again, and the reason has
already been written where the waiting page can read it.

---

## 3. The dispatcher function

Same again, with different numbers. **Lambda → Create function → Author from
scratch.**

| Field | Value |
|---|---|
| Function name | `nxf-download` |
| Runtime | Python 3.13 |
| Architecture | x86_64 |
| Execution role | **Use an existing role** → `nxf-download` |

**The code.** Rename the file to `nxf_download.py`, paste in the whole of
[`lambda/nxf_download.py`](../../lambda/nxf_download.py), **Deploy**, and set
the handler to:

```
nxf_download.lambda_handler
```

**Configuration → General configuration → Edit:**

| Field | Value |
|---|---|
| Memory | `256` MB |
| Timeout | `0` min `15` sec |

**Configuration → Environment variables → Edit.** Four this time — the same
three plus the name of the function it hands builds to:

| Key | Value |
|---|---|
| `AWS_S3_BUCKET` | `BUCKET` |
| `S3_RUN_PREFIX` | `RUN_PREFIX` |
| `S3_ZIP_PREFIX` | `ZIP_PREFIX` |
| `BUILDER_FUNCTION` | `nxf-download-builder` |

Leave concurrency and retries alone; this one answers in milliseconds and is
never invoked asynchronously.

---

## 4. The function URL

Still on `nxf-download`: **Configuration → Function URL → Create function URL.**

| Field | Value |
|---|---|
| Auth type | **NONE** |
| Invoke mode | BUFFERED |

Copy the URL it gives you — `https://xxxxxxxx.lambda-url.REGION.on.aws/`. You
need it in the next step.

**`NONE` is temporary.** It is set that way so you can prove the function works
before CloudFront is involved; [step 7](#7-lock-the-function-url) closes it. Do
not stop before that step.

### Prove it works

Open the function URL with a uid on the end — any run that is currently
published:

```
https://xxxxxxxx.lambda-url.REGION.on.aws/download/3xk9mp2q
```

You should get the *Preparing your download* page, a progress bar that moves,
and a download that starts on its own a minute or two later. If you get
anything else, [work through the table below](#when-it-does-not-work) before
adding CloudFront on top — every problem is easier to see at this layer.

---

## 5. CloudFront: the origin

**CloudFront → Distributions → `DISTRIBUTION_ID` → Origins → Create origin.**

| Field | Value |
|---|---|
| Origin domain | the function URL's host **only** — `xxxxxxxx.lambda-url.REGION.on.aws`, with no `https://` and no trailing slash |
| Protocol | **HTTPS only** |
| Origin access | **Origin access control settings (recommended)** |
| Origin access control | **Create new OAC** → name `nxf-download`, signing behavior **Sign requests**, origin type **Lambda** |

Create the OAC, then create the origin.

CloudFront will show a banner saying the function's permissions must be updated
to allow it. That is [step 7](#7-lock-the-function-url); carry on for now.

---

## 6. CloudFront: the behavior

**Behaviors → Create behavior.**

| Field | Value |
|---|---|
| Path pattern | `/download/*` |
| Origin and origin groups | the origin from step 5 |
| Viewer protocol policy | **Redirect HTTP to HTTPS** |
| Allowed HTTP methods | **GET, HEAD** |
| Restrict viewer access | No |
| Cache policy | **CachingDisabled** |
| Origin request policy | **AllViewerExceptHostHeader** |
| Response headers policy | none |
| Function associations | **none — leave every one of them empty** |

Three of those are load-bearing:

- **`CachingDisabled`**, because every answer this address gives is either a
  per-request redirect carrying a signature or a progress report a few seconds
  old. A cached redirect served to the next reader would be an expired link.
- **`AllViewerExceptHostHeader`**, because a Lambda function URL rejects a
  request arriving with somebody else's `Host` header, which is exactly what
  forwarding the viewer's `Host` would do.
- **No function associations.** The
  [directory-URL viewer request function](cloudfront.md) redirects any path with
  no trailing slash and no dot — `/download/3xk9mp2q` is one — so attaching it
  here bounces every download link once before it ever reaches the dispatcher.
  A CloudFront function is attached per behavior, so leaving this box empty is
  the whole of what keeps the two apart. The function itself needs no change.

Behaviors are matched in order and `Default (*)` is always last, so a new
behavior automatically takes precedence over it. Nothing to reorder.

Wait for the distribution to finish deploying before testing.

---

## 7. Lock the function URL

Two halves, and the order matters — set the auth type first, then grant
CloudFront the exception.

**In Lambda, on `nxf-download`: Configuration → Function URL → Edit.** Change
auth type to **AWS_IAM**. Save. The URL is now closed to everybody, CloudFront
included.

**Then Configuration → Permissions → Resource-based policy statements → Add
permissions → AWS service.**

| Field | Value |
|---|---|
| Service | **CloudFront** |
| Statement ID | `AllowCloudFront` |
| Principal | `cloudfront.amazonaws.com` |
| Source ARN | `arn:aws:cloudfront::ACCOUNT_ID:distribution/DISTRIBUTION_ID` |
| Action | `lambda:InvokeFunctionUrl` |

That builds this, which is what you should see afterwards under **Resource-based
policy statements**:

```json
{
    "Sid": "AllowCloudFront",
    "Effect": "Allow",
    "Principal": {
        "Service": "cloudfront.amazonaws.com"
    },
    "Action": "lambda:InvokeFunctionUrl",
    "Resource": "arn:aws:lambda:REGION:ACCOUNT_ID:function:nxf-download",
    "Condition": {
        "StringEquals": {
            "AWS:SourceArn": "arn:aws:cloudfront::ACCOUNT_ID:distribution/DISTRIBUTION_ID"
        }
    }
}
```

The `SourceArn` condition is the point of the exercise: without it any
CloudFront distribution in the world could call this function.

Confirm the lock by opening the raw `lambda-url` address again — it should now
answer `403 Forbidden`, while the address on your own domain keeps working.

---

## 8. The lifecycle rule

**S3 → `BUCKET` → Management → Create lifecycle rule.**

| Field | Value |
|---|---|
| Rule name | `expire-download-zips` |
| Rule scope | **Limit the scope using one or more filters** |
| Prefix | `ZIP_PREFIX/` — with the trailing slash |

Tick two actions:

| Action | Value |
|---|---|
| Expire current versions of objects | `3` days after object creation |
| Delete expired object delete markers or incomplete multipart uploads | **Delete incomplete multipart uploads**, `1` day |

The first keeps a cache from accumulating for runs nobody asks about twice. The
second collects a build that died between its last part and its completion —
those parts are billed as storage but are invisible in the object listing, so
without this rule they are never noticed and never go.

**Check the prefix before you save.** A rule saved with an empty prefix expires
the whole bucket in three days.

This rule is a backstop, not the mechanism: a zip is normally deleted with its
results by `wrike_expiration.sh` or `wrike_delete_handler.sh`. See
[Expiring a dashboard](../operations/expiration.md).

---

## 9. Check the finished thing

Pick a currently published run and open its address on your own domain:

```
https://BUCKET/download/3xk9mp2q
```

The first request builds; a second one, once the zip is cached, should redirect
immediately:

```bash
curl -sI https://BUCKET/download/3xk9mp2q | head -5
```

A finished build answers `HTTP/2 302` with a `location:` pointing at
`s3.amazonaws.com` and a `filename=` naming the run. While a build is running it
answers `200` with the waiting page instead.

Three more worth trying, since they are what a mistyped link looks like:

| Address | Expected |
|---|---|
| `/download/notauid` | `404`, "that is not a results address" |
| `/download/aaaaaaaa` | `404`, "nothing is published for" |
| `/download/` | `404`, not a build |

---

## Changing a function afterwards

Paste the new code over the old in the **Code** tab and press **Deploy**. There
is no build step and no dependency to install — both functions are a single file
using only the standard library and the `boto3` that is already in the runtime.

Everything tunable is an environment variable rather than a constant, so most
adjustments are a **Configuration → Environment variables** edit and no code
change at all. The full list is in
[Tuning](downloads.md#tuning).

## When it does not work

| What you see | Where to look |
|---|---|
| `403` from your own domain | Step 7. Either the resource-based policy is missing, or its `SourceArn` names a different distribution |
| An extra redirect, or the dashboard's 301 behavior, on a download link | Step 6. A viewer request function is attached to `/download/*`; remove it |
| `502 Bad Gateway` | The dispatcher raised. CloudWatch → `/aws/lambda/nxf-download` |
| The waiting page never moves | The dispatcher could not invoke the builder. Check `StartABuild` in the role policy names the right function and region, then read the dispatcher's log |
| "Nothing is published for" a uid that plainly is | `S3_RUN_PREFIX` on the dispatcher does not match the prefix the results are under |
| The download starts, then `AccessDenied` from S3 | The role is missing `s3:GetObject` on the zip prefix, or the presigned link was left sitting for over an hour |
| The progress bar fills, then the page reloads to an error | The build failed for a real reason. The sentence on that page is the one the builder recorded; the full error is in `/aws/lambda/nxf-download-builder` |
| Everything works from the `lambda-url` address but not from yours | The distribution had not finished deploying, or the behavior's path pattern is not `/download/*` |
