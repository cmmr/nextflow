# Globus

Where the bulky download of every run is served from, and the tool for handing
someone a dataset directly. Files already on the cluster are shared straight out
of BCM's Globus Connect Server endpoint (`bcmdtn2`, mapped collection
`BCMDTN2-POSIX`) through a guest collection, `CMMR-Nextflow` — no upload, no
egress, and at the cluster's own bandwidth.

Both pipelines publish here: a run's one archive goes into
`$GLOBUS_DIR/nxf/<uid>/`, and [the results page](../results/index.md) links to
it. Everything else about a run still publishes to S3.

`globus-cli` is what does this from the command line. It is a pure-Python
package with no compiled release, so it is installed into its own venv rather
than as a system package — the same pattern `$NEXTFLOW_DIR/bin` already holds
[`nextflow` and `lbzip2`](cluster-requirements.md) under, and for the same
reason: nothing here needs root, and nothing installed this way can collide
with whatever Python the rest of the cluster is running.

## Installing it

```bash
python3 -m venv /data/prod/nextflow/opt/globus-cli
```

```bash
/data/prod/nextflow/opt/globus-cli/bin/pip install --upgrade pip globus-cli
```

```bash
ln -s /data/prod/nextflow/opt/globus-cli/bin/globus /data/prod/nextflow/bin/globus
```

The symlink is what `cluster-requirements.md`'s two other entries do too:
`bin/globus` is invoked by that path rather than added to `PATH`, so a script
that shells out to it never depends on whoever is logged in having set
anything up. For interactive use, add `$NEXTFLOW_DIR/bin` to your own shell's
`PATH` — the venv's `bin/` is deliberately not what gets linked from, since
activating it would also put its private copy of `pip` ahead of the system
one.

Check it landed:

```bash
bin/globus version
```

Not `--version` — that option doesn't exist here (`version` is a subcommand,
`--help` will list the rest).

### The Python 3.9 ceiling

`python3 -m venv` on the login node builds the venv against whatever
`python3` resolves to, which on this cluster is 3.9. globus-cli 3.42.0
(2026-02) started requiring Python ≥3.10, so a venv built this way sticks
at **3.41.0** — the last release that still supports 3.9 — and `bin/globus
update` fails outright rather than silently doing nothing:

```
ERROR: Ignored the following versions that require a different python
version: 3.42.0 Requires-Python >=3.10; 3.43.0 Requires-Python >=3.10
```

3.41.0 is current enough for everything this page uses. If a later feature is
ever needed, rebuild the venv against a newer interpreter first — `module
avail python` or the cluster's `miniconda3` are the likely sources of one —
rather than fighting `pip` into installing a version it has correctly refused.

## Logging in

```bash
bin/globus login
```

Run over SSH with no local browser, this prints a URL to open on any machine
plus a code to paste back, rather than trying to launch one on the login node.
Log in as the identity you administer collections under (`whoami` after
confirms which):

```bash
bin/globus whoami
```

## The pipeline needs no Globus credentials

Nothing in the pipeline shells out to `globus`. It writes files into
`$GLOBUS_DIR` as an ordinary Unix user and the collection serves them, so there
is no token for a run to hold and nothing to expire in the middle of one. The
`globus login` above is for the commands on this page — granting the permission,
listing it, retiring it — which are run by hand.

That is a deliberate consequence of the one-permission scheme below. Under a
grant per run the pipeline would have to authenticate to Globus Auth on every
publish and every tear-down, which would mean either a cached refresh token in
one person's home directory or a confidential client registered for the
purpose, and a run failing on an expired credential having produced its results.
As it stands, the only thing that can break the downloads is the `/nxf/` grant
being removed, which is visible in one command.

## What the pipeline publishes here

Every run writes **one** file into the collection and links to it from its
dashboard:

| | |
|---|---|
| `$GLOBUS_DIR/nxf/<uid>/<task title>_<uid>.zip` | the reads the run was given beside the whole `results/` folder, the three pages it is read through included |

It is laid out the way the run directory itself is — `raw-sequences/` beside
`results/` — so unpacking it gives back what the run was handed and what it
produced, side by side, and the dashboard inside it browses the reads the same
way it browses everything else.

