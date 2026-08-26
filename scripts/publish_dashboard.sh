#
# publish_dashboard.sh - Build and upload the landing page a published run is read through.
#
# Author: Daniel Smith
# Date:   August 26th, 2026
#
# Sourced by .env rather than executed. Every pipeline's upload script publishes
# the same page from templates/dashboard.html: a header, the date the results
# are deleted on, one tab per report, and an index of every output file worth
# naming.
#
# An upload script declares what its pipeline produced and then renders:
#
#   dashboard_reset  <results_dir> <catalog>
#   dashboard_view   <id> <label> <path>    once per report the tabs offer
#   dashboard_button <path>                 once per file the header offers
#   render_dashboard <run_id> <task_name> <run_date> <sample_count> <expires>
#
# Each of those skips a file the run did not produce, so the page describes the
# run rather than the pipeline. The first view is the one the page opens on and
# the first button is the emphasised one.
#
# The file index comes from the catalog - templates/<pipeline>/outputs.conf -
# which names paths, globs and folders in the order they should be read, grouped
# under headings.
#
# Defines: dashboard_reset, dashboard_view, dashboard_button, render_dashboard,
#          upload_results_tree, TEXT_EXTENSIONS, DOWNLOAD_EXTENSIONS
# Requires: aws, GNU find; the escape_html/escape_url/human_size/render_template
#           helpers from utilities.sh
# Env:      NEXTFLOW_DIR

# Extensions uploaded as text rather than left for aws to type from the name.
# Without this a browser is handed a table as an application/octet-stream and
# saves it instead of showing it.
TEXT_EXTENSIONS=(txt tsv csv log yaml yml gff fasta fa fna nwk sh)

# Extensions that download when clicked. Everything else opens in a new tab,
# which the content types above are what make possible.
DOWNLOAD_EXTENSIONS=(zip gz bz2 xz tar tgz qza qzv biom rds rda parquet)

DASHBOARD_RESULTS_DIR=""
DASHBOARD_CATALOG=""
DASHBOARD_VIEWS=()
DASHBOARD_BUTTONS=""

dashboard_reset() {
    DASHBOARD_RESULTS_DIR="${1%/}"
    DASHBOARD_CATALOG="$2"
    DASHBOARD_VIEWS=()
    DASHBOARD_BUTTONS=""
}

# True when a path is one a browser should be told to save
dashboard_is_download() {
    local extension="${1##*.}"
    local candidate

    extension="${extension,,}"

    for candidate in "${DOWNLOAD_EXTENSIONS[@]}"; do
        [[ "$extension" == "$candidate" ]] && return 0
    done

    return 1
}

# The attributes a link to one output carries: saved to disk, or opened beside
# the page it was clicked from.
dashboard_link_attributes() {
    if dashboard_is_download "$1"; then
        printf ' download'
    else
        printf ' target="_blank" rel="noopener"'
    fi
}

# One tab, if the run produced the report behind it. The id is the fragment the
# page remembers the open tab as.
dashboard_view() {
    local id="$1" label="$2" path="$3"

    [[ -r "$DASHBOARD_RESULTS_DIR/$path" ]] || return 0

    DASHBOARD_VIEWS+=("$id|$label|$path")
}

