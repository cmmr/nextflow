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
#   dashboard_reset      <results_dir> <catalog> [run_url]
#                                                 run_url being where the
#                                                 archives it published to
#                                                 Globus are served from
#   dashboard_view       <id> <label> <path>      once per report the bar offers
#   dashboard_index_view [label]                  where the file index sits in it
#   dashboard_button     <glob> [label]           once per file the sidebar
#                                                 offers, under its own name
#                                                 unless the label says
#                                                 otherwise; false when the glob
#                                                 named nothing
#   dashboard_link_button <href> <label> [icon]   a link to data held elsewhere,
#                                                 hidden while <href> is empty
#   dashboard_bundle     <label> <url>            one of the archives the run
#                                                 publishes to Globus: a quick
#                                                 download of its own, and part
#                                                 of "Download everything"
#   dashboard_stat_group <heading> [note]         opens a block of the statistics
#   dashboard_stat_row   <label> <value>          a reading with no bar under it
#   dashboard_stat_tiles <value|label|tone> ...   a row of counts
#   dashboard_stat_chips <value|label> ...        the same row, set small
#   dashboard_stat_bar   <label> <reading> <percent> [tone] [details]
#                        tone: growth for a share of the reads that were kept;
#                        a total is left toneless and wears the navy
#                        details: the group of dashboard_stat_detail bars this
#                        bar's "details" link shows and hides
#   dashboard_stat_detail <group> <label> <reading> <percent> [href]
#                        one step behind a bar's "details" link, hidden until
#                        the reader asks for it; href makes the label a link to
#                        where the pipeline's own report accounts for that step
#   dashboard_report_section <report> <href> <anchors>
#                        the address of a section of a published report, for
#                        that href, or nothing when it carries no such section
#   render_dashboard  <run_id> <task_name> <subtitle> <pipeline> \
#                     <run_date> <sample_count> <expires> [plot_data]
#   publish_results   <s3_dir>
#
# Each of those skips a file the run did not produce, so the pages describe the
# run rather than the pipeline. Overview is always the first link and the one a
# reader lands on; the file index is appended to the bar when the pipeline did
# not say where it goes. "Download everything" takes whatever bundles the run
# declared, and a run that declared none has no such button.
#
# render_dashboard writes the three pages into the results folder rather than
# straight to S3, so the zip a run publishes to Globus holds the same dashboard
# the bucket serves: unpack it, open the index.html in it, and every link still
# resolves.
# publish_results then uploads the folder, landing the pages last so that
# nothing they frame is still arriving.
#
# The file index comes from the catalog - templates/<pipeline>/outputs.conf -
# which names paths, globs and folders in the order they should be read, grouped
# under headings. A folder is listed as one row pointing at the
# directory_listing.html index_directories.sh wrote into it. A path that is an
# absolute address instead is written as one row leading there, which is how the
# archives served from Globus are listed among the files they hold.
#
# Icons are Material Symbols names, from the font the design system loads:
# biotech, database, filter_alt, science, folder_zip, data_object and so on.
#
# Defines: dashboard_reset, dashboard_view, dashboard_index_view,
#          dashboard_button, dashboard_link_button, dashboard_bundle,
#          dashboard_stat_group, dashboard_stat_row, dashboard_stat_tiles,
#          dashboard_stat_chips, dashboard_stat_bar, dashboard_stat_detail,
#          dashboard_report_section, render_dashboard,
#          publish_results, DASHBOARD_PAGES, TEXT_EXTENSIONS,
#          DOWNLOAD_EXTENSIONS
# Requires: aws, GNU find; the escape_html/escape_url/human_size/render_template
#           helpers from utilities.sh
# Env:      NEXTFLOW_DIR

# Extensions uploaded as text rather than left for aws to type from the name.
# Without this a browser is handed a table as an application/octet-stream and
# saves it instead of showing it.
TEXT_EXTENSIONS=(txt tsv csv log yaml yml gff fasta fa fna nwk newick sh)

# Extensions that download when clicked. Everything else opens in a new tab,
# which the content types above are what make possible.
DOWNLOAD_EXTENSIONS=(zip gz bz2 xz tar tgz qza qzv biom rds rda parquet)

