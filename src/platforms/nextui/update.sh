#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Continuity OTA Update — pull latest PAK from GitHub
# Uses curl + GitHub API to download and extract new PAK version.
# Preserves local state (.continuity/ directory is separate from PAK).
set -e

PAK_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTINUITY_HOME="/mnt/SDCARD/.continuity"
UPDATE_LOG="$CONTINUITY_HOME/update.log"
UPDATE_TMP="$CONTINUITY_HOME/update_tmp"

# ── Configuration ────────────────────────────────────────────────────
# These are set during build or can be overridden.
CONTINUITY_UPDATE_REPO="${CONTINUITY_UPDATE_REPO:-jreinach-alt/ideal_os}"
CONTINUITY_UPDATE_BRANCH="${CONTINUITY_UPDATE_BRANCH:-main}"

# Where to fetch the PAK archive from.
# Option A: GitHub Release asset (production)
# Option B: Raw files from a branch (development)
CONTINUITY_UPDATE_MODE="${CONTINUITY_UPDATE_MODE:-branch}"

# ── Logging ──────────────────────────────────────────────────────────

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$UPDATE_LOG" 2>/dev/null
    printf '%s\n' "$1" >&2
}

# ── Utilities ────────────────────────────────────────────────────────

# check_online — verify network connectivity
check_online() {
    ping -c 1 -W 3 github.com >/dev/null 2>&1 ||
    wget --spider -q -T 3 https://github.com 2>/dev/null
}

# get_current_version — read local version
get_current_version() {
    if [ -f "$PAK_DIR/version.txt" ]; then
        cat "$PAK_DIR/version.txt"
    else
        printf 'unknown\n'
    fi
}

# ── Branch Mode (Development) ────────────────────────────────────────
# Downloads a tarball of the repo branch and extracts PAK files from it.

