#!/usr/bin/env bash
#
# subenum.sh - Passive + Active subdomain enumeration with per-target output structure
#
# Usage:
#   ./subenum.sh target1.com target2.com ...
#
# Output structure:
#   ./recon/<target>/passive/     <- one file per passive tool
#   ./recon/<target>/active/      <- one file per active tool
#   ./recon/<target>/final/       <- merged + deduped results (older data is preserved)
#

set -o pipefail

# ----------------------------------------------------------------- formatting
BOLD=$'\033[1m'
RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[1;34m'
CYAN=$'\033[1;36m'
RESET=$'\033[0m'

info()    { if [ "${SILENT:-0}" -eq 1 ]; then return 0; fi; echo "${BLUE}[+ INFO ]${RESET} $*"; }
ok()      { echo "${GREEN}[+  OK  ]${RESET} $*"; }
warn()    { echo "${YELLOW}[! WARN ]${RESET} $*"; }
fail()    { echo "${RED}[! FAIL ]${RESET} $*"; }

banner() {
    [ "$SILENT" -eq 1 ] && return 0
    local TITLE="${CYAN}${BOLD}"
    local SUB="${YELLOW}"
    local LINE="${CYAN}"
    local DIM="${BLUE}"
    local E="${RESET}"

    echo "${TITLE}"
    echo "   ███████╗██╗   ██╗██████╗ ███████╗███╗   ██╗██╗   ██╗███╗   ███╗"
    echo "   ██╔════╝██║   ██║██╔══██╗██╔════╝████╗  ██║██║   ██║████╗ ████║"
    echo "   ███████╗██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║   ██║██╔████╔██║"
    echo "   ╚════██║██║   ██║██╔══██╗██╔══╝  ██║╚██╗██║██║   ██║██║╚██╔╝██║"
    echo "   ███████║╚██████╔╝██████╔╝███████╗██║ ╚████║╚██████╔╝██║ ╚═╝ ██║"
    echo "   ╚══════╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝ ╚═════╝ ╚═╝     ╚═╝"
    echo "${E}"
    echo "${LINE}   ─────────────────────────────────────────────────────────────${E}"
    echo "   ${SUB}${BOLD}Passive${E} ${LINE}+${E} ${SUB}${BOLD}Active${E} ${LINE}subdomain enumeration${E}"
    echo "   ${DIM}Sources: subfinder, amass, assetfinder, findomain, crt.sh, hackertarget${E}"
    echo "   ${DIM}Active : puredns bruteforce (rate limited)${E}"
    echo "   ${DIM}Output : merged + deduped per target, old data preserved${E}"
    echo "${LINE}   ─────────────────────────────────────────────────────────────${E}"
    echo "${E}"
}

# ----------------------------------------------------------------- validation
have() { command -v "$1" >/dev/null 2>&1; }

check_tool() {
    if have "$1"; then
        ok "$1 found"
        return 0
    else
        warn "$1 not found - it will be SKIPPED"
        return 1
    fi
}

usage() {
    local H1="${CYAN}${BOLD}"   # section headings
    local H2="${GREEN}${BOLD}"  # commands / flags
    local H3="${YELLOW}"        # key words
    local DIM="${BLUE}"         # comments / notes
    local E="${RESET}"          # restore normal

    echo "${H1}"
    echo "  =============================================================="
    echo "                     S U B E N U M  -  recon helper"
    echo "           Passive + Active subdomain enumeration"
    echo "  =============================================================="
    echo "${E}"
    echo

    echo "${H1}  USAGE${E}"
    echo "    subenum ${H2}target.com${E} [${H2}more targets...${E}]"
    echo "    subenum ${H2}-l${E} list.txt   ${DIM}# targets from file${E}"
    echo "    subenum ${H2}-o${E} results/   ${DIM}# custom results folder${E}"
    echo "    ${DIM}list file: one domain per line; ${H3}#comments${DIM} and blank lines ignored${E}"
    echo

    echo "${H1}  OPTIONS${E}"
    echo "    ${H2}-h, --help${E}            show help and quit"
    echo "    ${H2}-l, --list <file>${E}     targets file (${H3}one domain per line${E})"
    echo "    ${H2}-o, --output <dir>${E}    results directory, ${H3}created if missing${E}"
    echo "                          ${DIM}you can mix --list with extra command-line targets${E}"
    echo "                          ${DIM}amass progress bar is throttled to 1 line per"
    echo "                          ${DIM}AMASS_BAR_INTERVAL seconds (default 30)${E}"
    echo "    ${H2}-v, --verbose${E}        natural output + each tool's own verbose flag"
    echo "    ${H2}-s, --silent${E}         minimal: tools silenced, no banner/headers/"
    echo "                          ${DIM}summaries, tool stderr dropped${E}"
    echo "                          ${DIM}DEFAULT: every tool's own output shown as-is -"
    echo "                          ${DIM}incl. amass progress bar and source logs${E}"
    echo "    ${H2}-q, --query-delay N${E}  ${H3}seconds between queries${E} ${DIM}(API protection):"
    echo "                          subfinder -rl, findomain --rate-limit, puredns rate,"
    echo "                          amass has NO per-query rate - only TOOL_DELAY works there${E}"
    echo "    ${H2}-p, --parallel${E}       run all passive sources ${H3}simultaneously${E} (fast;"
    echo "                          ${DIM}TOOL_DELAY between tools is skipped in this mode,"
    echo "                          ${DIM}-v output will interleave${E})"
    echo

    echo "${H1}  FLOW${E}"
    echo "    ${H2}1.${E} ${H3}PASSIVE${E} for every target: ${DIM}subfinder, amass, assetfinder,"
    echo "       findomain, crt.sh, hackertarget${E} ${DIM}(missing tools skipped)${E}"
    echo "    ${H2}2.${E} results merged + ${H3}deduped${E} per target"
    echo "    ${H2}3.${E} ${H3}YOU decide${E}: go ${H3}ACTIVE${E} or stop"
    echo "    ${H2}4.${E} ACTIVE (puredns bruteforce), ${H3}rate limited 50 req/s${E}"
    echo "    ${H2}5.${E} final report - old data is ${H3}never deleted${E}"
    echo

    echo "${H1}  OUTPUT STRUCTURE${E}"
    echo "    ${H2}<out>/<target>/passive/${E}   ${DIM}one .txt per passive tool${E}"
    echo "    ${H2}<out>/<target>/active/${E}    ${DIM}one .txt per active tool${E}"
    echo "    ${H2}<out>/<target>/final/${E}     ${DIM}<target>_subdomains_<date>.txt${E}"
    echo "    ${DIM}default output: ${H3}next to the script${DIM} - safe to call from anywhere${E}"
    echo

    echo "${H1}  ACTIVE PHASE NEEDS${E}"
    echo "    ${H2}puredns${E} binary + a wordlist ${DIM}(asked only if you choose active)${E}"
    echo "    resolvers: ${H2}~/.config/puredns/resolvers.txt${E} ${DIM}(custom path asked if absent)${E}"
    echo

    echo "${H1}  ENVIRONMENT${E}"
    echo "    ${H2}TOOL_TIMEOUT=150${E}   ${DIM}optional: kill each tool after 150s. default: 0 = no limit${E}"
    echo "    ${H2}TOOL_DELAY=10${E}      ${DIM}optional: wait 10s BETWEEN tool calls. default: 0 = no delay${E}"
    echo "                          ${DIM}use it to slow API-key usage of the sources${E}"
    echo

    echo "${H1}  EXAMPLES${E}"
    echo "    ${H2}subenum target.com${E}"
    echo "    ${H2}subenum target1.com target2.com${E}"
    echo "    ${H2}subenum --list targets.txt${E}"
    echo "    ${H2}subenum -l targets.txt extra.com${E}"
    echo "    ${H2}subenum -o /path/to/results target.com${E}   ${DIM}# custom output folder${E}"
    echo "    ${H2}subenum -v target.com${E}                    ${DIM}# watch live tool output${E}"
    echo "    ${H2}subenum -q 5 target.com${E}                  ${DIM}# 5s between queries${E}"
    echo "    ${H2}subenum -p -l targets.txt${E}                ${DIM}# fast, parallel passives${E}"
    echo "    ${H2}TOOL_TIMEOUT=120 subenum -l targets.txt -o ./results${E}"
    echo "    ${H2}TOOL_DELAY=10 subenum target.com${E}   ${DIM}# 10s pause between tools${E}"
    echo "${E}"
    exit 0
}

case "$1" in
    -h|--help) usage ;;
