#
# publish_dashboard.sh - Build and upload the pages a published run is read through.
#
# Author: Daniel Smith
# Date:   August 26th, 2026
#
# Sourced by .env rather than executed. Every pipeline's upload script publishes
# the same three pages, all built from templates/redesign/code.html:
#
#   index.html     the navigation bar, and a frame the rest of it loads into
#   overview.html  the run itself - what it was, what it found, what to take
#   files.html     the annotated index of everything it published
#
# The bar is the only chrome that survives navigation. Each of its links names a
# whole page: the two above, and the pipeline's own reports as they were
# written.
#
# An upload script declares what its pipeline produced and then publishes:
#
#   dashboard_reset      <results_dir> <catalog>
#   dashboard_view       <id> <label> <path>      once per report the bar offers
#   dashboard_index_view [label]                  where the file index sits in it
#   dashboard_button     <glob>                   once per file the sidebar offers
#   dashboard_link_button <href> <label> [icon]   a link to data held elsewhere,
#                                                 hidden while <href> is empty
#   dashboard_stat_group <heading> [note]         opens a block of the statistics
#   dashboard_stat_row   <label> <value>          a reading with no bar under it
#   dashboard_stat_tiles <value|label|tone> ...   a row of counts
#   dashboard_stat_chips <value|label> ...        the same row, set small
#   dashboard_stat_bar   <label> <reading> <percent> [tone]
#                        tone: growth for a share of the reads that were kept;
#                        a total is left toneless and wears the navy
#   publish_dashboard <s3_dir> <run_id> <task_name> <subtitle> <pipeline> \
#                     <run_date> <sample_count> <expires> [plot_data]
#
# Each of those skips a file the run did not produce, so the pages describe the
# run rather than the pipeline. Overview is always the first link and the one a
# reader lands on; the file index is appended to the bar when the pipeline did
# not say where it goes. Every run also gets a button for the whole of itself as
# one zip.
#
# The file index comes from the catalog - templates/<pipeline>/outputs.conf -
# which names paths, globs and folders in the order they should be read, grouped
# under headings. A folder is listed as one row pointing at the
# directory_listing.html index_directories.sh wrote into it.
#
# Icons are Material Symbols names, from the font the design system loads:
# biotech, database, filter_alt, science, folder_zip, data_object and so on.
#
# Defines: dashboard_reset, dashboard_view, dashboard_index_view,
#          dashboard_button, dashboard_link_button, dashboard_stat_group,
#          dashboard_stat_row, dashboard_stat_tiles, dashboard_stat_chips,
#          dashboard_stat_bar, publish_dashboard, upload_results_tree,
#          TEXT_EXTENSIONS, DOWNLOAD_EXTENSIONS
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

# The two states of a link in the navigation bar, as the design writes them. The
# page's own script swaps between these, so both are spelled the same in both
# places.
readonly DASHBOARD_NAV_ON="text-on-primary border-b-2 border-secondary-fixed font-bold pb-1 px-2 py-1 rounded text-[13px] tracking-[0.02em] hover:bg-primary-container transition-colors"
readonly DASHBOARD_NAV_OFF="text-primary-fixed/80 hover:text-on-primary hover:bg-primary-container transition-colors px-2 py-1 rounded text-[13px] tracking-[0.02em] font-medium"

DASHBOARD_RESULTS_DIR=""
DASHBOARD_CATALOG=""
DASHBOARD_VIEWS=()
DASHBOARD_DOWNLOADS=""
DASHBOARD_STATS=""
DASHBOARD_STAT_GROUP_OPEN=""