# The two states of a link in the navigation bar, as the design writes them. The
# page's own script swaps between these, so both are spelled the same in both
# places.
readonly DASHBOARD_NAV_ON="text-on-primary border-b-2 border-secondary-fixed font-bold pb-1 px-2 py-1 rounded text-[13px] tracking-[0.02em] hover:bg-primary-container transition-colors"
readonly DASHBOARD_NAV_OFF="text-primary-fixed/80 hover:text-on-primary hover:bg-primary-container transition-colors px-2 py-1 rounded text-[13px] tracking-[0.02em] font-medium"

# The three pages this script writes into the results folder. Named here because
# the upload sends them last, after everything they frame.
readonly DASHBOARD_PAGES=(overview.html files.html index.html)

DASHBOARD_RESULTS_DIR=""
DASHBOARD_CATALOG=""
DASHBOARD_VIEWS=()
DASHBOARD_DOWNLOADS=""
DASHBOARD_STATS=""
DASHBOARD_STAT_GROUP_OPEN=""

# The archives this run published to Globus, as "<label>|<url>" - the two
# downloads "Download everything" starts, and a quick download each
DASHBOARD_BUNDLES=()

# Where this run's archives are served from, which is what a catalog entry
# beginning __RUN_URL__ is read against. Empty for a run that published none,
# which leaves those entries naming nothing and so out of the index.
DASHBOARD_RUN_URL=""

