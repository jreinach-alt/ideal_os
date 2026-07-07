#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Continuity OTA update — sync the PAK from the project repo using the
# PAK's own bundled git. No curl, no tarballs, no system tools beyond
# BusyBox: the update mechanism is the same proven git+TLS stack that
# enrollment uses.
#
# Design:
#   - A persistent shallow clone lives at $CONTINUITY_HOME/ota-repo,
#     sparse-checked-out to just build/Continuity.pak (with a partial
#     clone filter when the server supports it), so update checks and
#     downloads are incremental — unchanged binaries are never refetched.
#   - The update channel (branch) is read from ota_channel.txt in the
#     PAK, written at build time from the branch the build came from.
#   - Apply is staged: fetch → verify the fetched tree (CRLF scan +
#     checksums.txt) → copy over the live PAK → sync. The daemon reads
#     its scripts at boot, so replacing files mid-run takes effect on
#     the next reboot.
#
# Functions are ota_-prefixed and individually testable; overridables:
#   CONTINUITY_OTA_URL     — repo URL (default: the public project repo)
#   CONTINUITY_OTA_BRANCH  — channel override (default: ota_channel.txt)
#   CONTINUITY_HOME        — state root (default: /mnt/SDCARD/.continuity)

OTA_PAK_DIR="${CONTINUITY_PAK_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
OTA_HOME="${CONTINUITY_HOME:-/mnt/SDCARD/.continuity}"
OTA_REPO="$OTA_HOME/ota-repo"
OTA_LOG="$OTA_HOME/update.log"
OTA_URL="${CONTINUITY_OTA_URL:-https://github.com/jreinach-alt/ideal_os}"
OTA_GIT="${CONTINUITY_GIT_BIN:-$OTA_PAK_DIR/bin/git}"

ota_log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$OTA_LOG" 2>/dev/null
}

# ota_channel — the branch this build tracks
ota_channel() {
    if [ -n "$CONTINUITY_OTA_BRANCH" ]; then
        printf '%s\n' "$CONTINUITY_OTA_BRANCH"
    elif [ -s "$OTA_PAK_DIR/ota_channel.txt" ]; then
        cat "$OTA_PAK_DIR/ota_channel.txt"
    else
        printf 'main\n'
    fi
}

# ota_git — run the bundled git with hang-proof transport settings
ota_git() {
    GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=60 \
        "$OTA_GIT" "$@"
}

# ota_ensure_repo — create or reuse the persistent sparse OTA clone.
# Returns: 0 ready, 1 failure (logged)
ota_ensure_repo() {
    local branch
    branch=$(ota_channel)
    mkdir -p "$OTA_HOME"

    if [ -d "$OTA_REPO/.git" ]; then
        return 0
    fi

    ota_log "Setting up OTA clone (channel: $branch)"
    rm -rf "$OTA_REPO"
    mkdir -p "$OTA_REPO"

    # Partial clone keeps the first setup small (only the PAK's blobs are
    # fetched at checkout). Some servers (and file:// test remotes without
    # uploadpack.allowFilter) reject filters — fall back to a plain
    # shallow clone.
    if ! ota_git clone --depth 1 --branch "$branch" --no-checkout \
            --filter=blob:none "$OTA_URL" "$OTA_REPO" >>"$OTA_LOG" 2>&1; then
        ota_log "Filtered clone refused — falling back to plain shallow clone"
        rm -rf "$OTA_REPO"
        if ! ota_git clone --depth 1 --branch "$branch" --no-checkout \
                "$OTA_URL" "$OTA_REPO" >>"$OTA_LOG" 2>&1; then
            ota_log "ERROR: OTA clone failed"
            rm -rf "$OTA_REPO"
            return 1
        fi
    fi

    if ! ota_git -C "$OTA_REPO" sparse-checkout set build/Continuity.pak >>"$OTA_LOG" 2>&1; then
        ota_log "ERROR: sparse-checkout failed"
        rm -rf "$OTA_REPO"
        return 1
    fi
    return 0
}

# ota_check — fetch the channel head; print "<new_version> <commit>" and
# return 0 when an update is available, 1 when up to date / unavailable.
ota_check() {
    local branch head cur_commit new_version
    branch=$(ota_channel)

    ota_ensure_repo || return 1

    if ! ota_git -C "$OTA_REPO" fetch --depth 1 origin "$branch" >>"$OTA_LOG" 2>&1; then
        ota_log "ERROR: OTA fetch failed"
        return 1
    fi

    head=$(ota_git -C "$OTA_REPO" rev-parse FETCH_HEAD 2>>"$OTA_LOG")
    [ -n "$head" ] || return 1

    cur_commit=$(cat "$OTA_HOME/.ota_commit" 2>/dev/null)
    if [ "$head" = "$cur_commit" ]; then
        ota_log "Up to date at $head"
        return 1
    fi

    # Materialize the fetched tree to read its version stamp
    ota_git -C "$OTA_REPO" checkout -f "$head" >>"$OTA_LOG" 2>&1 || return 1
    new_version=$(cat "$OTA_REPO/build/Continuity.pak/version.txt" 2>/dev/null)
    new_version="${new_version:-unknown}"

    # Version parity: a card-swapped deploy never wrote .ota_commit, so
    # commit comparison alone re-offers the build the user already has.
    # If the PAK's own version matches the fetched one, adopt the commit
    # as current and report up to date. (Field-found by the user.)
    if [ "$new_version" = "$(cat "$OTA_PAK_DIR/version.txt" 2>/dev/null)" ]; then
        printf '%s\n' "$head" > "$OTA_HOME/.ota_commit"
        ota_log "Deployed build $new_version already matches $head — adopting"
        return 1
    fi

    ota_log "Update available: $new_version ($head)"
    printf '%s %s\n' "$new_version" "$head"
    return 0
}