dashboard_reset() {
    DASHBOARD_RESULTS_DIR="${1%/}"
    DASHBOARD_CATALOG="$2"
    DASHBOARD_VIEWS=()
    DASHBOARD_DOWNLOADS=""
    DASHBOARD_STATS=""
    DASHBOARD_STAT_GROUP_OPEN=""
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

# The attributes a link to one output carries. Read inside the landing page's
# frame, anything that opens rather than downloads has to open outside it.
dashboard_link_attributes() {
    if dashboard_is_download "$1"; then
        printf ' download'
    else
        printf ' target="_blank" rel="noopener"'
    fi
}

# What a file is, read off its extension, as the icon its row is marked with
dashboard_file_icon() {
    local extension="${1##*.}"

    case "${extension,,}" in
        zip|gz|bz2|xz|tar|tgz)             printf 'folder_zip' ;;
        biom|qza|qzv|rds|rda|parquet|json) printf 'data_object' ;;
        tsv|csv)                           printf 'table_view' ;;
        html|htm|svg|pdf|png)              printf 'monitoring' ;;
        *)                                 printf 'description' ;;
    esac
}

# One link in the navigation bar, if the run produced the page behind it. The id
# is the fragment the bar remembers the open view as.
dashboard_view() {
    local id="$1" label="$2" path="$3"

    [[ -r "$DASHBOARD_RESULTS_DIR/$path" ]] || return 0

    DASHBOARD_VIEWS+=("$id|$label|$path")
}

# Where the file index sits among those links. It is a page this script writes
# rather than one the run produced, so it is declared rather than found.
dashboard_index_view() {
    DASHBOARD_VIEWS+=("files|${1:-File Explorer}|files.html")
}

# How many samples the run covered, as the pill beside the statistics heading -
# the count every other number in that card is a count over
dashboard_sample_pill() {
    local sample_count="$1"
    local noun="samples"

    [[ "$sample_count" =~ ^[0-9]+$ && "$sample_count" -gt 0 ]] || return 0

    (( sample_count == 1 )) && noun="sample"

    printf '<span class="inline-flex items-center gap-1.5 shrink-0 rounded-full border border-outline-variant bg-surface-container px-2.5 py-1 font-label-caps text-label-caps text-on-surface-variant">'
    printf '<span class="material-symbols-outlined text-[14px]">science</span>%s %s</span>' \
        "$sample_count" "$noun"
}