# One header button per file matching a glob, labelled with its own filename
dashboard_button() {
    local pattern="$1"
    local path name class

    for path in "$DASHBOARD_RESULTS_DIR"/$pattern; do
        [[ -r "$path" ]] || continue

        name=${path#"$DASHBOARD_RESULTS_DIR/"}
        class="button"
        [[ -z "$DASHBOARD_BUTTONS" ]] && class="button primary"

        DASHBOARD_BUTTONS+="<a class=\"$class\" href=\"$(escape_url "$name")\""
        DASHBOARD_BUTTONS+="$(dashboard_link_attributes "$name")>"
        DASHBOARD_BUTTONS+="$(escape_html "${name##*/}")</a>"
    done
}

# A group heading as its own fragment, e.g. "Start here" -> "start-here"
dashboard_slug() {
    local slug="${1,,}"

    slug=${slug//[^a-z0-9]/-}

    # Collapse and trim the runs of separators that leaves
    while [[ "$slug" == *--* ]]; do
        slug=${slug//--/-}
    done

    printf '%s' "${slug#-}"
}

# The tabs, in the order they were declared, plus the file index every run has
dashboard_tabs() {
    local entry id label path

    for entry in ${DASHBOARD_VIEWS[@]+"${DASHBOARD_VIEWS[@]}"}; do
        id=${entry%%|*}
        label=${entry#*|}
        label=${label%%|*}
        path=${entry##*|}

        printf '<a class="tab" data-view="%s" href="%s" target="viewer">%s</a>' \
            "$id" "$(escape_url "$path")" "$(escape_html "$label")"
    done

    printf '<a class="tab" data-view="files" href="#files">All output files</a>'
}

# The page opens on the first tab declared, and on the file index for a run that
# produced no report at all.
dashboard_first_view() {
    local entry="${DASHBOARD_VIEWS[0]:-}"

    [[ -n "$entry" ]] || return 0

    escape_url "${entry##*|}"
}

# The strip under the header saying when the results are deleted. The date is
# written out here; how far off it is, is worked out in the page itself.
dashboard_expiry() {
    local expires="$1"

    if [[ ! "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        printf '<div class="expiry none">No deletion date is set for these results.'
        printf ' They stay online until you ask us to remove them.</div>'
        return 0
    fi

    printf '<div class="expiry" data-expires="%s"><strong>Save anything you want to keep.</strong>' \
        "$expires"
    printf ' This page and every file it links to are deleted on <span class="date">%s</span>' \
        "$(escape_html "$(date -d "$expires" '+%B %-d, %Y')")"
    printf '<span class="countdown"></span>. To keep them online for longer, ask your CMMR'
    printf ' contact before that date.</div>'
}

dashboard_trim() {
    local s="$1"

    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}

    printf '%s' "$s"
}

# One row of the file index: what it is called, what it holds, and how big it is
dashboard_row() {
    local href="$1" label="$2" description="$3" size="$4" tag="$5"

    printf '<tr><td class="name"><a href="%s"%s>%s</a>' \
        "$(escape_url "$href")" "$(dashboard_link_attributes "$href")" "$(escape_html "$label")"

    [[ -n "$tag" ]] && printf '<span class="tag">%s</span>' "$(escape_html "$tag")"

    printf '<span class="desc">%s</span></td><td class="size">%s</td></tr>\n' \
        "$(escape_html "$description")" "$(escape_html "$size")"
}

# Every row one catalog entry produces. A folder is one row naming its listing
# page; a glob is one row per file it matches, in name order.
dashboard_entry() {
    local path="$1" label="$2" description="$3"
    local full match name count size

    if [[ "$path" == */ ]]; then
        full="$DASHBOARD_RESULTS_DIR/${path%/}"

        [[ -d "$full" ]] || return 0

        # index.html is the listing page itself, which is not one of the outputs
        count=$(find -L "$full" -type f ! -name index.html | wc -l)
        (( count > 0 )) || return 0

        dashboard_row "${path}index.html" "${label:-$path}" "$description" \
            "$count files" "folder"
        return 0
    fi

    # A labelled entry is presented as the thing it names rather than as a file,
    # so its size is left off
    for full in "$DASHBOARD_RESULTS_DIR"/$path; do
        [[ -f "$full" ]] || continue

        name=${full#"$DASHBOARD_RESULTS_DIR/"}
        match="$label"
        size=""

        if [[ -z "$match" ]]; then
            match="$name"
            size=$(human_size "$(stat -c %s "$full")")
        fi

        dashboard_row "$name" "$match" "$description" "$size" ""
    done
}

# One group of the file index, kept only when the run produced something to put
# in it. Appends to the GROUP_NAV and SECTIONS its caller declared.
dashboard_end_group() {
    local group="$1" rows="$2" slug

    [[ -n "$group" && -n "$rows" ]] || return 0

    slug=$(dashboard_slug "$group")

    GROUP_NAV+="<a href=\"#$slug\">$(escape_html "$group")</a>"
    SECTIONS+="<section class=\"group\" id=\"$slug\">"
    SECTIONS+="<h2>$(escape_html "$group")</h2><table><tbody>"
    SECTIONS+="$rows</tbody></table></section>"
}

# The file index, and the menu beside it. Both are built in one pass over the
# catalog, so a group that produced no rows appears in neither.
#
# Reads the catalog into GROUP_NAV and SECTIONS rather than printing, since one
# pass has to produce both.
dashboard_index() {
    local line group path label description
    local current="" group_rows=""

    GROUP_NAV=""
    SECTIONS=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line//$'\r'/}
        line=${line#"${line%%[![:space:]]*}"}

        [[ -z "$line" || "$line" == \#* ]] && continue

        IFS='|' read -r group path label description <<< "$line"

        group=$(dashboard_trim "$group")
        path=$(dashboard_trim "$path")
        label=$(dashboard_trim "$label")
        description=$(dashboard_trim "$description")

        [[ -n "$group" && -n "$path" ]] || continue

        if [[ "$group" != "$current" ]]; then
            dashboard_end_group "$current" "$group_rows"
            current="$group"
            group_rows=""
        fi

        group_rows+=$(dashboard_entry "$path" "$label" "$description")
    done < "$DASHBOARD_CATALOG"

    dashboard_end_group "$current" "$group_rows"
}

# The whole page. Every value substituted into it is either escaped here or
# markup the functions above escaped themselves.
render_dashboard() {
    local run_id="$1" task_name="$2" run_date="$3" sample_count="$4" expires="$5"

    local GROUP_NAV SECTIONS

    if [[ ! -r "$DASHBOARD_CATALOG" ]]; then
        warn "No output catalog at $DASHBOARD_CATALOG; the file index will be empty."
        GROUP_NAV=""
        SECTIONS="<p class=\"empty\">No file index was built for this run.</p>"
    else
        dashboard_index
    fi

    render_template "$NEXTFLOW_DIR/templates/dashboard.html" \
        TASK_NAME    "$(escape_html "$task_name")" \
        RUN_ID       "$run_id" \
        RUN_DATE     "$run_date" \
        SAMPLE_COUNT "$sample_count" \
        EXPIRY       "$(dashboard_expiry "$expires")" \
        BUTTONS      "$DASHBOARD_BUTTONS" \
        TABS         "$(dashboard_tabs)" \
        VIEW_SRC     "$(dashboard_first_view)" \
        GROUP_NAV    "$GROUP_NAV" \
        SECTIONS     "$SECTIONS"
}

# Copy a results folder to its prefix in two passes, so that the tables, logs
# and configuration files a reader clicks open in the browser instead of
# downloading. aws types an object from its name, and only recognises some of
# these; the rest arrive as binary and are saved.
#
# Prints whatever aws had to say about a failure.
upload_results_tree() {
    local src="${1%/}" dest="${2%/}"
    local extension output
    local -a other=() text=(--exclude "*")

    for extension in "${TEXT_EXTENSIONS[@]}"; do
        other+=(--exclude "*.$extension")
        text+=(--include "*.$extension")
    done

    if ! output=$(aws s3 cp "$src/" "$dest/" --recursive "${other[@]}" 2>&1); then
        printf '%s' "$output"
        return 1
    fi

    if ! output=$(aws s3 cp "$src/" "$dest/" --recursive "${text[@]}" \
            --content-type "text/plain; charset=utf-8" 2>&1); then
        printf '%s' "$output"
        return 1
    fi
}
