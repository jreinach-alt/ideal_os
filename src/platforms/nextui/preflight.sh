#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Continuity — preflight doctor.
#
# One run captures every environment fact that past debugging rounds each
# needed a separate SD-card round-trip to discover: build identity, device
# clock sanity (a wrong clock breaks TLS), module line endings, the git
# binary AND its https helper AND its CA bundle, network reachability, a
# real unauthenticated TLS handshake with GitHub, setup.json shape (PAT
# never logged), button device, free space.
#
# The full report is written to a caller-chosen file (launch.sh puts it at
# the SD card root as CONTINUITY_DIAGNOSTIC.txt — visible on any OS) and
# the first fatal failure is available in $_pf_first_fail for the screen.
#
# Overridables for tests:
#   PF_YEAR          — current year (default: date +%Y)
#   PF_LSREMOTE_URL  — public repo for the network probe
#                      (default: this project's public GitHub repo)

PF_LSREMOTE_URL="${PF_LSREMOTE_URL:-https://github.com/jreinach-alt/ideal_os}"

_pf_report=""
_pf_first_fail=""
_pf_failed=0

# pf_emit <ok|FAIL|warn|info> <check-name> <detail>
pf_emit() {
    local status name detail
    status="$1"; name="$2"; detail="$3"
    printf '%-4s %-14s %s\n' "$status" "$name" "$detail" >> "$_pf_report"
    if [ "$status" = "FAIL" ]; then
        _pf_failed=1
        if [ -z "$_pf_first_fail" ]; then
            _pf_first_fail="$name: $detail"
        fi
    fi
}

pf_check_build() {
    local v
    v=$(cat "$CONTINUITY_PAK_DIR/version.txt" 2>/dev/null)
    pf_emit "info" "build" "${v:-unknown} at $CONTINUITY_PAK_DIR"
}

pf_check_clock() {
    local year
    year="${PF_YEAR:-$(date '+%Y')}"
    if [ "$year" -ge 2025 ] 2>/dev/null; then
        pf_emit "ok" "clock" "$(date '+%Y-%m-%d %H:%M:%S')"
    else
        pf_emit "FAIL" "clock" "device clock shows $(date '+%Y-%m-%d') — TLS will reject certificates; connect WiFi so NTP can set the time, then retry"
    fi
}

pf_check_modules() {
    local cr bad
    cr=$(printf '\r')
    bad=$(grep -rl "$cr" "$CONTINUITY_PAK_DIR/scripts" "$CONTINUITY_PAK_DIR/launch.sh" 2>/dev/null | head -3)
    if [ -n "$bad" ]; then
        pf_emit "FAIL" "line-endings" "CRLF in: $(printf '%s' "$bad" | tr '\n' ' ')"
    else
        pf_emit "ok" "line-endings" "all modules LF-clean"
    fi
}