# One quick download per file matching a glob, labelled with its own filename
dashboard_button() {
    local pattern="$1"
    local path name

    for path in "$DASHBOARD_RESULTS_DIR"/$pattern; do
        [[ -r "$path" ]] || continue

        name=${path#"$DASHBOARD_RESULTS_DIR/"}

        DASHBOARD_DOWNLOADS+="<a class=\"flex items-center justify-between gap-2 px-2 py-1.5 rounded hover:bg-surface-container transition-colors group\""
        DASHBOARD_DOWNLOADS+=" href=\"$(escape_url "$name")\"$(dashboard_link_attributes "$name")>"
        DASHBOARD_DOWNLOADS+="<span class=\"flex items-center gap-2 min-w-0\">"
        DASHBOARD_DOWNLOADS+="<span class=\"material-symbols-outlined text-[20px] text-on-surface-variant group-hover:text-primary transition-colors\">"
        DASHBOARD_DOWNLOADS+="$(dashboard_file_icon "$name")</span>"
        DASHBOARD_DOWNLOADS+="<span class=\"text-[13px] leading-5 text-on-surface truncate\">$(escape_html "${name##*/}")</span></span>"
        DASHBOARD_DOWNLOADS+="<span class=\"material-symbols-outlined text-[18px] shrink-0 text-on-surface-variant opacity-0 group-hover:opacity-100 transition-opacity\">"
        DASHBOARD_DOWNLOADS+="file_download</span></a>"
    done
}

# One quick download pointing at a whole address of its own rather than at a file
# in the results folder, for data published somewhere else. An empty address
# leaves the row in the page but hidden, so filling the address in is the whole
# of turning the link on. Hidden inline rather than by class, since the row's
# own "flex" would win over a utility class.
dashboard_link_button() {
    local href="$1" label="$2" icon="${3:-folder_zip}"
    local attributes

    if [[ -n "$href" ]]; then
        attributes=" href=\"$(escape_html "$href")\" target=\"_blank\" rel=\"noopener\""
    else
        attributes=' hidden style="display: none;"'
    fi

    DASHBOARD_DOWNLOADS+="<a class=\"flex items-center justify-between gap-2 px-2 py-1.5 rounded hover:bg-surface-container transition-colors group\""
    DASHBOARD_DOWNLOADS+="$attributes>"
    DASHBOARD_DOWNLOADS+="<span class=\"flex items-center gap-2 min-w-0\">"
    DASHBOARD_DOWNLOADS+="<span class=\"material-symbols-outlined text-[20px] text-on-surface-variant group-hover:text-primary transition-colors\">"
    DASHBOARD_DOWNLOADS+="$(escape_html "$icon")</span>"
    DASHBOARD_DOWNLOADS+="<span class=\"text-[13px] leading-5 text-on-surface truncate\">$(escape_html "$label")</span></span>"
    DASHBOARD_DOWNLOADS+="<span class=\"material-symbols-outlined text-[18px] shrink-0 text-on-surface-variant opacity-0 group-hover:opacity-100 transition-opacity\">"
    DASHBOARD_DOWNLOADS+="open_in_new</span></a>"
}

# The button for the whole run as one zip, which every run has. Its address is
# the only absolute link on the page: the zip is served by a behavior of the
# distribution rather than sitting beside the page, so it is also the one link
# that does not resolve in an unpacked copy.
#
# The landing page catches the click and packages the run behind a modal. The
# href is what everything else follows - a middle-click, a shared link, a reader
# without scripting - and answers with a redirect or the page that waits.
dashboard_zip_button() {
    printf '<a class="w-full bg-primary text-on-primary px-3 py-2 rounded-lg text-[13px] font-semibold hover:bg-primary-container transition-colors flex items-center justify-center gap-2"'
    printf ' id="download-all" href="/download/%s" target="_blank" rel="noopener">' "$(escape_url "$1")"
    printf '<span class="material-symbols-outlined text-[18px]">archive</span>Download everything</a>'
}

# Close whichever block of the statistics is open, so the next heading starts
# its own
dashboard_end_stat_group() {
    if [[ -n "$DASHBOARD_STAT_GROUP_OPEN" ]]; then
        DASHBOARD_STATS+="</div>"
        DASHBOARD_STAT_GROUP_OPEN=""
    fi
}

# One block of the sidebar. The note is the run's own setting for what the
# block reports - the region and instrument over the read totals, the reference
# database over the classification - so a number is read beside what produced
# it.
dashboard_stat_group() {
    local heading="$1" note="${2:-}"

    dashboard_end_stat_group

    DASHBOARD_STATS+="<div><h4 class=\"flex items-baseline justify-between gap-2 font-label-caps text-label-caps text-on-surface-variant mb-2.5\">"
    DASHBOARD_STATS+="<span class=\"shrink-0\">$(escape_html "$heading")</span>"

    if [[ -n "$note" ]]; then
        DASHBOARD_STATS+="<span class=\"min-w-0 truncate text-right text-[11px] font-normal tracking-normal normal-case text-outline\""
        DASHBOARD_STATS+=" title=\"$(escape_html "$note")\">$(escape_html "$note")</span>"
    fi

    DASHBOARD_STATS+="</h4>"
    DASHBOARD_STAT_GROUP_OPEN=1
}

# One reading with no bar under it, for a value that is not a share of anything
dashboard_stat_row() {
    local label="$1" value="$2"

    [[ -n "$value" ]] || return 0

    DASHBOARD_STATS+="<div class=\"flex justify-between items-baseline gap-2 mb-1.5 last:mb-0\">"
    DASHBOARD_STATS+="<span class=\"font-body-sm text-body-sm font-medium text-on-surface shrink-0\">"
    DASHBOARD_STATS+="$(escape_html "$label")</span>"
    DASHBOARD_STATS+="<span class=\"font-body-sm text-body-sm text-on-surface-variant text-right\">"
    DASHBOARD_STATS+="$(escape_html "$value")</span></div>"

    return 0
}

# A row of counts, each declared as value|label|tone. The tone names the accent
# the number is set in - growth for the biological readings, empty for the
# institutional blue - rather than the class it becomes.
dashboard_tiles() {
    local box="$1" size="$2" value_class="$3" label_class="$4"
    local entry value label tone
    shift 4

    DASHBOARD_STATS+="<div class=\"grid grid-cols-$size gap-2\">"

    for entry in "$@"; do
        IFS='|' read -r value label tone <<< "$entry"

        case "$tone" in
            growth)    tone="text-secondary" ;;
            plain)     tone="text-on-surface" ;;
            *)         tone="text-primary" ;;
        esac

        DASHBOARD_STATS+="<div class=\"$box\"><span class=\"$value_class $tone\">"
        DASHBOARD_STATS+="$(escape_html "$value")</span>"
        DASHBOARD_STATS+="<span class=\"$label_class\">$(escape_html "$label")</span></div>"
    done

    DASHBOARD_STATS+='</div>'
}