esac

TARGET_LIST=""
RECON_ROOT_ARG=""
VERBOSE=0
SILENT=0
PARALLEL=0
QUERY_DELAY=""
POS_TARGETS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        -l|--list)
            if [ -z "$2" ]; then
                echo "Option $1 needs a file path argument." >&2
                usage
            elif [ ! -s "$2" ]; then
                echo "Target list file is empty or does not exist: $2" >&2
                exit 1
            elif [ ! -f "$2" ]; then
                echo "Target list is not a regular file: $2" >&2
                exit 1
            else
                TARGET_LIST="$(realpath "$2")"
                shift 2
            fi
            ;;
        -o|--output)
            if [ -z "$2" ]; then
                echo "Option $1 needs a directory path argument." >&2
                usage
            else
                RECON_ROOT_ARG="$2"
                shift 2
            fi
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -s|--silent)
            SILENT=1
            shift
            ;;
        -q|--query-delay)
            if [ -z "$2" ]; then
                echo "Option $1 needs a number of seconds." >&2
                usage
            else
                case "$2" in
                    ''|*[!0-9.]*)
                        echo "Query delay must be a number: $2" >&2
                        exit 1
                        ;;
                    *) QUERY_DELAY="$2"; shift 2 ;;
                esac
            fi
            ;;
        -p|--parallel)
            PARALLEL=1
            shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage
            ;;
        *)
            # positional target: keep going, flags may follow it
            POS_TARGETS+=("$1")
            shift
            ;;
    esac