pf_check_git_binary() {
    local v resolved
    # Bare command names (test sandboxes use the system git) resolve via
    # PATH; on the device this is always the PAK's absolute path.
    case "$CONTINUITY_GIT_BIN" in
        */*) resolved="$CONTINUITY_GIT_BIN" ;;
        *)   resolved=$(command -v "$CONTINUITY_GIT_BIN" 2>/dev/null) ;;
    esac
    if [ -z "$resolved" ] || [ ! -x "$resolved" ]; then
        pf_emit "FAIL" "git-binary" "missing or not executable: $CONTINUITY_GIT_BIN"
        return 0
    fi
    v=$("$CONTINUITY_GIT_BIN" --version 2>&1 | head -1)
    if [ -n "$v" ]; then
        pf_emit "ok" "git-binary" "$v"
    else
        pf_emit "FAIL" "git-binary" "present but produced no output — wrong architecture?"
    fi
}

pf_check_https_helper() {
    if [ -x "$CONTINUITY_PAK_DIR/libexec/git-core/git-remote-https" ]; then
        pf_emit "ok" "https-helper" "libexec/git-core/git-remote-https"
    else
        pf_emit "FAIL" "https-helper" "git-remote-https missing — git cannot speak https"
    fi
}

pf_check_ca_bundle() {
    if [ -s "$CONTINUITY_PAK_DIR/share/ca-bundle.crt" ]; then
        pf_emit "ok" "ca-bundle" "share/ca-bundle.crt present"
    else
        pf_emit "FAIL" "ca-bundle" "share/ca-bundle.crt missing — TLS verification will fail"
    fi
}

pf_check_network() {
    if pal_is_online; then
        pf_emit "ok" "network" "online"
        return 0
    fi
    pf_emit "FAIL" "network" "offline — connect WiFi in NextUI settings, then retry"
    return 1
}

# Real end-to-end probe: DNS + TCP + TLS + CA + clock + https helper in
# one shot, no credentials involved. Only meaningful if network is up.
pf_check_github_tls() {
    local out
    out=$(GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=20 \
          "$CONTINUITY_GIT_BIN" ls-remote "$PF_LSREMOTE_URL" HEAD 2>&1 | head -2)
    case "$out" in
        *[0-9a-f]*HEAD*)
            pf_emit "ok" "github-tls" "unauthenticated ls-remote succeeded"
            ;;
        *)
            pf_emit "FAIL" "github-tls" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
            ;;
    esac
}

pf_check_setup_json() {
    local f url name pat
    f="$CONTINUITY_SD_ROOT/setup.json"
    if [ ! -f "$f" ]; then
        pf_emit "info" "setup-json" "absent"
        return 0
    fi
    url=$(sed -n 's/^[[:space:]]*"repo_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f")
    name=$(sed -n 's/^[[:space:]]*"device_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f")
    pat=$(sed -n 's/^[[:space:]]*"pat"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f")
    if [ -n "$url" ] && [ -n "$name" ] && [ -n "$pat" ]; then
        pf_emit "ok" "setup-json" "repo=$url device=$name pat=present(${#pat} chars)"
    else
        pf_emit "FAIL" "setup-json" "unparseable — need repo_url, device_name, pat (url:'${url:-?}' device:'${name:-?}' pat:$([ -n "$pat" ] && printf 'present' || printf 'MISSING'))"
    fi
}

pf_check_buttons() {
    if [ -r "${EUI_JS_DEV:-/dev/input/js0}" ]; then
        pf_emit "ok" "buttons" "joystick device present"
    else
        pf_emit "warn" "buttons" "no ${EUI_JS_DEV:-/dev/input/js0} — B/X/Y disabled, watchdog still active"
    fi
}

pf_check_space() {
    local free_kb
    free_kb=$(df -k "$CONTINUITY_SD_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$free_kb" ] && [ "$free_kb" -lt 51200 ] 2>/dev/null; then
        pf_emit "warn" "space" "only $((free_kb / 1024)) MB free on SD card"
    else
        pf_emit "ok" "space" "${free_kb:-unknown} KB free"
    fi
}

# pf_run — run every check, write the report.
# Usage: pf_run <report_file>
# Returns: 0 if no fatal check failed, 1 otherwise.
pf_run() {
    _pf_report="$1"
    _pf_first_fail=""
    _pf_failed=0

    {
        printf '=== Continuity preflight %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$_pf_report"

    pf_check_build
    pf_check_clock
    pf_check_modules
    pf_check_git_binary
    pf_check_https_helper
    pf_check_ca_bundle
    if pf_check_network; then
        pf_check_github_tls
    else
        pf_emit "info" "github-tls" "skipped (offline)"
    fi
    pf_check_setup_json
    pf_check_buttons
    pf_check_space

    printf '=== preflight %s ===\n' "$([ "$_pf_failed" -eq 0 ] && printf 'PASSED' || printf 'FAILED')" >> "$_pf_report"
    sync
    return "$_pf_failed"
}
