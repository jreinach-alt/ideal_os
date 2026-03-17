#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Change Detector — file enumeration helpers for Continuity sync flows
# Provides functions to list .srm files in the repo, on the device, and
# to detect changes in the repo working tree via git status.
# Requires the PAL and path mapper to be loaded before this file is sourced.

# cd_detect_changes — list .srm files changed in the repo working tree
# Usage: cd_detect_changes <repo_dir>
# Prints repo-relative paths of changed .srm files, one per line.
# Returns 0 always (empty output means no changes).
cd_detect_changes() {
    local repo_dir
    repo_dir="$1"

    "$CONTINUITY_GIT_BIN" -C "$repo_dir" status --porcelain -uall 2>/dev/null | \
        sed 's/^...//' | \
        grep '\.srm$' || true
    return 0
}

# cd_list_repo_saves — list all .srm files in the repo working tree
# Usage: cd_list_repo_saves <repo_dir>
# Prints repo-relative paths, one per line. Excludes .git/ and .continuity/.
# Returns 0 always (empty output means no .srm files).
cd_list_repo_saves() {
    local repo_dir
    repo_dir="$1"

    find "$repo_dir" -name "*.srm" \
        ! -path "*/.git/*" \
        ! -path "*/.continuity/*" 2>/dev/null | \
    while IFS= read -r abs_path; do
        printf '%s\n' "$abs_path" | sed "s|^$repo_dir/||"
    done
    return 0
}

# cd_list_device_saves — list all .srm files on the device
# Usage: cd_list_device_saves
# Prints absolute paths, one per line. Silently skips nonexistent dirs.
# Returns 0 always (empty output means no .srm files).
cd_list_device_saves() {
    pm_list_watched_dirs | while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        [ -d "$dir" ] || continue
        find "$dir" -name "*.srm" 2>/dev/null
    done
    return 0
}