done

if [ ${#POS_TARGETS[@]} -eq 0 ] && [ -z "$TARGET_LIST" ]; then
    echo "No target given. Use --help or --list for details." >&2
    usage
fi

# ----------------------------------------------------------------- config
# results always live next to the script (following symlinks), wherever you call it from
SELF_PATH="${BASH_SOURCE[0]}"
while [ -L "$SELF_PATH" ]; do
    SELF_PATH="$(readlink -f "$SELF_PATH")"
done
SCRIPT_DIR="$(cd "$(dirname "$SELF_PATH")" && pwd)"
RECON_ROOT="${SCRIPT_DIR}/recon"

# ----------------------------------------------------------------- rate config
# QUERY_DELAY (seconds between queries) translated to each tool's native option:
#   subfinder  : -rl N          (max HTTP requests/second, integer)
#   findomain  : --rate-limit S (seconds between queries - exact match)
#   puredns    : --rate-limit N (queries/second, integer)
#   amass v4   : NO rate option exists - warned below, only TOOL_DELAY applies
SUBFINDER_RATE=()
FINDOMAIN_RATE=()
PUREDNS_QPS=50
if [ -n "$QUERY_DELAY" ]; then
    qps=$(awk -v d="$QUERY_DELAY" 'BEGIN { q = 1 / d; if (q > 0) print int(q); else print 0 }')
    if [ "$qps" -ge 1 ]; then
        SUBFINDER_RATE=(-rl 1)
        PUREDNS_QPS="$qps"
    else
        warn "query-delay ${QUERY_DELAY}s is slower than 1 request/second -"
        warn "  subfinder (-rl) and puredns (--rate-limit) only accept whole requests/second;"
        warn "  they will be capped at 1 request/second which is the slowest supported"
        SUBFINDER_RATE=(-rl 1)
        PUREDNS_QPS=1
    fi
    FINDOMAIN_RATE=(--rate-limit "$QUERY_DELAY")
    warn "note: amass has no per-query rate option (v4) - only TOOL_DELAY applies to it"
fi
# tool flag policy:
#   default      -> each tool's own natural output (amass progress bar,
#                   subfinder/amass/findomain status lines all visible)
#   -s/--silent  -> suppress: tool silencing flags + drop tool stderr
#   -v/--verbose -> natural output + the tool's own verbose flag and diagnostics
if [ "$SILENT" -eq 1 ]; then
    SUBFINDER_FLAGS="-silent"
    AMASS_FLAGS="-silent"
    FINDOMAIN_FLAGS="-q"
elif [ "$VERBOSE" -eq 1 ]; then
    SUBFINDER_FLAGS="-v"
    AMASS_FLAGS=""
    FINDOMAIN_FLAGS="-v"
else
    SUBFINDER_FLAGS=""
    AMASS_FLAGS=""
    FINDOMAIN_FLAGS=""
fi

# -o/--output overrides the default results root
if [ -n "$RECON_ROOT_ARG" ]; then
    RECON_ROOT="$(realpath -m "$RECON_ROOT_ARG")"
fi
WORDLIST=""        # asked later, only needed for active phase
DATE_STAMP="$(date +%Y%m%d_%H%M%S)"
PUREDNS_RESOLVERS="${HOME}/.config/puredns/resolvers.txt"   # puredns default
RESOLVERS_OPT=""   # --resolvers argument, set only if the default file is missing
TOOL_TIMEOUT="${TOOL_TIMEOUT:-0}" # optional per-tool timeout in SECONDS. 0 = disabled (default).
TOOL_DELAY="${TOOL_DELAY:-0}"     # optional delay in SECONDS between tool calls. 0 = disabled.
                                  # use it to throttle API-key-hungry sources between tools

# sleep before each tool call (except the first of a run) when TOOL_DELAY > 0
before_tool() {
    local what="$1"
    if [ "${TOOL_DELAY:-0}" -gt 0 ]; then
        info "waiting ${TOOL_DELAY}s before ${what} (TOOL_DELAY - protecting API usage)"
        sleep "${TOOL_DELAY}"
    fi
}


# tool stderr passthrough policy:
#   default (-v or plain): stream tool stderr to the terminal (progress bars!)
#   -s/--silent: drop it
tool_err() {
    if [ "$SILENT" -eq 1 ]; then
        return 0
    fi
    cat >&2
}

# amass writes its progress-bar frames back-to-back with NO separator at all
# (no \r, no \n, no escapes): `0 / 1 [...] 0.00% ? p/s0 / 1 [...] 0.00% ? p/s`
# - verified on a pipe. Line-based read therefore never fires and dumps mud.
# amass_progress_filter reads fixed-size chunks, splits frames on the `p/s`
# boundary, keeps ONLY the latest frame and repaints it in place every
# AMASS_BAR_INTERVAL seconds (default 30) - one line, once, like native amass.
# Real diagnostics (warnings, API errors) pass through on their newlines.
amass_progress_filter() {
    if [ "${SILENT:-0}" -eq 1 ]; then
        return 0
    fi
    local interval="${AMASS_BAR_INTERVAL:-30}"
    local buf="" chunk="" frame txt diag t last="" first=1
    local start; start=$(date +%s)

    # drain all complete frames + newline-terminated messages from buf
    parse() {
        while :; do
            if [[ "$buf" != *p/s* ]]; then
                break                              # frame still incomplete
            fi
            frame="${buf%%p/s*}"                   # text before first p/s
            txt="${frame%%$'\n'*}"
            if [ "$txt" != "$frame" ]; then        # newline comes first ->
                diag="${buf%%$'\n'*}"              # plain message, show it
                buf="${buf#*$'\n'}"
                printf '%s\n' "$diag" >&2
                continue
            fi
            frame="${frame}p/s"                    # complete bar frame
            buf="${buf#*p/s}"
            last="$frame"
            t=$(date +%s)
            if [ "$first" -eq 1 ] || [ $((t - start)) -ge "$interval" ]; then
                printf '\r%s' "$frame" >&2         # in-place update, like amass
                start=$t
                first=0
            fi
        done
        while [[ "$buf" == *$'\n'* ]]; do          # leftover plain messages
            diag="${buf%%$'\n'*}"
            buf="${buf#*$'\n'}"
            printf '%s\n' "$diag" >&2
        done
    }

    # amass frames contain no \r/\n; read -d '' -n reads raw byte chunks
    while IFS= read -r -d '' -n 512 chunk; do
        buf+="$chunk"
        parse
    done
    buf+="$chunk"                                  # EOF remainder
    parse
    if [ -n "$last" ]; then
        printf '\r%s' "$last" >&2       # leave the final frame visible
    fi
}

# run_tool <cmd...>: executes cmd, optionally wrapped in `timeout` when
# TOOL_TIMEOUT > 0 and the `timeout` binary exists. Fine to wrap every tool invocation.
run_tool() {
    if [ "$TOOL_TIMEOUT" -gt 0 ] && have timeout; then
        timeout "$TOOL_TIMEOUT" "$@"
    else
        "$@"
    fi
}
# Words removed from tool output before saving (wildcard-style junk)
trim_line() { sed -E -e 's/^\*\.?//' <<< "$1"; }

# ------------------------------------------------------------- passive sources

passive_subfinder() {
    local target="$1" dir="$2"
    info "subfinder: enumerating ${target}"
    if run_tool subfinder -d "$target" -all ${SUBFINDER_FLAGS} "${SUBFINDER_RATE[@]}" 2> >(tool_err) | while read -r line; do trim_line "$line"; done | tee "${dir}/subfinder.txt" >/dev/null; then
        ok "subfinder: $(wc -l < "${dir}/subfinder.txt" 2>/dev/null || echo 0) subs"
        return 0
    else
        fail "subfinder failed on ${target}"; : > "${dir}/subfinder.txt"
        return 1
    fi
}

passive_amass() {
    local target="$1" dir="$2"
    local amass_ok=0
    info "amass enum: querying ${target} (this may take some time - wait for completion)"
    if run_tool amass enum -d "$target" ${AMASS_FLAGS} 2> >(amass_progress_filter) | while read -r line; do trim_line "$line"; done | tee "${dir}/amass_enum.txt" >/dev/null; then
        ok "amass enum: query completed"
        amass_ok=1
    else
        fail "amass enum failed on ${target}"; : > "${dir}/amass_enum.txt"
    fi
    info "amass subs: dumping collected subdomains for ${target}"
    if run_tool amass subs -names -d "$target" 2> >(tool_err) | while read -r line; do trim_line "$line"; done | tee "${dir}/amass_subs.txt" >/dev/null; then
        ok "amass subs: $(wc -l < "${dir}/amass_subs.txt" 2>/dev/null || echo 0) subs"
        amass_ok=1
    else
        warn "amass subs empty/failed for ${target}"; : > "${dir}/amass_subs.txt"
    fi
    return $((1 - amass_ok))
}

passive_assetfinder() {
    local target="$1" dir="$2"
    info "assetfinder: enumerating ${target}"
    if run_tool assetfinder --subs-only "$target" 2> >(tool_err) | while read -r line; do trim_line "$line"; done | tee "${dir}/assetfinder.txt" >/dev/null; then
        ok "assetfinder: $(wc -l < "${dir}/assetfinder.txt" 2>/dev/null || echo 0) subs"
        return 0
    else
        fail "assetfinder failed on ${target}"; : > "${dir}/assetfinder.txt"
        return 1
    fi
}

passive_findomain() {
    local target="$1" dir="$2"
    info "findomain: enumerating ${target}"
    if run_tool findomain -t "$target" ${FINDOMAIN_FLAGS} "${FINDOMAIN_RATE[@]}" 2> >(tool_err) | while read -r line; do trim_line "$line"; done | tee "${dir}/findomain.txt" >/dev/null; then
        ok "findomain: $(wc -l < "${dir}/findomain.txt" 2>/dev/null || echo 0) subs"
        return 0
    else
        fail "findomain failed on ${target}"; : > "${dir}/findomain.txt"
        return 1
    fi
}

passive_crtsh() {
    # No extra dependencies: uses curl (widely installed) against crt.sh
    local target="$1" dir="$2"
    if ! have curl; then
        warn "curl not found - crt.sh source skipped"
        return 1
    fi
    info "crt.sh: querying certificate transparency logs for ${target}"
    if run_tool curl -s --max-time 60 "https://crt.sh/?q=%25.${target}&output=json" 2> >(tool_err) \
        | tr '\n' ' ' \
        | grep -oP '"name_value":\s*"\K[^"]+' \
        | sed 's/\\n/\n/g' \
        | while read -r line; do trim_line "$line"; done \
        | grep -F ".$target" | sort -u | tee "${dir}/crtsh.txt" >/dev/null; then
        ok "crt.sh: $(wc -l < "${dir}/crtsh.txt" 2>/dev/null || echo 0) subs"
        return 0
    else
        fail "crt.sh failed or timed out for ${target}"; : > "${dir}/crtsh.txt"
        return 1
    fi
}

passive_hackertarget() {
    local target="$1" dir="$2"
    if ! have curl; then return 1; fi
    info "hackertarget: querying host search API for ${target}"
    if run_tool curl -s --max-time 60 "https://api.hackertarget.com/hostsearch/?q=${target}" 2> >(tool_err) \
        | cut -d',' -f1 | grep -F ".$target" | tee "${dir}/hackertarget.txt" >/dev/null; then
        ok "hackertarget: $(wc -l < "${dir}/hackertarget.txt" 2>/dev/null || echo 0) subs"
        return 0
    else
        warn "hackertarget empty/failed for ${target}"; : > "${dir}/hackertarget.txt"
        return 1
    fi
}

# ------------------------------------------------------------- active sources

active_puredns() {
    local target="$1" dir="$2" wordlist="$3"
    local bruteforce_ok=0
    info "puredns: bruteforcing ${target} (rate-limit ${PUREDNS_QPS}, rate-limit-trusted 50)"
    if run_tool puredns bruteforce "$wordlist" "$target" \
        --rate-limit "${PUREDNS_QPS}" -t 20 --rate-limit-trusted 50 $RESOLVERS_OPT 2> >(tool_err) \
        | while read -r line; do trim_line "$line"; done | tee "${dir}/puredns.txt" >/dev/null; then
        ok "puredns bruteforce: $(wc -l < "${dir}/puredns.txt" 2>/dev/null || echo 0) subs"
        bruteforce_ok=1
    else
        fail "puredns bruteforce failed on ${target}"
        : > "${dir}/puredns.txt"
    fi
    # NOTE: no resolve step - this tool is a SUBDOMAIN enumerator; validating
    # which subs actually resolve is a separate task (e.g. httpx/naabu).
    return $((1 - bruteforce_ok))
}

# ------------------------------------------------------------- helpers

ask_go_active() {
    if [ "$SILENT" -eq 0 ]; then
        echo
        echo "${BOLD}Passive enumeration finished for: ${RESET}"
        local i=1
        for t in "$@"; do
            echo "  ${i})  ${t}"
            i=$((i + 1))
        done
    fi
    echo
    local ans
    while true; do
        printf "%s" "${YELLOW}Go for ACTIVE enumeration? [yes/no]: ${RESET}"
        read -r ans || return 1
        case "$ans" in
            yes|y|Y|YES) return 0 ;;
            no|n|N|NO)   return 1 ;;
            *) warn "Please answer yes or no." ;;
        esac
    done
}