update_from_branch() {
    local archive_url archive_file extract_dir
    archive_url="https://github.com/${CONTINUITY_UPDATE_REPO}/archive/refs/heads/${CONTINUITY_UPDATE_BRANCH}.tar.gz"

    log "Downloading from branch: $CONTINUITY_UPDATE_BRANCH"

    rm -rf "$UPDATE_TMP"
    mkdir -p "$UPDATE_TMP"
    archive_file="$UPDATE_TMP/repo.tar.gz"

    # Download
    if ! curl -fSL --retry 3 -o "$archive_file" "$archive_url" 2>>"$UPDATE_LOG"; then
        log "ERROR: Download failed"
        rm -rf "$UPDATE_TMP"
        return 1
    fi

    # Extract
    extract_dir="$UPDATE_TMP/extracted"
    mkdir -p "$extract_dir"
    tar xzf "$archive_file" -C "$extract_dir"

    # Find the repo root in the extracted archive
    local repo_root
    repo_root=$(find "$extract_dir" -maxdepth 1 -type d | tail -1)

    # Verify expected structure exists
    if [ ! -d "$repo_root/src/platforms/nextui" ]; then
        log "ERROR: Expected repo structure not found"
        rm -rf "$UPDATE_TMP"
        return 1
    fi

    # Update scripts (core + platform)
    log "Updating scripts..."

    # Core modules
    mkdir -p "$PAK_DIR/scripts/core"
    for f in "$repo_root"/src/core/*.sh; do
        [ -f "$f" ] && cp "$f" "$PAK_DIR/scripts/core/"
    done

    # Platform scripts
    for f in pal_nextui.sh enroll_sd_card.sh enroll_ui.sh preflight.sh continuity_daemon.sh update.sh; do
        if [ -f "$repo_root/src/platforms/nextui/$f" ]; then
            cp "$repo_root/src/platforms/nextui/$f" "$PAK_DIR/scripts/"
        fi
    done

    # launch.sh goes to PAK root
    if [ -f "$repo_root/src/platforms/nextui/launch.sh" ]; then
        cp "$repo_root/src/platforms/nextui/launch.sh" "$PAK_DIR/launch.sh"
    fi

    # Config
    if [ -f "$repo_root/config/platform_maps/nextui.json" ]; then
        mkdir -p "$PAK_DIR/config/platform_maps"
        cp "$repo_root/config/platform_maps/nextui.json" "$PAK_DIR/config/platform_maps/"
    fi

    # Make everything executable
    find "$PAK_DIR" -name "*.sh" -exec chmod +x {} +
    [ -f "$PAK_DIR/bin/git" ] && chmod +x "$PAK_DIR/bin/git"

    # Write version
    local new_version
    new_version="branch-${CONTINUITY_UPDATE_BRANCH}-$(date '+%Y%m%d-%H%M%S')"
    printf '%s\n' "$new_version" > "$PAK_DIR/version.txt"

    log "Update complete: $new_version"

    # Cleanup
    rm -rf "$UPDATE_TMP"
    return 0
}

# ── Release Mode (Production) ────────────────────────────────────────
# Downloads a pre-built PAK archive from GitHub Releases.

update_from_release() {
    log "Checking for latest release..."

    local api_url latest_tag current_version
    api_url="https://api.github.com/repos/${CONTINUITY_UPDATE_REPO}/releases/latest"
    current_version=$(get_current_version)

    # Get latest release info
    local release_info
    release_info=$(curl -fsSL "$api_url" 2>>"$UPDATE_LOG") || {
        log "ERROR: Failed to fetch release info"
        return 1
    }

    # Parse tag name (simple sed — no jq on BusyBox)
    latest_tag=$(printf '%s' "$release_info" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

    if [ -z "$latest_tag" ]; then
        log "ERROR: Could not parse release tag"
        return 1
    fi

    if [ "$latest_tag" = "$current_version" ]; then
        log "Already up to date: $current_version"
        return 0
    fi

    log "New version available: $latest_tag (current: $current_version)"

    # Find Continuity.pak.tar.gz asset
    local asset_url
    asset_url=$(printf '%s' "$release_info" | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*Continuity\.pak\.tar\.gz[^"]*\)".*/\1/p' | head -1)

    if [ -z "$asset_url" ]; then
        log "ERROR: No Continuity.pak.tar.gz asset in release"
        return 1
    fi

    # Download and extract
    rm -rf "$UPDATE_TMP"
    mkdir -p "$UPDATE_TMP"

    log "Downloading: $asset_url"
    if ! curl -fSL --retry 3 -o "$UPDATE_TMP/pak.tar.gz" "$asset_url" 2>>"$UPDATE_LOG"; then
        log "ERROR: Download failed"
        rm -rf "$UPDATE_TMP"
        return 1
    fi

    # Preserve git binary (don't overwrite with potentially missing binary)
    local git_backup
    if [ -f "$PAK_DIR/bin/git" ]; then
        git_backup="$UPDATE_TMP/git.backup"
        cp "$PAK_DIR/bin/git" "$git_backup"
    fi

    # Extract over existing PAK
    tar xzf "$UPDATE_TMP/pak.tar.gz" -C "$(dirname "$PAK_DIR")"

    # Restore git binary if it was lost
    if [ -n "$git_backup" ] && [ ! -f "$PAK_DIR/bin/git" ]; then
        mkdir -p "$PAK_DIR/bin"
        cp "$git_backup" "$PAK_DIR/bin/git"
    fi

    # Make everything executable
    find "$PAK_DIR" -name "*.sh" -exec chmod +x {} +
    [ -f "$PAK_DIR/bin/git" ] && chmod +x "$PAK_DIR/bin/git"

    # Write version
    printf '%s\n' "$latest_tag" > "$PAK_DIR/version.txt"

    log "Update complete: $latest_tag"
    rm -rf "$UPDATE_TMP"
    return 0
}

# ── Main ─────────────────────────────────────────────────────────────

mkdir -p "$CONTINUITY_HOME"

log "OTA update starting (mode: $CONTINUITY_UPDATE_MODE)"

if ! check_online; then
    log "ERROR: No network connectivity"
    exit 1
fi

case "$CONTINUITY_UPDATE_MODE" in
    branch)
        update_from_branch
        ;;
    release)
        update_from_release
        ;;
    *)
        log "ERROR: Unknown update mode: $CONTINUITY_UPDATE_MODE"
        exit 1
        ;;
esac
