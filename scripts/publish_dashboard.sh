#
# publish_dashboard.sh - Build and upload the pages a published run is read through.
#
# Author: Daniel Smith
# Date:   August 26th, 2026
#
# Sourced by .env rather than executed. Every pipeline's upload script publishes
# the same three pages, all built from templates/redesign/code.html, and a fourth
# for a pipeline that declares methods data:
#
#   index.html         the navigation bar, and a frame the rest of it loads into
#   overview.html      the run itself - what it was, what it found, what to take
#   deliverables.html  the annotated index of its final outputs
#   methods.html       a paragraph for a manuscript saying how the results were
#                      made, and the references it cites
#
# The bar is the only chrome that survives navigation. Each of its links names a
# whole page, and every pipeline's bar reads the same:
#
#   Overview       overview.html
#   Deliverables   deliverables.html
#   ...            the links the upload script declared, in that order
#   QC Report      multiqc/multiqc_report.html, when the run wrote one
#   File Explorer  directory_listing.html, the results folder's listing
#
# An upload script declares what its pipeline produced and then publishes:
#
#   dashboard_reset      <results_dir> <catalog>
#   dashboard_view       <id> <label> <path>      once per link the pipeline
#                                                 adds to the bar
#   dashboard_methods_view <data> [label]         the Methods page's link,
#                                                 rendered from the data a
#                                                 methods script wrote; nothing
#                                                 when that file is missing
#   dashboard_tab        <id> <label>             opens a tab of the Feature
#                                                 Table card; the buttons,
#                                                 formats, folders and stat
#                                                 groups declared after it are
#                                                 drawn in that tab, and a tab
#                                                 left empty is not drawn
#   dashboard_tab_end                             closes it, sending stat groups
#                                                 back to the statistics card
#   dashboard_button     <glob> [label]           once per file the sidebar
#                                                 offers, under its own name
#                                                 unless the label says
#                                                 otherwise; false when the glob
#                                                 named nothing
#   dashboard_formats    <heading> <[title|]label|path> ...
#                                                 one file offered in several
#                                                 formats, as a row of boxes
#                                                 under one heading, or under
#                                                 none for an empty heading; a
#                                                 format the run did not write is
#                                                 left out, and a heading whose
#                                                 formats are all missing is
#                                                 not drawn
#   dashboard_folder     <folder/> [label]        a link to a folder's listing;
#                                                 false when the run has no such
#                                                 folder
#   dashboard_bundle     <url> [bytes] [folder...] the one archive the run
#                                                 publishes to Globus, which is
#                                                 what "Download everything"
#                                                 takes and how big it says it
#                                                 is; the folders zipped into
#                                                 it are drawn as a tree under
#                                                 its row in the file index
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
#   dashboard_stat_share <label> <count> <total> [tone] [details]
#   dashboard_stat_share_detail <group> <label> <count> <total> [href]
#                        the two above, reading a count as a share of its total;
#                        nothing when either is not a count
#   dashboard_report_section <report> <href> <anchors>
#                        the address of a section of a published report, for
#                        that href, or nothing when it carries no such section
#   render_dashboard  <run_id> <task_name> <subtitle> <pipeline> \
#                     <run_date> <sample_count> <expires> [plot_data]
#   dashboard_stage_records                       copies the run's record and
#                                                 the progress page's final
#                                                 state into the results folder
#   dashboard_late_files                          the files to add to the
#                                                 download once the pages are
#                                                 written and the folders indexed
#   publish_results   <s3_dir>
#
# Each of those skips a file the run did not produce, so the pages describe the
# run rather than the pipeline. Overview is always the first link and the one a
# reader lands on.
#
# "Download everything" is the one archive the run published to Globus - the
# reads it was given and this whole dashboard in a single zip - and a run that
# published none has no such button. One file rather than two, and no separate
# link to either half of it, because two downloads let a reader take one and
# believe their data was safe before the dashboard expired. It sits under the
# deletion date the navigation bar carries.
#
# render_dashboard writes the three pages into the results folder rather than
# straight to S3, so the zip a run publishes to Globus holds the same dashboard
# the bucket serves: unpack it, open the index.html in it, and every link still
# resolves.
# publish_results then uploads the folder, landing the pages last so that
# nothing they frame is still arriving - and finally retires the progress page
# index.html has just replaced, by writing "final" over the state file that page
# was following, which sends a browser still watching the run for the report.
#
# The file index comes from the catalog - templates/<pipeline>/outputs.conf -
# which names paths, globs and folders in the order they should be read, grouped
# under headings. A line naming no path is a paragraph under its heading, saying
# how the group's files were made. An entry naming several paths, or a glob
# matching several files, is one block of rows under one description. A folder
# is listed as one row pointing at the
# directory_listing.html index_directories.sh wrote into it. A path that is an
# absolute address instead is written as one row leading there, which is how the
# archive served from Globus is listed among the files it holds.
#
# A path marked HELD is a folder listed but not published: the reads the run was
# given, which are only inside that archive. Its row leads to the listing
# index_directories.sh wrote for them and is greyed, and so is every name in
# that listing, until the page is read out of an unpacked copy of the download.
#
# Icons are Material Symbols names, from the font the design system loads:
# biotech, database, filter_alt, science, folder_zip, data_object and so on.
#
# Defines: dashboard_reset, dashboard_view,
#          dashboard_methods_view, dashboard_tab, dashboard_tab_end, dashboard_button,
#          dashboard_formats, dashboard_folder, dashboard_bundle,
#          dashboard_stat_group, dashboard_stat_row, dashboard_stat_tiles,
#          dashboard_stat_chips, dashboard_stat_bar, dashboard_stat_detail,
#          dashboard_report_section, render_dashboard,
#          dashboard_stage_records, dashboard_late_files,
#          publish_results, DASHBOARD_PAGES, TEXT_EXTENSIONS,
#          DOWNLOAD_EXTENSIONS
# Requires: aws, GNU find, jq; the escape_html/escape_url/human_size/render_template
#           and warn helpers from utilities.sh
# Env:      NEXTFLOW_DIR, and RUN_STATE_FILE, RUN_STATE_KEY and
#           PROGRESS_STATE_KEY from run_state.sh

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