ask_wordlist() {
    local wl
    while true; do
        printf "%s" "${YELLOW}Path to DNS bruteforce wordlist (e.g. /usr/share/wordlists/dns/subdomains-top1million-5000.txt): ${RESET}"
        read -r wl || return 1
        if [ -z "$wl" ]; then
            warn "Wordlist path cannot be empty."
        elif [ ! -f "$wl" ]; then
            fail "File not found: ${wl}"
        else
            WORDLIST="$(realpath "$wl")"
            ok "Using wordlist: ${WORDLIST} ($(wc -l < "$WORDLIST") entries)"
            return 0
        fi
    done
}

# puredns resolvers handling:
# puredns expects a resolvers file. Its default is ~/.config/puredns/resolvers.txt;
# if that file does not exist, puredns fails or uses no resolvers. So the script
# checks it, and if it is missing asks the user for a custom resolvers file and
# passes it via --resolvers.
check_resolvers() {
    if [ -s "${PUREDNS_RESOLVERS}" ]; then
        ok "puredns resolvers found: ${PUREDNS_RESOLVERS} ($(wc -l < "${PUREDNS_RESOLVERS}") resolvers)"
        RESOLVERS_OPT=""
        return 0
    fi
    warn "Default resolvers file not found or empty: ${PUREDNS_RESOLVERS}"
    printf "%s" "${YELLOW}Path to your resolvers file (one resolver per line, e.g. 8.8.8.8): ${RESET}"
    local r
    read -r r || return 1
    if [ -z "$r" ] || [ ! -f "$r" ] || [ ! -s "$r" ]; then
        fail "No valid resolvers file provided - active enumeration may fail or find nothing."
        return 1
    fi
    RESOLVERS_OPT="--resolvers $(realpath "$r")"
    ok "Using custom resolvers: $(realpath "$r") ($(wc -l < "$r") resolvers)"
}