# The headline counts, two to a row
dashboard_stat_tiles() {
    dashboard_tiles \
        "bg-surface-container p-2.5 rounded-lg border border-outline-variant/30 flex flex-col items-center justify-center text-center" \
        2 "font-headline-lg text-headline-lg leading-7" \
        "font-body-sm text-body-sm text-on-surface-variant" "$@"
}

# The same row set small, for readings that support a headline count rather than
# being one
dashboard_stat_chips() {
    dashboard_tiles \
        "bg-surface-container p-2 rounded-lg border border-outline-variant/30 flex flex-col items-center justify-center text-center" \
        3 "font-bold text-body-md leading-5" \
        "text-[10px] leading-3 font-label-caps text-on-surface-variant" "$@"
}

# One measurement as a labelled bar. The reading is written out for a reader -
# "14.8k", "12.7%" - and the percentage is only how far the bar is filled.
dashboard_stat_bar() {
    local label="$1" reading="$2" percent="$3" tone="${4:-}"

    case "$tone" in
        growth)    tone="bg-bio-growth" ;;
        *)         tone="bg-primary-container" ;;
    esac

    [[ "$percent" =~ ^[0-9]+(\.[0-9]+)?$ ]] || percent=0

    # A share can be given to a decimal, so the ceiling is compared as one
    if awk -v p="$percent" 'BEGIN { exit !(p > 100) }'; then
        percent=100
    fi

    DASHBOARD_STATS+="<div class=\"mb-2.5 last:mb-0\"><div class=\"flex justify-between items-baseline gap-2 mb-1\">"
    DASHBOARD_STATS+="<span class=\"font-body-sm text-body-sm font-medium text-on-surface\">$(escape_html "$label")</span>"
    DASHBOARD_STATS+="<span class=\"font-code-sm text-code-sm text-on-surface-variant\">$(escape_html "$reading")</span></div>"
    DASHBOARD_STATS+="<div class=\"h-1.5 w-full bg-surface-variant rounded-full overflow-hidden\">"
    DASHBOARD_STATS+="<div class=\"h-full $tone rounded-full\" style=\"width: $percent%;\"></div></div></div>"

    return 0
}

# The statistics card, or nothing when the run has neither a setting to name nor
# anything measured to report
dashboard_stats_card() {
    local sample_count="${1:-}"

    dashboard_end_stat_group

    [[ -n "$DASHBOARD_STATS" ]] || return 0

    printf '<div class="bg-surface-container-lowest rounded-xl border border-outline-variant p-padding-card shadow-sm lg:flex-1 lg:min-h-0 lg:overflow-y-auto">'
    printf '<h3 class="text-base font-semibold text-primary mb-4 flex items-center justify-between gap-2">'
    printf '<span class="flex items-center gap-2"><span class="material-symbols-outlined text-[20px]">analytics</span>Run Statistics</span>'
    printf '%s</h3>' "$(dashboard_sample_pill "$sample_count")"
    printf '<div class="flex flex-col gap-5">%s</div></div>' "$DASHBOARD_STATS"
}