# The two states of a tab link in the Feature Table card, spelled the same as
# the page's own script spells them
readonly DASHBOARD_TAB_ON="font-label-caps text-label-caps font-bold text-primary border-b-2 border-primary pb-0.5"
readonly DASHBOARD_TAB_OFF="font-label-caps text-label-caps font-bold text-on-surface-variant opacity-60 hover:opacity-100 transition-opacity pb-0.5"

# The pages this script writes into the results folder. Named here because the
# upload sends them last, after everything they frame.
readonly DASHBOARD_PAGES=(overview.html deliverables.html methods.html index.html)

# The MultiQC report every pipeline publishes, and the results folder's listing
# index_directories.sh writes after the pages
readonly DASHBOARD_QC_REPORT="multiqc/multiqc_report.html"
readonly DASHBOARD_LISTING="directory_listing.html"

DASHBOARD_RESULTS_DIR=""
DASHBOARD_CATALOG=""
DASHBOARD_VIEWS=()
DASHBOARD_DOWNLOADS=""
DASHBOARD_STATS=""
DASHBOARD_STAT_GROUP_OPEN=""

# The methods data the Methods page is rendered from; empty for a run without one
DASHBOARD_METHODS=""

# The Feature Table card's tabs, in the order they were declared, and the one
# being declared now. While a tab is open, DASHBOARD_DOWNLOADS and
# DASHBOARD_STATS are that tab's, and the card's own are kept aside.
DASHBOARD_TAB=""
DASHBOARD_TAB_IDS=()
DASHBOARD_TAB_LABELS=()
DASHBOARD_TAB_BODIES=()
DASHBOARD_CARD_DOWNLOADS=""
DASHBOARD_CARD_STATS=""

# The one archive this run published to Globus: where it is served from, and
# how big it came out. The address is what "Download everything" takes and what
# a catalog entry of __BUNDLE_URL__ is read as; both are empty for a run that
# published none, which leaves the button off the page and that entry out of the
# index. The folders are the ones it was zipped from, as the paths they are
# stored under in it.
DASHBOARD_BUNDLE_URL=""
DASHBOARD_BUNDLE_SIZE=""
DASHBOARD_BUNDLE_FOLDERS=()