merge_final() {
    # merge + dedup, never delete older final files (new file is timestamped)
    local target="$1" root="$2"
    local final_dir="${root}/final"
    mkdir -p "$final_dir"
    local out="${final_dir}/${target}_subdomains_${DATE_STAMP}.txt"
    cat "${root}/passive"/*.txt "${root}/active"/*.txt 2>/dev/null \
        | grep -F ".$target" \
        | while read -r line; do trim_line "$line"; done \
        | sed -e 's/^\.\+//' -e 's/\.\+$//' \
        | grep -E '^[a-zA-Z0-9_*-]+(\.[a-zA-Z0-9_*-]+)+$' \
        | grep -F ".$target" \
        | sort -u > "$out"
    local count
    count=$(wc -l < "$out")
    ok "Merged + deduped ${target}: ${count} unique subs -> ${out}" >&2
    echo "${out}"
}

# ------------------------------------------------------------- main flow

banner

# ----------------------------------------------------------------- targets
# build the target list: OPT-IN list file first (--list), then positional args
RAW_TARGETS=()
if [ -n "$TARGET_LIST" ]; then
    info "Loading targets from list: ${TARGET_LIST}"
    while IFS= read -r raw_t || [ -n "$raw_t" ]; do
        # strip leading/trailing whitespace and inline comments
        t="$(echo "$raw_t" | sed -e 's/[[:space:]]*\(#.*\)\?$//' -e 's/[[:space:]]//g')"
        [ -z "$t" ] && continue
        RAW_TARGETS+=("$t")
    done < "$TARGET_LIST"
    ok "Loaded $((${#RAW_TARGETS[@]} + 0)) targets from ${TARGET_LIST}"
fi
for t in "${POS_TARGETS[@]}"; do
    RAW_TARGETS+=("$t")
done

if [ ${#RAW_TARGETS[@]} -eq 0 ]; then
    fail "No targets provided."
    exit 1
fi

# validate all targets first - refuse to proceed on bad input
VALID_TARGETS=()
for t in "${RAW_TARGETS[@]}"; do
    if ! echo "$t" | grep -Eiq '^([a-zA-Z0-9_-]+\.)+[a-zA-Z]{2,}$'; then
        fail "Not a valid domain, skipping: ${t}"
        continue
    fi
    VALID_TARGETS+=("$t")
done

if [ ${#VALID_TARGETS[@]} -eq 0 ]; then
    fail "No valid targets provided."
    exit 1
fi

echo "${BOLD}Targets (${#VALID_TARGETS[@]}):${RESET}"
for t in "${VALID_TARGETS[@]}"; do echo "  ${BLUE}- ${t}${RESET}"; done
echo

info "Checking available tools ..."
HAVE_SUBFINDER=1;     check_tool subfinder     || HAVE_SUBFINDER=0
HAVE_AMASS=1;         check_tool amass         || HAVE_AMASS=0
HAVE_ASSETFINDER=1;   check_tool assetfinder   || HAVE_ASSETFINDER=0
HAVE_FINDOMAIN=1;     check_tool findomain     || HAVE_FINDOMAIN=0
HAVE_CURL=1;          check_tool curl          || HAVE_CURL=0
HAVE_PUREDNS=1;       check_tool puredns       || HAVE_PUREDNS=0

encourage_missing() {
    if [ "$HAVE_SUBFINDER$HAVE_AMASS$HAVE_ASSETFINDER$HAVE_FINDOMAIN$HAVE_CURL$HAVE_PUREDNS" != "111111" ]; then
        warn "Missing tools reduce coverage. Install: amass, subfinder, assetfinder, findomain, puredns"
    fi
}

# Ask active decision only once, after passives for ALL targets are done
results=()
for target in "${VALID_TARGETS[@]}"; do
    if [ "$SILENT" -eq 0 ]; then
        echo
        echo "${CYAN}${BOLD}--------------------------------------------------------------"
        echo "  [ PHASE 1 ]  PASSIVE ENUMERATION : ${target}"
        echo "--------------------------------------------------------------${RESET}"
    fi

    root="${RECON_ROOT}/${target}"
    mkdir -p "${root}/passive" "${root}/active" "${root}/final"

    if [ "$PARALLEL" -eq 1 ]; then
        # all passive tools in background simultaneously (TOOL_DELAY can't be
        # honored between tools in this mode - it still applies between targets)
        info "parallel mode: all passive sources run simultaneously"
        pids=()
        [ "$HAVE_SUBFINDER"   -eq 1 ] && { passive_subfinder   "$target" "${root}/passive" & pids+=($!); }
        [ "$HAVE_AMASS"       -eq 1 ] && { passive_amass       "$target" "${root}/passive" & pids+=($!); }
        [ "$HAVE_ASSETFINDER" -eq 1 ] && { passive_assetfinder "$target" "${root}/passive" & pids+=($!); }
        [ "$HAVE_FINDOMAIN"   -eq 1 ] && { passive_findomain   "$target" "${root}/passive" & pids+=($!); }
        [ "$HAVE_CURL"        -eq 1 ] && { passive_crtsh       "$target" "${root}/passive" & pids+=($!); }
        [ "$HAVE_CURL"        -eq 1 ] && { passive_hackertarget "$target" "${root}/passive" & pids+=($!); }
        for pid in "${pids[@]}"; do wait "$pid" || true; done
    else
        [ "$HAVE_SUBFINDER"   -eq 1 ] && before_tool "subfinder"   && passive_subfinder   "$target" "${root}/passive"
        [ "$HAVE_AMASS"       -eq 1 ] && before_tool "amass"       && passive_amass       "$target" "${root}/passive"
        [ "$HAVE_ASSETFINDER" -eq 1 ] && before_tool "assetfinder" && passive_assetfinder "$target" "${root}/passive"
        [ "$HAVE_FINDOMAIN"   -eq 1 ] && before_tool "findomain"   && passive_findomain   "$target" "${root}/passive"
        if [ "$HAVE_CURL" -eq 1 ]; then
            before_tool "crt.sh"         && passive_crtsh       "$target" "${root}/passive"
            before_tool "hackertarget"   && passive_hackertarget "$target" "${root}/passive"
        fi
    fi
    merged="$(merge_final "$target" "$root")"
    results+=("${target}|${root}|${merged}")

    if [ "$SILENT" -eq 0 ]; then
        echo
        echo "${BOLD}  Passive summary for ${target}: ${RESET}"
        for f in "${root}/passive"/*.txt; do
            [ -e "$f" ] || continue
            printf "    %-22s %6d subs\n" "$(basename "$f" .txt)" "$(wc -l < "$f")"
        done
        printf "    %-22s %6d subs (merged+deduped)\n" "FINAL" "$(wc -l < "$merged")"
    fi
done

encourage_missing

# ------------------------------------------------------- user decision point
if ask_go_active "${VALID_TARGETS[@]}"; then
    if [ "$SILENT" -eq 0 ]; then
        echo
        echo "${CYAN}${BOLD}--------------------------------------------------------------"
        echo "  [ PHASE 2 ]  ACTIVE ENUMERATION"
        echo "--------------------------------------------------------------${RESET}"
    fi

    if [ "$HAVE_PUREDNS" -eq 0 ]; then
        fail "puredns is not installed - active enumeration cannot proceed."
        exit 1
    fi
    check_resolvers
    ask_wordlist

    for entry in "${results[@]}"; do
        IFS='|' read -r target root merged <<< "$entry"
        echo
        echo "${CYAN}${BOLD}  >> Active on: ${target}${RESET}"
        before_tool "puredns (active)" && active_puredns "$target" "${root}/active" "$WORDLIST"
        # re-merge so the final file always includes active results
        merged="$(merge_final "$target" "$root")"
        ok "Updated final for ${target}: [$merged]"
    done
else
    echo
    info "Active enumeration skipped by user."
fi

# ------------------------------------------------------- final report
echo
echo "${CYAN}${BOLD}=============================================================="
echo "  FINAL REPORT"
echo "==============================================================${RESET}"
for entry in "${results[@]}"; do
    IFS='|' read -r target root merged <<< "$entry"
    echo "${BOLD}  ${target}${RESET}"
    for f in "${root}/passive"/*.txt "${root}/active"/*.txt; do
        [ -e "$f" ] || continue
        printf "    %-22s %6d subs\n" "$(basename "$f" .txt)" "$(wc -l < "$f")"
    done
    if [ -e "${root}/final" ]; then
        for f in "${root}/final"/*; do
            [ -e "$f" ] || continue
            printf "    %-22s ${GREEN}%6d subs${RESET}  <- merged\n" "$(basename "$f")" "$(wc -l < "$f")"
        done
    fi
done

echo
echo "${BOLD}Structure:${RESET}   ${RECON_ROOT}/<target>/{passive,active,final}/  (all raw data preserved)"
echo
ok "Done."