# The quick downloads, or a line saying the run named none
dashboard_downloads() {
    if [[ -z "$DASHBOARD_DOWNLOADS" ]]; then
        printf '<p class="font-body-sm text-body-sm text-on-surface-variant p-2">'
        printf 'This run names no single files; take all of it below.</p>'
        return 0
    fi

    printf '%s' "$DASHBOARD_DOWNLOADS"
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

# The navigation bar: Overview, then the views in the order they were declared,
# with the file index appended when the pipeline did not place it.
dashboard_nav() {
    local entry id label path
    local views=(${DASHBOARD_VIEWS[@]+"${DASHBOARD_VIEWS[@]}"})

    printf '<a class="%s" data-view="overview" href="overview.html" target="view">Overview</a>' \
        "$DASHBOARD_NAV_ON"

    if [[ " ${views[*]} " != *"files|"* ]]; then
        views+=("files|File Explorer|files.html")
    fi

    for entry in ${views[@]+"${views[@]}"}; do
        id=${entry%%|*}
        label=${entry#*|}
        label=${label%%|*}
        path=${entry##*|}

        printf '<a class="%s" data-view="%s" href="%s" target="view">%s</a>' \
            "$DASHBOARD_NAV_OFF" "$id" "$(escape_url "$path")" "$(escape_html "$label")"
    done
}

# The note at the end of the navigation bar saying when the results are deleted.
# The date is written out here; how far off it is, is worked out in the page
# itself. What to do about it is left to the tooltip, so the bar stays a
# navigation bar.
dashboard_expiry() {
    local expires="$1"

    if [[ ! "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        printf '<div class="flex items-center gap-2 text-on-surface-variant bg-surface-container px-3 py-1.5 rounded-full border border-outline-variant font-label-caps text-label-caps font-bold"'
        printf ' title="These results stay online until you ask your CMMR contact to remove them.">'
        printf '<span class="material-symbols-outlined text-sm">timer</span>'
        printf '<span>No expiration date</span></div>'
        return 0
    fi

    printf '<div class="flex items-center gap-2 text-warning-amber bg-warning-amber/10 px-3 py-1.5 rounded-full border border-warning-amber/20 font-label-caps text-label-caps font-bold"'
    printf ' data-expires="%s" title="This page and every file it links to are deleted after' "$expires"
    printf ' that date. Save anything you want to keep, or ask your CMMR contact to keep them'
    printf ' online for longer.">'
    printf '<span class="material-symbols-outlined text-sm">timer</span><span>'
    printf '<span class="label">Expires </span><span class="date">%s</span>' \
        "$(escape_html "$(date -d "$expires" '+%b %-d, %Y')")"
    printf '<span class="countdown"></span></span></div>'
}

# What the run was, along the foot of every page: when it finished, which
# pipeline version produced it, and the uid to quote when asking us about it.
# Each is left out rather than written empty.
dashboard_footer_note() {
    local run_date="$1" pipeline="$2" run_id="$3"
    local note=""
    local part

    [[ -n "$run_date" ]] && note="Completed $run_date"

    for part in "$pipeline" "$run_id"; do
        [[ -n "$part" ]] || continue

        note+="${note:+ · }$(escape_html "$part")"
    done

    printf '%s' "$note"
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

        # The listing pages index_directories.sh writes are how the folder is
        # read, not something the run produced
        count=$(find -L "$full" -type f ! -name directory_listing.html | wc -l)
        (( count > 0 )) || return 0

        dashboard_row "${path}directory_listing.html" "${label:-$path}" "$description" \
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

# The plots the overview draws, as the object its script reads. A run that
# computed none says so in JavaScript rather than leaving the page half
# written.
dashboard_plot_data() {
    local file="${1:-}"

    if [[ -z "$file" || ! -s "$file" ]]; then
        printf 'null'
        return 0
    fi

    cat "$file"
}

# The navigation bar, and the frame everything else is read in
render_shell() {
    local run_id="$1" task_name="$2" expires="$3"

    render_template "$NEXTFLOW_DIR/templates/dashboard.html" \
        TASK_NAME  "$(escape_html "$task_name")" \
        NAV        "$(dashboard_nav)" \
        EXPIRY     "$(dashboard_expiry "$expires")" \
        FIRST_VIEW "overview.html"
}

# The run itself: what it was, what it found, and what to take away
render_overview() {
    local run_id="$1" task_name="$2" subtitle="$3" pipeline="$4" run_date="$5"
    local sample_count="$6" plot_data="$7"

    render_template "$NEXTFLOW_DIR/templates/overview.html" \
        TASK_NAME   "$(escape_html "$task_name")" \
        SUBTITLE    "$(escape_html "$subtitle")" \
        PLOT_DATA   "$(dashboard_plot_data "$plot_data")" \
        DOWNLOADS   "$(dashboard_downloads)" \
        ZIP_BUTTON  "$(dashboard_zip_button "$run_id")" \
        STATS       "$(dashboard_stats_card "$sample_count")" \
        YEAR        "$(date '+%Y')" \
        FOOTER_NOTE "$(dashboard_footer_note "$run_date" "$pipeline" "$run_id")"
}

# Everything the run published, annotated
render_files() {
    local run_id="$1" task_name="$2" pipeline="$3" run_date="$4"

    local GROUP_NAV SECTIONS

    if [[ ! -r "$DASHBOARD_CATALOG" ]]; then
        warn "No output catalog at $DASHBOARD_CATALOG; the file index will be empty."
        GROUP_NAV=""
        SECTIONS="<p class=\"empty\">No file index was built for this run.</p>"
    else
        dashboard_index
    fi

    render_template "$NEXTFLOW_DIR/templates/files.html" \
        TASK_NAME   "$(escape_html "$task_name")" \
        GROUP_NAV   "$GROUP_NAV" \
        SECTIONS    "$SECTIONS" \
        YEAR        "$(date '+%Y')" \
        FOOTER_NOTE "$(dashboard_footer_note "$run_date" "$pipeline" "$run_id")"
}

# Render the three pages and upload them to the run's prefix, the landing page
# last so that nothing it frames is still arriving. Prints whatever failed.
#
# subtitle names the analysis the pipeline performed and run_date is already
# written out for a reader; sample_count is a bare number, or empty for a run
# that never recorded one; plot_data is the file ampliseq_composition.sh wrote,
# or empty for a pipeline that draws nothing.
publish_dashboard() {
    local s3_dir="${1%/}" run_id="$2" task_name="$3" subtitle="$4" pipeline="$5"
    local run_date="$6" sample_count="$7" expires="$8" plot_data="${9:-}"

    local name page output

    for name in overview files shell; do
        case "$name" in
            overview) page=$(render_overview "$run_id" "$task_name" "$subtitle" \
                                 "$pipeline" "$run_date" "$sample_count" "$plot_data") ;;
            files)    page=$(render_files "$run_id" "$task_name" "$pipeline" "$run_date") ;;
            shell)    page=$(render_shell "$run_id" "$task_name" "$expires") ;;
        esac

        if [[ -z "$page" ]]; then
            printf 'The %s page could not be built from its template.' "$name"
            return 1
        fi

        [[ "$name" == "shell" ]] && name="index"

        # --content-type because reading the body from stdin leaves aws nothing
        # to guess from, and a page served as binary downloads instead of
        # rendering
        if ! output=$(printf '%s\n' "$page" \
                | aws s3 cp - "$s3_dir/$name.html" --content-type "text/html" 2>&1); then
            printf '%s' "$output"
            return 1
        fi
    done
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