One file rather than the two this used to be. Two downloads let a requester take
one of them, see nothing else obviously outstanding, and believe their data was
safe; there is now nothing to take but the whole thing. The reads are still
*named* on the dashboard — a greyed row in the file index, and a greyed listing
of every file and its size behind it — so the page says what is in the download
without offering files the bucket does not hold.

The name is the Wrike task's own title, cut down to what a filename should carry
and capped at 60 characters, then the uid. The title is what makes the file
recognisable in a downloads folder among everything else a requester has taken;
the uid is what lets them quote the run back to us months later.
`globus_bundle_name` builds it.

It is served as `$GLOBUS_URL/nxf/<uid>/<file>?download`, which is what the
Overview's **Download everything** button fetches. `?download` is what makes the
collection answer with an attachment rather than with the file itself. The same
address without it is what `wget` or `curl` in a shell somewhere else takes.

It is written straight onto the collection's own filesystem — which is on this
cluster — so publishing it is a `zip` into place rather than an upload, and
nothing about it costs S3 storage or egress. It is also the thing most likely to
be fetched whole and least likely to be read through a browser, which is why it
lives here rather than in the bucket. The analysis itself still publishes to S3,
where the dashboard is served from.

The reads go in stored (`zip -0`), being already gzipped, and the results
deflated; `globus_archive` takes each part with the level to give it. The
dashboard's own three pages go in last, through `globus_archive_add`, because
they say how big the archive is and that is not known until the rest of it is in
there.

[`scripts/globus.sh`](../../scripts/globus.sh) is the whole of the mechanism:
`globus_run_dir`, `globus_run_url`, `globus_bundle_name`, `globus_archive`,
`globus_archive_add`, `globus_archive_size` and `globus_discard_run`, sourced by
`.env` and called from each pipeline's upload script. The three values it reads
— `GLOBUS_DIR`, `GLOBUS_RUN_PREFIX` and `GLOBUS_URL` — are set in
[`.env`](../configuration.md), and `GLOBUS_UUID` beside them is for the commands
on this page rather than for the pipeline, which never shells out to `globus`.

`globus_discard_run` is called from both places a run is torn down —
[`wrike_expiration.sh`](expiration.md) when its date arrives, and
`wrike_delete_handler.sh` when its task goes away — so the archive goes on the
same pass as the dashboard that linked to it.

## One permission, every run

**A run is a directory under `/nxf/`, not a permission of its own.** One
anonymous read grant on `/nxf/` covers all of them:

```bash
globus endpoint permission create "$GLOBUS_UUID:/nxf/" --anonymous --permissions r
```

That is granted once, by hand, and nothing in the pipeline creates, lists or
deletes permissions. The alternative — a grant per run, created at publish time
and revoked at expiration — buys nothing, because what keeps one requester out
of another's files is not the permission:

1. **HTTPS access to a Globus collection has no directory listing, at all.**
   Nobody can browse from `/nxf/` to enumerate the run directories under it —
   there is no "list files" HTTPS endpoint to ask. A per-run grant would not
   hide anything a shared one exposes.
2. **Each run directory is named with its uid**, the eight base32 characters
   [`derive_uid`](../conventions.md) works out by HMAC from the Wrike task ID.
   Knowing one uid tells you nothing about any other, and knowing a task ID is
   not enough to compute where its results are.