dashboard_reset() {
    DASHBOARD_RESULTS_DIR="${1%/}"
    DASHBOARD_CATALOG="$2"
    DASHBOARD_RUN_URL="${3:-}"
    DASHBOARD_VIEWS=()
    DASHBOARD_DOWNLOADS=""
    DASHBOARD_STATS=""
    DASHBOARD_STAT_GROUP_OPEN=""
    DASHBOARD_BUNDLES=()
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

    [[ -n "$path" && -f "$DASHBOARD_RESULTS_DIR/$path" ]] || return 0

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

# One quick download per file matching a glob. A file whose name is the name of
# the thing is offered under it; anything a pipeline names after the tool, the
# database and the format it came out of is offered under the label instead,
# since that string is what the file index is for. A label given for a glob
# matching several files is used for each of them, so a label belongs to a glob
# that names one.
dashboard_button() {
    local pattern="$1" label="${2:-}"
    local path name text
    local offered=1

    for path in "$DASHBOARD_RESULTS_DIR"/$pattern; do
        [[ -r "$path" ]] || continue

        name=${path#"$DASHBOARD_RESULTS_DIR/"}
        text=${label:-${name##*/}}

        DASHBOARD_DOWNLOADS+="<a class=\"flex items-center justify-between gap-2 px-2 py-1.5 rounded hover:bg-surface-container transition-colors group\""
        DASHBOARD_DOWNLOADS+=" href=\"$(escape_url "$name")\"$(dashboard_link_attributes "$name")>"
        DASHBOARD_DOWNLOADS+="<span class=\"flex items-center gap-2 min-w-0\">"
        DASHBOARD_DOWNLOADS+="<span class=\"material-symbols-outlined text-[20px] text-on-surface-variant group-hover:text-primary transition-colors\">"
        DASHBOARD_DOWNLOADS+="$(dashboard_file_icon "$name")</span>"
        DASHBOARD_DOWNLOADS+="<span class=\"text-[13px] leading-5 text-on-surface truncate\""
        DASHBOARD_DOWNLOADS+=" title=\"$(escape_html "$name")\">$(escape_html "$text")</span></span>"
        DASHBOARD_DOWNLOADS+="<span class=\"material-symbols-outlined text-[18px] shrink-0 text-on-surface-variant opacity-0 group-hover:opacity-100 transition-opacity\">"
        DASHBOARD_DOWNLOADS+="file_download</span></a>"
        offered=0
    done

    # Whether the glob named anything, so a caller can offer a second choice for
    # the run that produced neither
    return $offered
}

# One quick download pointing at a whole address of its own rather than at a file
# in the results folder, for data published somewhere else. An empty address
# leaves the row in the page but hidden, so filling the address in is the whole
# of turning the link on. Hidden inline rather than by class, since the row's
# own "flex" would win over a utility class.
#
# An address the collection answers as an attachment - anything ending in
# "?download" - is left to download in place; anything else opens outside the
# frame the page is read in.
dashboard_link_button() {
    local href="$1" label="$2" icon="${3:-folder_zip}"
    local attributes trailing="open_in_new"

    if [[ -n "$href" ]]; then
        attributes=" href=\"$(escape_html "$href")\""

        if [[ "$href" == *"?download" ]]; then
            trailing="file_download"
        else
            attributes+=" target=\"_blank\" rel=\"noopener\""
        fi
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
    DASHBOARD_DOWNLOADS+="$trailing</span></a>"
}

# One archive the run published to the guest collection: the reads it was given,
# and the whole of this dashboard. Each is a quick download of its own and one
# of the files "Download everything" starts, so the button and the rows beside
# it cannot come to name different things.
dashboard_bundle() {
    local label="$1" url="$2"

    [[ -n "$url" ]] || return 0

    DASHBOARD_BUNDLES+=("$label|$url")
    dashboard_link_button "$url" "$label"
}

# The button for everything the run published as archives, or nothing at all
# when it published none. Its addresses are the only absolute links on the page:
# the archives are served from the guest collection rather than sitting beside
# the page, so they are also the links that do not resolve in an unpacked copy.
#
# The href is the first of them, which is what everything that cannot run a
# script follows - a middle-click, a shared link, a reader without scripting.
# The rest are carried in data-download, and the page's own script starts them
# one after another.
dashboard_zip_button() {
    local entry url first="" rest=""

    for entry in ${DASHBOARD_BUNDLES[@]+"${DASHBOARD_BUNDLES[@]}"}; do
        url=${entry#*|}

        if [[ -z "$first" ]]; then
            first="$url"
        else
            rest+="${rest:+ }$url"
        fi
    done

    [[ -n "$first" ]] || return 0

    printf '<a class="w-full bg-primary text-on-primary px-3 py-2 rounded-lg text-[13px] font-semibold hover:bg-primary-container transition-colors flex items-center justify-center gap-2"'
    printf ' id="download-all" href="%s"' "$(escape_html "$first")"

    [[ -n "$rest" ]] && printf ' data-download="%s"' "$(escape_html "$rest")"

    printf '><span class="material-symbols-outlined text-[18px]">archive</span>Download everything</a>'
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

# How far a bar is filled, as a percentage a style rule can take
dashboard_bar_fill() {
    local percent="$1"

    [[ "$percent" =~ ^[0-9]+(\.[0-9]+)?$ ]] || percent=0

    # A share can be given to a decimal, so the ceiling is compared as one
    if awk -v p="$percent" 'BEGIN { exit !(p > 100) }'; then
        percent=100
    fi

    printf '%s' "$percent"
}

# One measurement as a labelled bar. The reading is written out for a reader -
# "14.8k", "12.7%" - and the percentage is only how far the bar is filled.
#
# Naming a group of detail bars puts a "details" link beside the label, which
# shows and hides them. The link is written hidden and the page's script reveals
# it, so a reader without scripting is not offered a control that does nothing.
dashboard_stat_bar() {
    local label="$1" reading="$2" percent="$3" tone="${4:-}" details="${5:-}"

    case "$tone" in
        growth)    tone="bg-bio-growth" ;;
        *)         tone="bg-primary-container" ;;
    esac

    percent=$(dashboard_bar_fill "$percent")

    DASHBOARD_STATS+="<div class=\"mb-2.5 last:mb-0\"><div class=\"flex justify-between items-baseline gap-2 mb-1\">"
    DASHBOARD_STATS+="<span class=\"font-body-sm text-body-sm font-medium text-on-surface\">$(escape_html "$label")"

    if [[ -n "$details" ]]; then
        DASHBOARD_STATS+="<button type=\"button\" data-stat-details=\"$(escape_html "$details")\""
        DASHBOARD_STATS+=" aria-expanded=\"false\" style=\"display: none\""
        DASHBOARD_STATS+=" class=\"ml-1.5 font-body-sm text-body-sm font-normal text-primary underline"
        DASHBOARD_STATS+=" decoration-dotted underline-offset-2 hover:no-underline\">details</button>"
    fi

    DASHBOARD_STATS+="</span>"
    DASHBOARD_STATS+="<span class=\"font-code-sm text-code-sm text-on-surface-variant\">$(escape_html "$reading")</span></div>"
    DASHBOARD_STATS+="<div class=\"h-1.5 w-full bg-surface-variant rounded-full overflow-hidden\">"
    DASHBOARD_STATS+="<div class=\"h-full $tone rounded-full\" style=\"width: $percent%;\"></div></div></div>"

    return 0
}

# One step behind a bar's "details" link. Set smaller and indented under the
# reading it breaks down, since these support that number rather than being one
# of the run's own headline counts.
#
# A step that the pipeline's own report accounts for somewhere carries the
# address of that section, and its label is the link there. The report is one of
# the dashboard's own views rather than a file to take away, so this opens in
# the frame the reader is already in and the navigation bar follows it there -
# unlike the file index, whose links are to files and open in a tab of their
# own.
dashboard_stat_detail() {
    local group="$1" label="$2" reading="$3" percent="$4" href="${5:-}"
    local style="font-body-sm text-[11px] leading-4 text-on-surface-variant"
    local open="<span class=\"$style\">" close="</span>"

    percent=$(dashboard_bar_fill "$percent")

    #    The address carries a fragment, which escape_url would encode away, and
    #    it is built from a fixed path and an anchor the report itself declared
    style+=" underline decoration-dotted underline-offset-2"
    style+=" hover:text-on-surface hover:decoration-solid"

    if [[ -n "$href" ]]; then
        open="<a class=\"$style\" href=\"$(escape_html "$href")\">"
        close="</a>"
    fi

    DASHBOARD_STATS+="<div class=\"mb-2 last:mb-0 pl-3 border-l-2 border-outline-variant/40\""
    DASHBOARD_STATS+=" data-stat-detail=\"$(escape_html "$group")\" style=\"display: none\">"
    DASHBOARD_STATS+="<div class=\"flex justify-between items-baseline gap-2 mb-1\">"
    DASHBOARD_STATS+="$open$(escape_html "$label")$close"
    DASHBOARD_STATS+="<span class=\"font-code-sm text-code-sm text-outline shrink-0\">"
    DASHBOARD_STATS+="$(escape_html "$reading")</span></div>"
    DASHBOARD_STATS+="<div class=\"h-1 w-full bg-surface-variant rounded-full overflow-hidden\">"
    DASHBOARD_STATS+="<div class=\"h-full bg-primary-container/60 rounded-full\" style=\"width: $percent%;\"></div>"
    DASHBOARD_STATS+="</div></div>"

    return 0
}

# The address of a section of a report the run published, named as the anchors
# that could carry it, most specific first. Both reports this system publishes
# give their sections stable ids - pandoc slugifies a heading into one, MultiQC
# names a section after the tool that wrote it - so an anchor follows what a
# section is rather than where it fell, and the numbering that shifts when a run
# skips a step does not come into it.
#
# A section a report does not have is not linked to at all: the anchors are
# checked against the report this run actually produced, and nothing is printed
# when it carries none of them, which leaves the label as plain text rather than
# a link that lands nowhere.
dashboard_report_section() {
    local report="$1" href="$2" anchor

    [[ -r "$report" ]] || return 0

    for anchor in $3; do
        if grep -qF "id=\"$anchor\"" "$report"; then
            printf '%s#%s' "$href" "$anchor"
            return 0
        fi
    done
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

# One row of the file index: what it is called, what it holds, and how big it is.
# An href that is already a whole address is written as it stands - it was built
# here, not read off a disk - and always downloads, since the only such rows are
# the archives the collection serves as attachments.
dashboard_row() {
    local href="$1" label="$2" description="$3" size="$4" tag="$5"
    local link attributes

    if [[ "$href" == http://* || "$href" == https://* ]]; then
        link="$href"
        attributes=""
    else
        link="$(escape_url "$href")"
        attributes="$(dashboard_link_attributes "$href")"
    fi

    printf '<tr><td class="name"><a href="%s"%s>%s</a>' \
        "$link" "$attributes" "$(escape_html "$label")"

    [[ -n "$tag" ]] && printf '<span class="tag">%s</span>' "$(escape_html "$tag")"

    printf '<span class="desc">%s</span></td><td class="size">%s</td></tr>\n' \
        "$(escape_html "$description")" "$(escape_html "$size")"
}

# Every row one catalog entry produces. A folder is one row naming its listing
# page; a glob is one row per file it matches, in name order; an absolute address
# is one row leading there, for an archive published to the guest collection
# rather than into the results folder.
dashboard_entry() {
    local path="$1" label="$2" description="$3"
    local full match name count size

    if [[ "$path" == http://* || "$path" == https://* ]]; then
        dashboard_row "$path" "${label:-${path##*/}}" "$description" "" ""
        return 0
    fi

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

        # The listing pages are how a folder is read, not something the run
        # produced, so a glob over a folder's web pages does not catch them
        [[ "${name##*/}" == directory_listing.html ]] && continue

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

        # An entry for something served from the guest collection rather than
        # published into the results folder
        path=${path//__RUN_URL__/$DASHBOARD_RUN_URL}

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
        ZIP_BUTTON  "$(dashboard_zip_button)" \
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

# Write the three pages into the results folder, from what the run produced and
# what the upload script declared. Prints whatever failed.
#
# Into the folder rather than straight to the bucket, because the zip published
# to the guest collection is made from this folder: a reader who unpacks it gets
# the same dashboard, and the pages the bucket serves are the same bytes rather
# than a second rendering of them.
#
# subtitle names the analysis the pipeline performed and run_date is already
# written out for a reader; sample_count is a bare number, or empty for a run
# that never recorded one; plot_data is the file the composition script wrote,
# or empty for a pipeline that draws nothing.
render_dashboard() {
    local run_id="$1" task_name="$2" subtitle="$3" pipeline="$4"
    local run_date="$5" sample_count="$6" expires="$7" plot_data="${8:-}"

    local name page

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

        if ! printf '%s\n' "$page" > "$DASHBOARD_RESULTS_DIR/$name.html"; then
            printf 'The %s page could not be written into %s.' "$name" "$DASHBOARD_RESULTS_DIR"
            return 1
        fi
    done
}

# Copy the results folder to its prefix, then the three pages on top of it.
#
# The copy runs in two passes, so that the tables, logs and configuration files
# a reader clicks open in the browser instead of downloading: aws types an
# object from its name and only recognises some of these, and the rest arrive as
# binary and are saved.
#
# The pages go last and on their own, so that nothing they frame is still
# arriving when a reader is handed them - index.html overwrites the progress
# page nextflow_progress.sh published to the same key, which is how someone
# watching the run is handed the report.
#
# Prints whatever aws had to say about a failure.
publish_results() {
    local dest="${1%/}"
    local src="$DASHBOARD_RESULTS_DIR"
    local extension page output
    local -a other=() text=(--exclude "*")

    for extension in "${TEXT_EXTENSIONS[@]}"; do
        other+=(--exclude "*.$extension")
        text+=(--include "*.$extension")
    done

    # After the includes, which is what lets an exclude overrule one
    for page in "${DASHBOARD_PAGES[@]}"; do
        other+=(--exclude "$page")
        text+=(--exclude "$page")
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

    # index.html is last in DASHBOARD_PAGES, so the page that frames the other
    # two is the last object of the run to land
    for page in "${DASHBOARD_PAGES[@]}"; do
        [[ -f "$src/$page" ]] || continue

        if ! output=$(aws s3 cp "$src/$page" "$dest/$page" \
                --content-type "text/html" 2>&1); then
            printf '%s' "$output"
            return 1
        fi
    done
}
