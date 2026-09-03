#
# globus.sh - Where a run's bulky download is written, and how it is addressed.
#
# Author: Daniel Smith
# Date:   September 1st, 2026
#
# Sourced by .env rather than executed.
#
# The one file a requester actually downloads - their reads and the whole
# dashboard, in a single zip - is served from the CMMR-Nextflow guest collection
# rather than from the bucket. It is written straight onto the collection's own
# filesystem, which is on this cluster, so publishing it is a copy rather than
# an upload and there is no egress to pay for either.
#
# One archive rather than two, because two invited the reader to take one and
# believe they had everything. It holds the run directory's own layout -
# raw-sequences/ beside results/ - so unpacking it gives back what the run was
# given and what it produced, side by side.
#
# Every run publishes under one prefix, $GLOBUS_RUN_PREFIX, which carries a
# single anonymous read permission granted once by hand. A run is a directory
# under it, not a permission of its own: HTTPS access to a collection has no
# directory listing, so a run directory named after an unguessable uid cannot be
# found by anyone who was not given its address. See docs/operations/globus.md.
#
#   globus_run_dir      <uid>                    where that run's files are written
#   globus_run_url      <uid> [file]             the address they are served from
#   globus_bundle_name  <uid> <title>            what its archive is called
#   globus_archive      <uid> <zip> <dir[|level]>...
#                                                build that archive
#   globus_archive_add  <uid> <zip> <path>...    add to one already built
#   globus_archive_size <uid> <zip>              how big it came out, in bytes
#   globus_discard_run  <uid>                    delete the directory and all of it
#
# Defines: globus_run_dir, globus_run_url, globus_bundle_name, globus_archive,
#          globus_archive_add, globus_archive_size, globus_discard_run
# Requires: zip
# Env:     GLOBUS_DIR, GLOBUS_RUN_PREFIX, GLOBUS_URL, and the log/warn and
#          is_valid_uid/escape_url helpers from utilities.sh

# Where one run's downloads live on disk. The uid is validated because the value
# is handed to mkdir and to a recursive delete, and an empty one would name the
# whole prefix.
globus_run_dir() {
    if ! is_valid_uid "$1"; then
        warn "\"$1\" is not a uid; it names no Globus directory."
        return 1
    fi

    printf '%s/%s/%s' "${GLOBUS_DIR%/}" "$GLOBUS_RUN_PREFIX" "$1"
}

# The address that directory is served from, or a file in it. "?download" is
# what makes the collection answer with an attachment rather than with the file
# itself, so a click saves it instead of rendering it.
globus_run_url() {
    local uid="$1" file="${2:-}"

    if ! is_valid_uid "$uid"; then
        warn "\"$uid\" is not a uid; it names no Globus address."
        return 1
    fi

    printf '%s/%s/%s' "${GLOBUS_URL%/}" "$GLOBUS_RUN_PREFIX" "$uid"

    [[ -n "$file" ]] && printf '/%s?download' "$(escape_url "$file")"

    return 0
}

# What a run's archive is called. The task's own title leads, so the file is
# recognisable in a downloads folder among everything else a requester has
# taken; the uid follows it, so the run it came from can still be quoted back to
# us months later.
#
# The title is written by a requester and becomes a filename, so it is cut down
# to the characters a filename should carry: runs of anything else become one
# hyphen, and what is left is trimmed and shortened. A title that survives none
# of that leaves the uid to name the file on its own.
globus_bundle_name() {
    local uid="$1" slug

    slug=$(printf '%s' "${2:-}" | LC_ALL=C tr -cs '[:alnum:]' '-')
    slug=${slug#-}
    slug=${slug%-}
    slug=${slug:0:60}
    slug=${slug%-}

    printf '%s%s.zip' "${slug:+${slug}_}" "$uid"
}

# Build a run's archive straight into the collection, out of the directories
# named after it. Straight into it rather than beside the results and moved
# after, because a run's reads are large enough that writing them twice is the
# one part of publishing that would cost anything.
#
# Each directory is given as "<dir>" or "<dir>|<level>", the level being what
# zip is told about that part: "-0" stores rather than deflates, which is what
# to give already-gzipped reads, and the default "-9" is for everything else.
# They are read relative to the working directory and go in under their own
# names, so the archive unpacks into the layout the run directory holds.
#
# zip stores what a symlink points at, so a sample staged as a link is archived
# as real data.
#
# Prints whatever zip had to say about a failure.
globus_archive() {
    local uid="$1" name="$2"
    local dir output part level
    shift 2

    dir=$(globus_run_dir "$uid") || return 1

    if ! output=$(mkdir -p "$dir" 2>&1); then
        printf '%s' "$output"
        return 1
    fi

    # zip adds to an archive it finds, so a half-built one left by an
    # interrupted run would be extended rather than replaced
    rm -f "$dir/$name"

    for part in "$@"; do
        level="-9"
        [[ "$part" == *'|'* ]] && level=${part#*|}
        part=${part%%|*}

        if ! output=$(zip -r -q "$level" "$dir/$name" "$part" 2>&1); then
            printf '%s' "$output"
            return 1
        fi
    done

    # World-readable, because the collection serves these as the anonymous
    # principal rather than as whoever ran the pipeline
    chmod -R a+rX "$dir" 2>/dev/null || true
}

# Add to an archive already built, replacing whatever it holds under those
# names. The dashboard's own three pages go in this way: they say how big the
# download is, which is not known until everything else is in it.
globus_archive_add() {
    local uid="$1" name="$2"
    local dir output
    shift 2

    dir=$(globus_run_dir "$uid") || return 1

    if ! output=$(zip -q -9 "$dir/$name" "$@" 2>&1); then
        printf '%s' "$output"
        return 1
    fi

    chmod a+r "$dir/$name" 2>/dev/null || true
}

# How big that archive came out, in bytes, for the page that offers it to say
# what a reader is about to start
globus_archive_size() {
    local dir

    dir=$(globus_run_dir "$1") || return 1

    stat -c %s "$dir/$2" 2>/dev/null
}

# Delete everything published for a run. Called from the two places a run is
# torn down - its expiration date, and its task going away - so the dashboard
# and the file it linked to go on the same pass.
globus_discard_run() {
    local dir

    dir=$(globus_run_dir "$1") || return 1

    [[ -d "$dir" ]] || return 0

    rm -rf "$dir"
}