It also sidesteps a cap and a failure mode. [A guest collection holds at most
1,000 permissions](https://docs.globus.org/api/transfer/permissions/), which a
grant per run would reach; and a permission left behind by a tear-down that
failed part way through would leave a stale grant nothing cleans up. With one
grant there is nothing per run to get out of step — deleting the directory is
the whole of retiring a run's downloads.

The collection's own `Visible To` setting is a third, unrelated thing: it
controls whether *the collection itself* — `CMMR-Nextflow` as a whole — is
listed when someone browses BCM's collections. It says nothing about what is
inside it.

## Setting that permission up

`CMMR-Nextflow` (`906ce447-a02f-4b41-a7f2-6237c243cb8a`) already exists, and
the grant below is already in place. This is what to repeat if the collection
is ever rebuilt, or if `GLOBUS_RUN_PREFIX` is ever changed to something other
than `nxf`.

**Prerequisite, one time:** `collection show` and other GCS-level management
calls need a separate consent from your base login, scoped to the specific
GCS endpoint:

```bash
bin/globus login --gcs cb94237b-af5f-41fa-b161-bd4289338137
```

**1. Find where `CMMR-Nextflow` is rooted on disk.** This is what `GLOBUS_DIR`
in `.env` is set to:

```bash
bin/globus collection show 906ce447-a02f-4b41-a7f2-6237c243cb8a
```

**2. Make the prefix the runs go under:**

```bash
mkdir -p "$GLOBUS_DIR/nxf"
```

**3. Grant anonymous read scoped to it:**

```bash
bin/globus endpoint permission create "$GLOBUS_UUID:/nxf/" --anonymous --permissions r
```

The trailing `/` matters — it is what scopes the grant to that subtree rather
than to the single path entry.

**4. Check it took.** The grant shows up as `r`, shared with `fallback`, on
`/nxf/`:

```bash
bin/globus endpoint permission list "$GLOBUS_UUID"
```

```
Rule ID                              | Permissions | Shared With      | Path
------------------------------------ | ----------- | ---------------- | -----
80678c22-a576-11f1-8def-02ce27bde401 | r           | fallback         | /nxf/
b6c4edf9-a557-11f1-a946-0ee7ef9370d9 | rw          | dpsmith@bcm.edu  | /
```

Removing it again is by rule ID, and takes every run's downloads offline at
once:

```bash
bin/globus endpoint permission delete "$GLOBUS_UUID" "80678c22-a576-11f1-8def-02ce27bde401"
```

## Sharing something else by direct link

The same collection is the tool for handing someone a dataset that never went
through a pipeline — a folder already on the cluster, a re-delivery, anything
with no dashboard behind it. Put it in a directory of its own under a name
nobody could guess, and grant anonymous read on that directory the same way:

```bash
mkdir "$GLOBUS_DIR/<token>"
```

```bash
bin/globus endpoint permission create "$GLOBUS_UUID:/<token>/" --anonymous --permissions r
```

```
https://g-8d60ea.bd9c6d.eb38.data.globus.org/<token>/<filename>?download
```

Not under `/nxf/`: that prefix is the pipeline's, and `wrike_expiration.sh`
deletes directories under it by uid. A hand-made share sitting there would be
safe by accident rather than by design.

**`--anonymous` is one shared "no login" principal, not a per-recipient
credential.** Nothing above stops anyone who *already has* a link from handing
it on — there is no authentication step behind it to catch that. Treat each
link the way you would treat a bearer token: fine to hand out, not something to
publish somewhere it could be indexed or forwarded past the intended recipient.

**There is no download count.** Anonymous HTTPS access is not a Transfer task,
so it never appears in `globus task list` or the web app's Activity tab — those
only cover real endpoint-to-endpoint transfers. The requests are logged, but
server-side, in `globus_access_log` on `bcmdtn2` itself, which means reading it
means asking whoever administers that GCS install. If knowing whether a link
was used ever actually matters, that is the only place it is written down.

## When it does not work

| What you see | Where to look |
|---|---|
| `globus: command not found` | `$NEXTFLOW_DIR/bin` isn't on your `PATH` — use `bin/globus` or add it |
| `Error: No such option: --version` | use `bin/globus version`, not `--version` |
| `globus update` fails with `Requires-Python >=3.10` | [the Python 3.9 ceiling](#the-python-39-ceiling) — the venv needs rebuilding against a newer interpreter, not a retry |
| `MissingLoginError: Missing 'manage_collections' consent` | run `bin/globus login --gcs cb94237b-af5f-41fa-b161-bd4289338137` once — a GCS-level call needs its own consent beyond the base `login` |
| `endpoint permission create --anonymous` is rejected | anonymous/HTTPS access may not be enabled on the `BCMDTN2-POSIX` storage gateway itself — that's a BCM GCS-admin setting, not something a guest-collection admin can turn on |
| the direct link redirects to a login page instead of downloading | the anonymous grant on `/nxf/` is gone, or the path in the URL falls outside the subtree it was scoped to — check `endpoint permission list` |
| a dashboard's downloads 404 | the run's directory under `$GLOBUS_DIR/nxf/` is missing; a run torn down by `wrike_expiration.sh` has had it deleted on purpose |
