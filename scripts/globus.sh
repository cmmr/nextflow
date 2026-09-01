#
# globus.sh - Where a run's bulky downloads are written, and how they are addressed.
#
# Author: Daniel Smith
# Date:   September 1st, 2026
#
# Sourced by .env rather than executed.
#
# The two files a requester actually downloads - their reads, and the whole
# dashboard as one zip - are served from the CMMR-Nextflow guest collection
# rather than from the bucket. They are written straight onto the collection's
# own filesystem, which is on this cluster, so publishing them is a copy rather
# than an upload and there is no egress to pay for either.
#
# Every run publishes under one prefix, $GLOBUS_RUN_PREFIX, which carries a
# single anonymous read permission granted once by hand. A run is a directory
# under it, not a permission of its own: HTTPS access to a collection has no
# directory listing, so a run directory named after an unguessable uid cannot be
# found by anyone who was not given its address. See docs/operations/globus.md.
#
#   globus_run_dir <uid>                    where that run's files are written
#   globus_run_url <uid> [file]             the address they are served from
#   globus_archive <uid> <zip> <dir> [-0]   build one of its archives
#   globus_discard_run <uid>                delete the directory and all of it
#
# Defines: globus_run_dir, globus_run_url, globus_archive, globus_discard_run
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

# Build one of a run's archives straight into the collection, from the contents
# of a directory. Straight into it rather than beside the results and moved
# after, because a run's reads are large enough that writing them twice is the
# one part of publishing that would cost anything.
#
# The directory goes in under its own name, so unpacking raw-sequences.zip
# gives a raw-sequences/ folder rather than a few hundred loose FASTQ files.
#
# The last argument is passed to zip, for the archive whose contents are already
# compressed - "-0" stores rather than deflates, which is what to give an
# archive of gzipped reads. zip stores what a symlink points at, so a sample
# staged as a link is archived as real data.
#
# Prints whatever zip had to say about a failure.
globus_archive() {
    local uid="$1" name="$2" source="${3%/}" level="${4:--9}"
    local dir output

    dir=$(globus_run_dir "$uid") || return 1

    if ! output=$(mkdir -p "$dir" 2>&1); then
        printf '%s' "$output"
        return 1
    fi

    # zip adds to an archive it finds, so a half-built one left by an
    # interrupted run would be extended rather than replaced
    rm -f "$dir/$name"

    if ! output=$(cd "$(dirname "$source")" && zip -r -q "$level" "$dir/$name" "$(basename "$source")" 2>&1); then
        printf '%s' "$output"
        return 1
    fi

    # World-readable, because the collection serves these as the anonymous
    # principal rather than as whoever ran the pipeline
    chmod -R a+rX "$dir" 2>/dev/null || true
}

# Delete everything published for a run. Called from the two places a run is
# torn down - its expiration date, and its task going away - so the dashboard
# and the files it linked to go on the same pass.
globus_discard_run() {
    local dir

    dir=$(globus_run_dir "$1") || return 1

    [[ -d "$dir" ]] || return 0

    rm -rf "$dir"
}