# ota_verify_tree — sanity-check a fetched PAK tree before applying.
# CRLF scan on scripts + checksum manifest verification of binaries.
ota_verify_tree() {
    local tree cr bad sum size path actual
    tree="$1"
    cr=$(printf '\r')

    [ -f "$tree/launch.sh" ] || { ota_log "ERROR: fetched tree has no launch.sh"; return 1; }

    bad=$(grep -rl "$cr" "$tree/scripts" "$tree/launch.sh" 2>/dev/null | head -1)
    if [ -n "$bad" ]; then
        ota_log "ERROR: fetched tree has CRLF corruption: $bad"
        return 1
    fi

    if [ -f "$tree/checksums.txt" ]; then
        while IFS=' ' read -r sum size path; do
            [ -n "$path" ] || continue
            actual=$(cat "$tree/$path" 2>/dev/null | wc -c)
            if [ "$actual" != "$size" ]; then
                ota_log "ERROR: fetched $path size $actual != $size"
                return 1
            fi
            if command -v sha256sum >/dev/null 2>&1; then
                if [ "$(sha256sum "$tree/$path" 2>/dev/null | cut -d' ' -f1)" != "$sum" ]; then
                    ota_log "ERROR: fetched $path checksum mismatch"
                    return 1
                fi
            fi
        done < "$tree/checksums.txt"
    fi
    return 0
}

# ota_apply — copy the verified fetched PAK over the live one.
# The daemon picks up changes on next boot. Returns 0 on success.
ota_apply() {
    local commit tree new_version
    commit="$1"
    tree="$OTA_REPO/build/Continuity.pak"

    ota_verify_tree "$tree" || return 1

    ota_log "Applying update $commit"

    # Scripts, config, manifests first; binaries after (largest last so
    # an interrupted copy is most likely to leave scripts consistent —
    # and preflight's checksum verification catches a torn binary).
    cp "$tree/launch.sh" "$OTA_PAK_DIR/launch.sh" || return 1
    mkdir -p "$OTA_PAK_DIR/scripts/core" "$OTA_PAK_DIR/config/platform_maps" \
             "$OTA_PAK_DIR/share/templates" "$OTA_PAK_DIR/libexec/git-core" "$OTA_PAK_DIR/bin"
    cp "$tree"/scripts/*.sh "$OTA_PAK_DIR/scripts/" || return 1
    cp "$tree"/scripts/core/*.sh "$OTA_PAK_DIR/scripts/core/" || return 1
    cp "$tree"/config/platform_maps/*.json "$OTA_PAK_DIR/config/platform_maps/" 2>/dev/null
    cp "$tree/config/system_taxonomy.json" "$OTA_PAK_DIR/config/" 2>/dev/null
    cp "$tree/version.txt" "$OTA_PAK_DIR/version.txt" 2>/dev/null
    cp "$tree/checksums.txt" "$OTA_PAK_DIR/checksums.txt" 2>/dev/null
    cp "$tree/ota_channel.txt" "$OTA_PAK_DIR/ota_channel.txt" 2>/dev/null

    # Binaries: only rewrite ones whose size differs (cheap change probe;
    # rewriting 20+ MB over SD for identical bytes wears the card and
    # widens the interruption window for nothing).
    for b in bin/git libexec/git-core/git libexec/git-core/git-remote-https \
             libexec/git-core/git-remote-http share/ca-bundle.crt; do
        if [ -f "$tree/$b" ]; then
            if [ "$(cat "$tree/$b" 2>/dev/null | wc -c)" != "$(cat "$OTA_PAK_DIR/$b" 2>/dev/null | wc -c)" ]; then
                ota_log "Updating binary: $b"
                cp "$tree/$b" "$OTA_PAK_DIR/$b" || return 1
            fi
        fi
    done

    find "$OTA_PAK_DIR" -name "*.sh" -exec chmod +x {} +
    chmod +x "$OTA_PAK_DIR/bin/git" "$OTA_PAK_DIR"/libexec/git-core/* 2>/dev/null

    printf '%s\n' "$commit" > "$OTA_HOME/.ota_commit"
    sync

    new_version=$(cat "$OTA_PAK_DIR/version.txt" 2>/dev/null)
    ota_log "Update applied: ${new_version:-unknown} ($commit)"
    return 0
}

# ota_run — check and apply in one call (used by scripted/manual flows).
# Returns: 0 updated, 1 no update, 2 failure.
ota_run() {
    local info commit
    mkdir -p "$OTA_HOME"
    info=$(ota_check) || return 1
    commit="${info##* }"
    ota_apply "$commit" || return 2
    return 0
}