dashboard_reset() {
    DASHBOARD_RESULTS_DIR="${1%/}"
    DASHBOARD_CATALOG="$2"
    DASHBOARD_VIEWS=()
    DASHBOARD_DOWNLOADS=""
    DASHBOARD_STATS=""
    DASHBOARD_STAT_GROUP_OPEN=""
    DASHBOARD_TAB=""
    DASHBOARD_TAB_IDS=()
    DASHBOARD_TAB_LABELS=()
    DASHBOARD_TAB_BODIES=()
    DASHBOARD_CARD_DOWNLOADS=""
    DASHBOARD_CARD_STATS=""
    DASHBOARD_BUNDLE_URL=""
    DASHBOARD_BUNDLE_SIZE=""
    DASHBOARD_BUNDLE_FOLDERS=()
    DASHBOARD_METHODS=""
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

# One link a pipeline adds to the navigation bar, between Deliverables and QC
# Report, if the run produced the page behind it. The id is the fragment the bar
# remembers the open view as.
dashboard_view() {
    local id="$1" label="$2" path="$3"

    [[ -n "$path" && -f "$DASHBOARD_RESULTS_DIR/$path" ]] || return 0

    DASHBOARD_VIEWS+=("$id|$label|$path")
}

# The Methods page's link among those, for a run whose methods script
# wrote its data: a JSON object of paragraphs citing [@id] and the references
# those ids name, as biobakery_methods.sh writes it
dashboard_methods_view() {
    local data="$1" label="${2:-Methods}"

    [[ -s "$data" ]] || return 0

    DASHBOARD_METHODS="$data"
    DASHBOARD_VIEWS+=("methods|$label|methods.html")
}

# Take a declared link back out of the navigation bar
dashboard_drop_view() {
    local entry
    local kept=()

    for entry in ${DASHBOARD_VIEWS[@]+"${DASHBOARD_VIEWS[@]}"}; do
        [[ "${entry%%|*}" == "$1" ]] || kept+=("$entry")
    done

    DASHBOARD_VIEWS=(${kept[@]+"${kept[@]}"})
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
    local path name
    local offered=1

    for path in "$DASHBOARD_RESULTS_DIR"/$pattern; do
        [[ -r "$path" ]] || continue

        name=${path#"$DASHBOARD_RESULTS_DIR/"}

        dashboard_link_row "$(escape_url "$name")" "${label:-${name##*/}}" "$name" \
            "$(dashboard_file_icon "$name")" file_download \
            "$(dashboard_link_attributes "$name")"
        offered=0
    done

    # Whether the glob named anything, so a caller can offer a second choice for
    # the run that produced neither
    return $offered
}

# A link to the listing index_directories.sh wrote for a folder, under the
# folder's own name unless the label says otherwise
dashboard_folder() {
    local folder="${1%/}" label="${2:-}"

    [[ -d "$DASHBOARD_RESULTS_DIR/$folder" ]] || return 1

    dashboard_link_row "$(escape_url "$folder")/directory_listing.html" \
        "${label:-$folder/}" "$folder/" folder_open open_in_new \
        "$(dashboard_link_attributes directory_listing.html)"
}

# One row of the Feature Table card: an icon for what it leads to, its text,
# and an icon for what following it does
dashboard_link_row() {
    local href="$1" text="$2" title="$3" icon="$4" action="$5" attributes="$6"

    DASHBOARD_DOWNLOADS+="<a class=\"flex items-center justify-between gap-2 px-2 py-1.5 rounded hover:bg-surface-container transition-colors group\""
    DASHBOARD_DOWNLOADS+=" href=\"$href\"$attributes>"
    DASHBOARD_DOWNLOADS+="<span class=\"flex items-center gap-2 min-w-0\">"
    DASHBOARD_DOWNLOADS+="<span class=\"material-symbols-outlined text-[20px] text-on-surface-variant group-hover:text-primary transition-colors\">"
    DASHBOARD_DOWNLOADS+="$icon</span>"
    DASHBOARD_DOWNLOADS+="<span class=\"text-[13px] leading-5 text-on-surface truncate\""
    DASHBOARD_DOWNLOADS+=" title=\"$(escape_html "$title")\">$(escape_html "$text")</span></span>"
    DASHBOARD_DOWNLOADS+="<span class=\"material-symbols-outlined text-[18px] shrink-0 text-on-surface-variant opacity-0 group-hover:opacity-100 transition-opacity\">"
    DASHBOARD_DOWNLOADS+="$action</span></a>"
}

# One file the run wrote in several formats, as a row of boxes under a heading
# of its own. Each box names the format the same way - the thing itself set
# large, the encoding under it - so the row reads as one file offered three ways
# rather than as three files.
#
# Every box downloads. These are the same table whichever one is taken, and a
# browser asked to render a hundred megabytes of it helps nobody.
#
# A format the run did not write is left out rather than offered and broken, and
# a heading whose formats are all missing is not drawn at all. An empty heading
# draws the row on its own, for the file the card is already named after.
#
# An entry is "label|path", set large as BIOM, or "title|label|path" to set the
# title large instead.
dashboard_formats() {
    local heading="$1"
    local entry title label name boxes=""
    shift

    for entry in "$@"; do
        title="BIOM"
        name=${entry##*|}
        label=${entry%|*}

        if [[ "$label" == *"|"* ]]; then
            title=${label%%|*}
            label=${label#*|}
        fi

        [[ -r "$DASHBOARD_RESULTS_DIR/$name" ]] || continue

        boxes+="<a class=\"flex flex-col items-center justify-center gap-0.5 py-2 px-1 rounded-lg"
        boxes+=" border border-outline-variant bg-surface-container-lowest"
        boxes+=" hover:border-primary hover:bg-surface-container transition-colors group\""
        boxes+=" href=\"$(escape_url "$name")\" download"
        boxes+=" title=\"$(escape_html "$name")\">"
        boxes+="<span class=\"font-bold text-body-md leading-5 text-primary\">$(escape_html "$title")</span>"
        boxes+="<span class=\"font-label-caps text-[10px] leading-3 tracking-[0.06em]"
        boxes+=" text-secondary group-hover:text-primary transition-colors\">"
        boxes+="$(escape_html "$label")</span></a>"
    done

    [[ -n "$boxes" ]] || return 1

    DASHBOARD_DOWNLOADS+="<div class=\"px-2 pt-2 pb-1\">"

    if [[ -n "$heading" ]]; then
        DASHBOARD_DOWNLOADS+="<span class=\"block font-label-caps text-label-caps text-on-surface-variant mb-1.5\">"
        DASHBOARD_DOWNLOADS+="$(escape_html "$heading")</span>"
    fi

    DASHBOARD_DOWNLOADS+="<div class=\"grid grid-cols-3 gap-1.5\">$boxes</div>"
    DASHBOARD_DOWNLOADS+="</div>"

    return 0
}

# Open a tab of the Feature Table card. Until the next dashboard_tab or
# dashboard_tab_end, downloads and stat groups are written into it.
dashboard_tab() {
    dashboard_tab_end
    dashboard_end_stat_group

    DASHBOARD_CARD_DOWNLOADS="$DASHBOARD_DOWNLOADS"
    DASHBOARD_CARD_STATS="$DASHBOARD_STATS"
    DASHBOARD_DOWNLOADS=""
    DASHBOARD_STATS=""
    DASHBOARD_TAB="$1|$2"
}

# Close the open tab, dropping it when nothing was written into it, and send
# stat groups back to the statistics card. The downloads come first in a tab and
# its stat groups under them, whichever order they were declared in.
dashboard_tab_end() {
    local body=""

    [[ -n "$DASHBOARD_TAB" ]] || return 0

    dashboard_end_stat_group

    if [[ -n "$DASHBOARD_DOWNLOADS" ]]; then
        body+="<div class=\"flex flex-col gap-0.5\">$DASHBOARD_DOWNLOADS</div>"
    fi

    if [[ -n "$DASHBOARD_STATS" ]]; then
        #    A block with no heading starts closer under the downloads
        local gap="mt-4"
        [[ "$DASHBOARD_STATS" == "<div><h4"* ]] || gap="mt-3"

        body+="<div class=\"flex flex-col gap-5 px-2${DASHBOARD_DOWNLOADS:+ $gap}\">$DASHBOARD_STATS</div>"
    fi

    if [[ -n "$body" ]]; then
        DASHBOARD_TAB_IDS+=("${DASHBOARD_TAB%%|*}")
        DASHBOARD_TAB_LABELS+=("${DASHBOARD_TAB#*|}")
        DASHBOARD_TAB_BODIES+=("$body")
    fi

    DASHBOARD_DOWNLOADS="$DASHBOARD_CARD_DOWNLOADS"
    DASHBOARD_STATS="$DASHBOARD_CARD_STATS"
    DASHBOARD_TAB=""
}

# The one archive the run published to the guest collection: the reads it was
# given and the whole of this dashboard, in a single zip. Declared before the
# pages are rendered, since the button and the file index are both read off it.
#
# The size is the archive as it stands on the collection, in bytes, and is what
# the button says a reader is about to start. It is left off for a run that
# could not be measured, which only drops the figure from the label.
#
# The folders are what was zipped, in the order it was zipped, and are drawn as
# the tree the archive unpacks into.
dashboard_bundle() {
    local url="$1" bytes="${2:-}"

    [[ -n "$url" ]] || return 0

    DASHBOARD_BUNDLE_URL="$url"
    DASHBOARD_BUNDLE_FOLDERS=("${@:3}")

    [[ "$bytes" =~ ^[0-9]+$ ]] && DASHBOARD_BUNDLE_SIZE="$bytes"

    return 0
}

# The button that takes everything this run published. Nothing at all for a run
# that published no archive.
#
# It sits at the top right of the Overview, directly under the deletion date the
# navigation bar carries, so the reader who has just been told the results go
# away is looking at the way to keep them.
#
# The address is the only absolute link on the page: the archive is served from
# the guest collection rather than sitting beside the page, so it is also the
# link that does not resolve in an unpacked copy.
#
# The button is a plain link, so a middle-click or a shared address still starts
# the download with no script involved.
dashboard_zip_button() {
    [[ -n "$DASHBOARD_BUNDLE_URL" ]] || return 0

    printf '<a class="shrink-0 bg-primary text-on-primary px-3.5 py-2 rounded-lg text-[13px] font-semibold hover:bg-primary-container transition-colors flex items-center justify-center gap-1.5 whitespace-nowrap"'
    printf ' id="download-all" href="%s"' "$(escape_html "$DASHBOARD_BUNDLE_URL")"
    printf '><span class="material-symbols-outlined text-[18px]">archive</span>Download everything'

    #    How big it is, set lighter than the label: it qualifies the button
    #    rather than naming it, and a reader deciding whether to start a
    #    forty-gigabyte download reads it after the verb, not instead of it
    [[ -n "$DASHBOARD_BUNDLE_SIZE" ]] \
        && printf '<span class="font-normal text-[12px] opacity-80">(%s)</span>' \
               "$(escape_html "$(human_size "$DASHBOARD_BUNDLE_SIZE")")"

    printf '</a>'
}

# Text as HTML, with every count human_count shortened written as a span whose
# tooltip is the exact figure: 4.4M over "4,404,860"
dashboard_count_html() {
    local text out="" pattern=$'\034([0-9]+)\035([^\036]*)\036'

    text=$(escape_html "$1")

    while [[ "$text" =~ $pattern ]]; do
        out+="${text%%"${BASH_REMATCH[0]}"*}"
        out+="<span title=\"$(group_count "${BASH_REMATCH[1]}")\">${BASH_REMATCH[2]}</span>"
        text=${text#*"${BASH_REMATCH[0]}"}
    done

    printf '%s' "$out$text"
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
# it. With neither a heading nor a note, the block opens with no heading line.
dashboard_stat_group() {
    local heading="${1:-}" note="${2:-}"

    dashboard_end_stat_group

    if [[ -z "$heading$note" ]]; then
        DASHBOARD_STATS+="<div>"
        DASHBOARD_STAT_GROUP_OPEN=1
        return 0
    fi

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
        DASHBOARD_STATS+="$(dashboard_count_html "$value")</span>"
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
#
# A note is written small under the bar - the database a reading was taken
# against - and an explanation of what it counts behind an icon beside the label.
dashboard_stat_bar() {
    local label="$1" reading="$2" percent="$3" tone="${4:-}" details="${5:-}" note="${6:-}" info="${7:-}"

    case "$tone" in
        growth)    tone="bg-bio-growth" ;;
        *)         tone="bg-primary-container" ;;
    esac

    percent=$(dashboard_bar_fill "$percent")

    DASHBOARD_STATS+="<div class=\"mb-2.5 last:mb-0\"><div class=\"flex justify-between items-baseline gap-2 mb-1\">"
    DASHBOARD_STATS+="<span class=\"font-body-sm text-body-sm font-medium text-on-surface\">$(escape_html "$label")"

    #    An explanation of what the reading counts, as a small icon beside the
    #    label whose tooltip carries it
    if [[ -n "$info" ]]; then
        DASHBOARD_STATS+="<span class=\"material-symbols-outlined ml-0.5 align-[-2px] text-[13px] leading-none"
        DASHBOARD_STATS+=" text-outline/70 hover:text-on-surface-variant cursor-help select-none\""
        DASHBOARD_STATS+=" title=\"$(escape_html "$info")\" aria-label=\"$(escape_html "$info")\""
        DASHBOARD_STATS+=" role=\"img\">info</span>"
    fi

    if [[ -n "$details" ]]; then
        DASHBOARD_STATS+="<button type=\"button\" data-stat-details=\"$(escape_html "$details")\""
        DASHBOARD_STATS+=" aria-expanded=\"false\" style=\"display: none\""
        DASHBOARD_STATS+=" class=\"ml-1.5 font-body-sm text-body-sm font-normal text-primary underline"
        DASHBOARD_STATS+=" decoration-dotted underline-offset-2 hover:no-underline\">details</button>"
    fi

    DASHBOARD_STATS+="</span>"
    DASHBOARD_STATS+="<span class=\"font-code-sm text-code-sm text-on-surface-variant\">$(dashboard_count_html "$reading")</span></div>"
    DASHBOARD_STATS+="<div class=\"h-1.5 w-full bg-surface-variant rounded-full overflow-hidden\">"
    DASHBOARD_STATS+="<div class=\"h-full $tone rounded-full\" style=\"width: $percent%;\"></div></div>"

    if [[ -n "$note" ]]; then
        DASHBOARD_STATS+="<div class=\"mt-1 truncate font-body-sm text-[11px] leading-4 text-outline\""
        DASHBOARD_STATS+=" title=\"$(escape_html "$note")\">$(escape_html "$note")</div>"
    fi

    DASHBOARD_STATS+="</div>"

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
    DASHBOARD_STATS+="$(dashboard_count_html "$reading")</span></div>"
    DASHBOARD_STATS+="<div class=\"h-1 w-full bg-surface-variant rounded-full overflow-hidden\">"
    DASHBOARD_STATS+="<div class=\"h-full bg-primary-container/60 rounded-full\" style=\"width: $percent%;\"></div>"
    DASHBOARD_STATS+="</div></div>"

    return 0
}

# A count against the total it was taken against, as the fill a bar takes and
# the reading written beside it.
#
# The share is written whole, except where rounding it whole would read 100% for
# a step that did drop reads: quality filtering keeps 99.5% of a good run, and a
# sidebar calling that 100% tells the reader nothing happened.
#
# Nothing at all when either is not a count, which is how a step the run did not
# take leaves out its bar rather than reporting a share of nothing.
dashboard_share_reading() {
    local count="$1" total="$2"

    [[ "$count" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 1
    (( total > 0 )) || return 1

    LC_ALL=C awk -v c="$count" -v t="$total" 'BEGIN {
        share = c * 100 / t
        text = sprintf("%.0f", share)

        if (text == "100" && c < t) {
            text = sprintf("%.1f", share)
            if (text == "100.0") text = "99.9"
        }

        printf "%.4f %s\n", share, text
    }'
}

# One reading as a bar: what it is, how many reads it was, and what share of the
# total. Green is for the reads that came through; what was taken out is left in
# the navy every total wears.
dashboard_stat_share() {
    local label="$1" count="$2" total="$3" tone="${4:-growth}" details="${5:-}"
    local percent reading

    read -r percent reading < <(dashboard_share_reading "$count" "$total") || return 0

    dashboard_stat_bar "$label" "$reading% · $(human_count "$count")" "$percent" \
        "$tone" "$details"
}

# The same reading with the total written beside the count - "19% · 764k / 4.0M" -
# a note under the bar, and an explanation behind an icon beside the label
dashboard_stat_share_of() {
    local label="$1" count="$2" total="$3" note="${4:-}" info="${5:-}"
    local percent reading

    read -r percent reading < <(dashboard_share_reading "$count" "$total") || return 0

    dashboard_stat_bar "$label" "$reading% · $(human_count "$count") / $(human_count "$total")" \
        "$percent" growth "" "$note" "$info"
}

# The same reading as one of the steps behind a bar's "details" link
dashboard_stat_share_detail() {
    local group="$1" label="$2" count="$3" total="$4" href="${5:-}"
    local percent reading

    read -r percent reading < <(dashboard_share_reading "$count" "$total") || return 0

    dashboard_stat_detail "$group" "$label" "$reading% · $(human_count "$count")" \
        "$percent" "$href"
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

# The Feature Table card's heading, plural once it holds more than one tab
dashboard_downloads_title() {
    if (( ${#DASHBOARD_TAB_IDS[@]} > 1 )); then
        printf 'Feature Tables'
    else
        printf 'Feature Table'
    fi
}

# What the Feature Table card offers - a row of tab links over one panel per
# tab, the first of them showing - or a line saying the run named nothing
dashboard_downloads() {
    local count=${#DASHBOARD_TAB_IDS[@]}
    local i id class selected style

    if [[ -z "$DASHBOARD_DOWNLOADS" ]] && (( count == 0 )); then
        printf '<p class="font-body-sm text-body-sm text-on-surface-variant p-2">'
        printf 'This run names no single files; take all of it with the button above.</p>'
        return 0
    fi

    if [[ -n "$DASHBOARD_DOWNLOADS" ]]; then
        printf '<div class="flex flex-col gap-0.5">%s</div>' "$DASHBOARD_DOWNLOADS"
    fi

    (( count > 0 )) || return 0

    printf '<div class="flex flex-wrap items-center gap-x-4 gap-y-1 ml-1 mb-3" role="tablist">'

    for (( i = 0; i < count; i++ )); do
        class="$DASHBOARD_TAB_OFF"
        selected="false"

        if (( i == 0 )); then
            class="$DASHBOARD_TAB_ON"
            selected="true"
        fi

        printf '<button type="button" role="tab" aria-selected="%s" class="%s" data-feature-tab="%s">%s</button>' \
            "$selected" "$class" "$(escape_html "${DASHBOARD_TAB_IDS[i]}")" \
            "$(escape_html "${DASHBOARD_TAB_LABELS[i]}")"
    done

    printf '</div>'

    for (( i = 0; i < count; i++ )); do
        id=$(escape_html "${DASHBOARD_TAB_IDS[i]}")
        style=""

        (( i > 0 )) && style=' style="display: none"'

        printf '<div role="tabpanel" data-feature-panel="%s"%s>%s</div>' \
            "$id" "$style" "${DASHBOARD_TAB_BODIES[i]}"
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

# The navigation bar: Overview and Deliverables, the views the pipeline declared
# in that order, then QC Report when the run wrote one, and File Explorer
dashboard_nav() {
    local entry id label path
    local views=("deliverables|Deliverables|deliverables.html")

    views+=(${DASHBOARD_VIEWS[@]+"${DASHBOARD_VIEWS[@]}"})

    if [[ -f "$DASHBOARD_RESULTS_DIR/$DASHBOARD_QC_REPORT" ]]; then
        views+=("quality|QC Report|$DASHBOARD_QC_REPORT")
    fi

    views+=("listing|File Explorer|$DASHBOARD_LISTING")

    printf '<a class="%s" data-view="overview" href="overview.html" target="view">Overview</a>' \
        "$DASHBOARD_NAV_ON"

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

# The folders under one directory, one line each, drawn below the line naming it
# with the prefix that line's place in the tree gives them
dashboard_tree_lines() {
    local dir="$1" prefix="$2"
    local children=() i last branch next

    mapfile -t children < <(find -L "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | LC_ALL=C sort)

    last=$(( ${#children[@]} - 1 ))

    for (( i = 0; i <= last; i++ )); do
        branch="├── "
        next="│   "

        if (( i == last )); then
            branch="└── "
            next="    "
        fi

        printf '%s%s%s/\n' "$prefix" "$branch" "$(escape_html "${children[i]}")"
        dashboard_tree_lines "$dir/${children[i]}" "$prefix$next"
    done
}

# What the archive unpacks into: the folders dashboard_bundle was given and every
# folder under them, with the archive's own name at the root. Files are left
# out, so the tree reads as a map of where things are. Nothing for an upload
# script that named no folders, or when none of them is still there.
dashboard_bundle_tree() {
    local folder name last i
    local folders=()

    for folder in ${DASHBOARD_BUNDLE_FOLDERS[@]+"${DASHBOARD_BUNDLE_FOLDERS[@]}"}; do
        [[ -d "$folder" ]] && folders+=("${folder%/}")
    done

    last=$(( ${#folders[@]} - 1 ))
    (( last >= 0 )) || return 0

    name=${DASHBOARD_BUNDLE_URL%%\?*}
    name=${name##*/}

    printf '<pre class="tree">%s\n' "$(escape_html "$name")"

    for (( i = 0; i <= last; i++ )); do
        if (( i == last )); then
            printf '└── %s/\n' "$(escape_html "${folders[i]}")"
            dashboard_tree_lines "${folders[i]}" "    "
        else
            printf '├── %s/\n' "$(escape_html "${folders[i]}")"
            dashboard_tree_lines "${folders[i]}" "│   "
        fi
    done

    printf '</pre>'
}

# One row of the file index: what it is called, how big it is, and - on the
# last row of its entry - what it holds. An href that is already a whole address
# is written as it stands - it was built here, not read off a disk - and always
# downloads, since the only such row is the archive the collection serves as an
# attachment.
#
# A held row names a folder this copy of the page does not publish: the reads,
# which are only inside that archive. It is greyed and carries the note saying
# so, and the page's own script turns it back into an ordinary row in the copy
# read out of an unpacked download, where those files are there to open.
dashboard_row() {
    local href="$1" label="$2" description="$3" size="$4" tag="$5" held="${6:-}"
    local link attributes row="<tr>"

    if [[ "$href" == http://* || "$href" == https://* ]]; then
        link="$href"
        attributes=""
    else
        link="$(escape_url "$href")"
        attributes="$(dashboard_link_attributes "$href")"
    fi

    [[ -n "$held" ]] && row="<tr class=\"held\">"

    printf '%s<td class="name"><a href="%s"%s>%s</a>' \
        "$row" "$link" "$attributes" "$(escape_html "$label")"

    [[ -n "$tag" ]] && printf '<span class="tag">%s</span>' "$(escape_html "$tag")"

    [[ -n "$description" ]] && printf '<span class="desc">%s</span>' "$(escape_html "$description")"

    [[ "$href" == "$DASHBOARD_BUNDLE_URL" ]] && dashboard_bundle_tree

    #    Where those files actually are, since the row leading to them is the
    #    one place a reader would look for them first
    [[ -n "$held" ]] && printf '<span class="held-note">%s</span>' \
        'Not published here — take these with the “Download everything” button on the Overview.'

    printf '</td><td class="size">%s</td></tr>\n' "$(escape_html "$size")"
}

# One file of a catalog entry, appended to the hrefs, labels, sizes, tags and
# helds its caller declared
dashboard_add_file() {
    hrefs+=("$1")
    labels+=("$2")
    sizes+=("$3")
    tags+=("$4")
    helds+=("${5:-}")
}

# The files one path of a catalog entry names. A folder is one file naming its
# listing page; a glob is one per file it matches, in name order; an absolute
# address is one leading there, for the archive published to the guest
# collection rather than into the results folder - and that one reports the size
# the archive came out at, which is the only size here not read off a file that
# is present.
#
# A path marked HELD is the folder listed but not published. It is counted where
# the run staged it - beside the results rather than in them - and its row leads
# to the listing index_directories.sh wrote for it inside them.
dashboard_entry_files() {
    local path="$1" label="$2"
    local full match name count size

    if [[ "$path" == http://* || "$path" == https://* ]]; then
        size=""

        if [[ "$path" == "$DASHBOARD_BUNDLE_URL" && -n "$DASHBOARD_BUNDLE_SIZE" ]]; then
            size=$(human_size "$DASHBOARD_BUNDLE_SIZE")
        fi

        dashboard_add_file "$path" "${label:-${path##*/}}" "$size" ""
        return 0
    fi

    if [[ "$path" == HELD:* ]]; then
        path=${path#HELD:}
        full="${path%/}"

        [[ -d "$full" ]] || return 0

        count=$(find -L "$full" -type f ! -name directory_listing.html | wc -l)
        (( count > 0 )) || return 0

        dashboard_add_file "${path}directory_listing.html" "${label:-$path}" \
            "$count files" "folder" held
        return 0
    fi

    if [[ "$path" == */ ]]; then
        full="$DASHBOARD_RESULTS_DIR/${path%/}"

        [[ -d "$full" ]] || return 0

        # The listing pages index_directories.sh writes are how the folder is
        # read, not something the run produced
        count=$(find -L "$full" -type f ! -name directory_listing.html | wc -l)
        (( count > 0 )) || return 0

        dashboard_add_file "${path}directory_listing.html" "${label:-$path}" \
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

        dashboard_add_file "$name" "$match" "$size" ""
    done
}

# One catalog entry as one block of the index: a row per file its
# whitespace-separated paths name, in the order they are written, and the
# description once, under the last. Prints nothing when no path matched.
dashboard_entry() {
    local paths="$1" label="$2" description="$3"
    local path i last text
    local list=() hrefs=() labels=() sizes=() tags=() helds=()

    read -ra list <<< "$paths"

    for path in "${list[@]}"; do
        dashboard_entry_files "$path" "$label"
    done

    last=$(( ${#hrefs[@]} - 1 ))
    (( last >= 0 )) || return 0

    printf '<tbody>'

    for (( i = 0; i <= last; i++ )); do
        text=""
        (( i == last )) && text="$description"

        dashboard_row "${hrefs[i]}" "${labels[i]}" "$text" "${sizes[i]}" \
            "${tags[i]}" "${helds[i]}"
    done

    printf '</tbody>'
}

# One group of the file index, kept only when the run produced something to put
# in it: its heading, what the group's own lines say about it, and its entries.
# Appends to the GROUP_NAV and SECTIONS its caller declared.
dashboard_end_group() {
    local group="$1" about="$2" rows="$3" slug

    [[ -n "$group" && -n "$rows" ]] || return 0

    slug=$(dashboard_slug "$group")

    GROUP_NAV+="<a href=\"#$slug\">$(escape_html "$group")</a>"
    SECTIONS+="<section class=\"group\" id=\"$slug\">"
    SECTIONS+="<h2>$(escape_html "$group")</h2>"
    [[ -n "$about" ]] && SECTIONS+="<div class=\"about\">$about</div>"
    SECTIONS+="<table>$rows</table></section>"
}

# The file index, and the menu beside it. Both are built in one pass over the
# catalog, so a group that produced no rows appears in neither.
#
# Reads the catalog into GROUP_NAV and SECTIONS rather than printing, since one
# pass has to produce both.
dashboard_index() {
    local line group path label description
    local current="" group_about="" group_rows=""

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

        [[ -n "$group" ]] || continue

        if [[ "$group" != "$current" ]]; then
            dashboard_end_group "$current" "$group_about" "$group_rows"
            current="$group"
            group_about=""
            group_rows=""
        fi

        # A line naming no path and no label describes the group itself, one
        # paragraph per line. Judged before the archive's address is
        # substituted, so a run without one does not turn its row into this.
        if [[ -z "$path" && -z "$label" ]]; then
            [[ -n "$description" ]] && group_about+="<p>$(escape_html "$description")</p>"
            continue
        fi

        # The one entry for something served from the guest collection rather
        # than published into the results folder. Substituted before the entry
        # is judged empty, so a run that published no archive drops the row
        # rather than listing the results folder itself.
        path=${path//__BUNDLE_URL__/"$DASHBOARD_BUNDLE_URL"}

        [[ -n "$path" ]] || continue

        group_rows+=$(dashboard_entry "$path" "$label" "$description")
    done < "$DASHBOARD_CATALOG"

    dashboard_end_group "$current" "$group_about" "$group_rows"
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

    # A tab the upload script left open, so its stat groups are not counted as
    # the statistics card's
    dashboard_tab_end

    render_template "$NEXTFLOW_DIR/templates/overview.html" \
        TASK_NAME   "$(escape_html "$task_name")" \
        SUBTITLE    "$(escape_html "$subtitle")" \
        PLOT_DATA   "$(dashboard_plot_data "$plot_data")" \
        DOWNLOADS_TITLE "$(dashboard_downloads_title)" \
        DOWNLOADS   "$(dashboard_downloads)" \
        ZIP_BUTTON  "$(dashboard_zip_button)" \
        STATS       "$(dashboard_stats_card "$sample_count")" \
        YEAR        "$(date '+%Y')" \
        FOOTER_NOTE "$(dashboard_footer_note "$run_date" "$pipeline" "$run_id")"
}

# One part of the Methods page, as markup: "text", the paragraphs with their
# [@id] citations written author-year; "references", the references they cite in
# alphabetical order, each linked to its DOI or its address; or "bibtex", the
# same references as BibTeX entries keyed by their ids.
#
# A reference is the structured entry config/references.json holds. Its
# citation, its formatted form and its BibTeX are all derived here: an author is
# "Family, Initials" or an organisation, and et_al marks a list cut short.
dashboard_methods_html() {
    local part="$1"

    jq -r --arg part "$part" '
        def ids: [scan("@([A-Za-z0-9_]+)") | .[0]];
        def cited: [scan("\\[@[^\\]]*\\]") | ids[]];
        def firsts: reduce .[] as $id ([]; if any(.[]; . == $id) then . else . + [$id] end);

        def person: contains(", ");
        def family: if person then split(", ")[0] else . end;
        def initials: split(", ")[1] // "";
        def stop: if test("[.?!]$") then . else . + "." end;
        def link: if .doi then "https://doi.org/" + .doi else (.url // "") end;

        def citation:
            .cite // (
                (.author | map(family)) as $names
                | (if (.et_al // false) or ($names | length) > 2 then $names[0] + " et al."
                   elif ($names | length) == 2 then $names[0] + " and " + $names[1]
                   else $names[0] end)
                + ", " + (.year | tostring));

        def formatted:
            ((.author | map(if person then family + " " + initials else . end) | join(", "))
             + (if .et_al then ", et al" else "" end) | stop)
            + " " + (.title | stop) + " "
            + if .type == "article" then
                (.journal_abbrev // .journal) + ". " + (.year | tostring)
                + (if .volume then ";" + .volume else "" end)
                + (if .number then "(" + .number + ")" else "" end)
                + (if .pages then ":" + .pages else "" end) + "."
              else
                (if .publisher then .publisher + "; " else "" end) + (.year | tostring) + "."
              end;

        def latex: gsub("(?<c>[&%$#_])"; "\\" + .c);
        def bibname:
            if person
            then family + ", " + (initials | explode | map([.] | implode + ".") | join(" "))
            else "{" + . + "}" end;

        def bibtex($id):
            "@" + (if .type == "article" then "article" else "misc" end) + "{" + $id + ",\n"
            + ([["author", ((.author | map(bibname)) + (if .et_al then ["others"] else [] end)
                            | join(" and "))],
                ["title", "{" + (.title | latex) + "}"],
                ["journal", (.journal // null | if . then latex else . end)],
                ["publisher", (.publisher // null | if . then latex else . end)],
                ["year", (.year | tostring)],
                ["volume", .volume],
                ["number", .number],
                ["pages", (.pages // null | if . then gsub("–"; "--") else . end)],
                ["doi", .doi],
                ["url", (if .doi then null else .url end)]]
               | map(select(.[1] != null) | "  " + .[0] + " = {" + .[1] + "}")
               | join(",\n"))
            + "\n}";

        . as $data
        | ([$data.paragraphs[] | cited[]] | firsts) as $order
        | ($data.references // {}) as $refs
        | [$order[] | . as $id | {id: $id, ref: ($refs[$id] // {author: [$id], title: $id, year: ""})}]
          as $cited

        | if $part == "text" then
            [$data.paragraphs[]
             | gsub("\\[(?<group>@[^\\]]*)\\]";
                    "(" + (.group | ids | map(($refs[.] // null) as $ref
                                              | if $ref then $ref | citation else . end)
                           | join("; ")) + ")")
             | "<p>" + @html + "</p>"]
            | join("")

          elif $part == "references" then
            $cited
            | map(.ref | {text: formatted, link: link})
            | sort_by(.text | ascii_downcase)
            | map("<li>" + (.text | @html)
                  + (.link | if . == "" then ""
                             else " <a href=\"" + @html + "\" target=\"_blank\" rel=\"noopener\">"
                                  + @html + "</a>" end)
                  + "</li>")
            | "<ul class=\"methods-refs\">" + join("") + "</ul>"

          else
            $cited
            | sort_by(.id)
            | map(.id as $id | .ref | bibtex($id))
            | "<pre class=\"methods-bibtex\">" + (join("\n\n") | @html) + "</pre>"
          end
    ' "$DASHBOARD_METHODS"
}

# How the run's results were made, for a manuscript
render_methods() {
    local run_id="$1" task_name="$2" pipeline="$3" run_date="$4"
    local text references bibtex

    text=$(dashboard_methods_html text) || return 1
    references=$(dashboard_methods_html references) || return 1
    bibtex=$(dashboard_methods_html bibtex) || return 1

    render_template "$NEXTFLOW_DIR/templates/methods.html" \
        TASK_NAME   "$(escape_html "$task_name")" \
        TEXT        "$text" \
        REFERENCES  "$references" \
        BIBTEX      "$bibtex" \
        YEAR        "$(date '+%Y')" \
        FOOTER_NOTE "$(dashboard_footer_note "$run_date" "$pipeline" "$run_id")"
}

# The run's final outputs, annotated
render_deliverables() {
    local run_id="$1" task_name="$2" pipeline="$3" run_date="$4"

    local GROUP_NAV SECTIONS

    if [[ ! -r "$DASHBOARD_CATALOG" ]]; then
        warn "No output catalog at $DASHBOARD_CATALOG; the file index will be empty."
        GROUP_NAV=""
        SECTIONS="<p class=\"empty\">No file index was built for this run.</p>"
    else
        dashboard_index
    fi

    render_template "$NEXTFLOW_DIR/templates/deliverables.html" \
        TASK_NAME   "$(escape_html "$task_name")" \
        GROUP_NAV   "$GROUP_NAV" \
        SECTIONS    "$SECTIONS" \
        YEAR        "$(date '+%Y')" \
        FOOTER_NOTE "$(dashboard_footer_note "$run_date" "$pipeline" "$run_id")"
}

# Write the pages into the results folder, from what the run produced and what
# the upload script declared. Prints whatever failed.
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

    for name in overview deliverables methods shell; do
        case "$name" in
            overview)     page=$(render_overview "$run_id" "$task_name" "$subtitle" \
                                     "$pipeline" "$run_date" "$sample_count" "$plot_data") ;;
            deliverables) page=$(render_deliverables "$run_id" "$task_name" "$pipeline" "$run_date") ;;
            methods)      [[ -n "$DASHBOARD_METHODS" ]] || continue
                          page=$(render_methods "$run_id" "$task_name" "$pipeline" "$run_date") ;;
            shell)        page=$(render_shell "$run_id" "$task_name" "$expires") ;;
        esac

        #    The Methods page is left out, and its link with it, rather than
        #    costing the run its dashboard
        if [[ "$name" == methods && -z "$page" ]]; then
            warn "The Methods page could not be built from $DASHBOARD_METHODS; leaving it out."
            dashboard_drop_view methods
            continue
        fi

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

# The two files published beside the results that nothing in the run writes into
# them - the run's own record as it stands, and the progress page's state file as
# publish_results leaves it - copied into the results folder, so the folder
# listings name them and the download carries them. wrike_followup.sh publishes
# the record once more when the run is marked complete, over the copy sent here.
dashboard_stage_records() {
    cp "$RUN_STATE_FILE" "$DASHBOARD_RESULTS_DIR/$RUN_STATE_KEY" || return 1
    printf '{"state":"final"}\n' > "$DASHBOARD_RESULTS_DIR/$PROGRESS_STATE_KEY"
}

# What goes into the download after it was first built, one path per line: the
# pages, the records dashboard_stage_records copied in, and every folder
# listing, all of which are written after the archive whose size the pages state
dashboard_late_files() {
    local name

    for name in "${DASHBOARD_PAGES[@]}" "$RUN_STATE_KEY" "$PROGRESS_STATE_KEY"; do
        [[ -f "$DASHBOARD_RESULTS_DIR/$name" ]] && printf '%s\n' "$DASHBOARD_RESULTS_DIR/$name"
    done

    find "$DASHBOARD_RESULTS_DIR" -name directory_listing.html -type f
}

# Copy the results folder to its prefix, then the pages on top of it.
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

    # After the includes, which is what lets an exclude overrule one. The
    # progress page's state file is written below, after the pages.
    for page in "${DASHBOARD_PAGES[@]}" "$PROGRESS_STATE_KEY"; do
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

    # The progress page that index.html has just replaced was following the
    # state file beside it, so the last thing that file tells it is to ask for
    # the page again - which is how a reader watching the run is handed the
    # report without touching anything. A browser that is not on that page has
    # nothing to read this, so it warns rather than fails.
    printf '{"state":"final"}\n' \
        | aws s3 cp - "$dest/$PROGRESS_STATE_KEY" \
            --content-type "application/json" --cache-control "no-cache" \
            > /dev/null 2>&1 \
        || warn "Could not retire the progress page's state file at $dest."
}
