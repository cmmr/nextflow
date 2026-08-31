# Globus

An alternative to [the results page](../results/index.md) for handing someone a
dataset directly: rather than publishing to S3 behind a dashboard, a file or
directory already on the cluster is shared straight from BCM's Globus Connect
Server endpoint (`bcmdtn2`, mapped collection `BCMDTN2-POSIX`) as its own guest
collection. Nothing here is invoked by a pipeline — it is an admin tool, run by
hand, for the case a dashboard doesn't fit: sharing something that never went
through `publish_dashboard.sh`, or a dataset with no expiration date in mind.

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

## How the pipeline authenticates

### Currently: `dpsmith`'s own login

The pipeline does not have its own Globus identity yet. It runs as `dpsmith`
and relies on the refresh token `bin/globus login` cached in that account's
`~/.globus/` — the same login used interactively above, not a separate
credential set up for automation. This works and is what's running today, with
three things worth knowing about it as a stopgap rather than a destination:

- Every share the pipeline creates is attributed to `dpsmith`, not to the
  pipeline — there's no way to tell, from a collection's `Original Owner`,
  whether a human or the automation made it.
- It only keeps working as long as *someone* logs in as `dpsmith` at least
  once every six months — the refresh token's inactivity limit — and as long
  as `dpsmith`'s account exists at all.
- It has to run under `dpsmith`'s Unix account specifically, since the cached
  token lives in that account's home directory.

### Recommended: migrate to a service identity

The intended mechanism for a script is a **confidential client**: a Globus
Auth service identity (a client ID and secret) that represents the pipeline
itself, the same way `bcmdtn2`'s own `Original Owner` —
`cb94237b-af5f-41fa-b161-bd4289338137@clients.auth.globus.org` — is a service
identity for the endpoint rather than a person. `globus-cli` picks one up from
two environment variables and skips `login` entirely when both are set:

```bash
export GLOBUS_CLI_CLIENT_ID=<client-id>
export GLOBUS_CLI_CLIENT_SECRET=<client-secret>
```

Register the client at `app.globus.org/settings/developers`, then store the
two values in [`secrets/.env`](../configuration.md) alongside
`WRIKE_API_TOKEN` — credentials only, never committed, sourced by `.env`
before anything else runs.

A fresh client isn't automatically allowed to create guest collections or set
permissions under `BCMDTN2-POSIX` just because it has valid credentials — the
storage gateway has to recognize it first (mapped to a local user, or granted
a role on the mapped collection), the same way any identity has to be before
it can act there. That's a change on the endpoint side, so it's a request to
whoever administers `bcmdtn2` for BCM, and it's the blocker on doing this
migration today rather than a technical one on the pipeline's side.

Not yet done — tracked as follow-up work, not a problem with the current
setup.

## Sharing something by direct link only

A guest collection has two settings that matter here, and they're
independent: whether it's **discoverable** (listed when someone browses
BCM's collections) and whether it's **anonymous** (downloadable with no
Globus login at all). A share that's public-by-link only wants the collection
private and the permission anonymous — the opposite pairing from
`CMMR-Nextflow`, which is `Visible To: Public`.

**1. Find the mapped collection's UUID.** Guest collections are created as a
child of `BCMDTN2-POSIX`, not of `bcmdtn2` itself. If you don't have that UUID
memorized, read it off any existing guest collection you administer:

```bash
bin/globus collection show 906ce447-a02f-4b41-a7f2-6237c243cb8a
```

(`906ce447-a02f-4b41-a7f2-6237c243cb8a` is `CMMR-Nextflow` — swap in whichever
collection you can see.) The `mapped_collection_id` field in the output is
what the next step wants.

**2. Create the new collection as private:**

```bash
bin/globus collection create guest <MAPPED_COLLECTION_ID> /path/on/posix/share "Share name" --private
```

Note the ID it returns (`<NEW_ID>` below).

**3. Grant anonymous read on it:**

```bash
bin/globus endpoint permission create <NEW_ID>:/ --anonymous --permissions r
```

Scope the path narrower than `/` to expose only a subfolder of what you gave
step 2.

**4. Get the URL:**

```bash
bin/globus collection show <NEW_ID>
```

The `domain` field is a subdomain of `data.globus.org`, one per guest
collection (`CMMR-Nextflow`'s is `g-8d60ea.bd9c6d.eb38.data.globus.org`). The
direct link is `https://<that domain>/<path-to-file>?download`.

**This is a permanent, unauthenticated link the moment step 3 succeeds** —
anyone who has it can download indefinitely, with no record of who did, until
the permission is revoked (`bin/globus endpoint permission delete`) or the
collection is deleted. Treat handing it out the same as you would publishing
to S3 with no expiration date: worth a second thought for anything that
isn't meant to be public forever.

## When it does not work

| What you see | Where to look |
|---|---|
| `globus: command not found` | `$NEXTFLOW_DIR/bin` isn't on your `PATH` — use `bin/globus` or add it |
| `Error: No such option: --version` | use `bin/globus version`, not `--version` |
| `globus update` fails with `Requires-Python >=3.10` | [the Python 3.9 ceiling](#the-python-39-ceiling) — the venv needs rebuilding against a newer interpreter, not a retry |
| `endpoint permission create --anonymous` is rejected | anonymous/HTTPS access may not be enabled on the `BCMDTN2-POSIX` storage gateway itself — that's a BCM GCS-admin setting, not something a guest-collection admin can turn on |
| the direct link redirects to a login page instead of downloading | step 3 didn't take, or the path in the URL falls outside what step 3 scoped the permission to |
