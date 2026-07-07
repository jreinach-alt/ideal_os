#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# PAL implementation for NextUI (TrimUI Brick)
# BusyBox ash compatible. FAT32 filesystem. No system git.

# All paths are env-defaulted: unset on the device (so the SD card paths
# apply), overridden by tests to run against sandbox directories.
CONTINUITY_SAVES_ROOT="${CONTINUITY_SAVES_ROOT:-/mnt/SDCARD/Saves}"
CONTINUITY_REPO_DIR="${CONTINUITY_REPO_DIR:-/mnt/SDCARD/.continuity/repo}"
CONTINUITY_PLATFORM="nextui"
CONTINUITY_SD_ROOT="${CONTINUITY_SD_ROOT:-/mnt/SDCARD}"
# CONTINUITY_DEVICE_NAME is read from enrollment config by pal_init

# The PAK's on-card location varies by platform dir (Tools/tg5040/... on the
# Brick). The daemon exports CONTINUITY_PAK_DIR from its own script path;
# fall back to the Brick default when sourced outside the daemon.
CONTINUITY_PAK_DIR="${CONTINUITY_PAK_DIR:-/mnt/SDCARD/Tools/tg5040/Continuity.pak}"
CONTINUITY_GIT_BIN="${CONTINUITY_GIT_BIN:-$CONTINUITY_PAK_DIR/bin/git}"

# pal_init — read device name from enrollment config and verify git binary
# Returns 0 on success, 1 if enrollment incomplete or git binary missing.
pal_init() {
    local config_file
    config_file="$CONTINUITY_REPO_DIR/.continuity/device_name"
    if [ -f "$config_file" ]; then
        CONTINUITY_DEVICE_NAME=$(cat "$config_file")
    else
        pal_log "error" "No device name found — enrollment incomplete?"
        return 1
    fi

    # Verify git binary exists
    if [ ! -x "$CONTINUITY_GIT_BIN" ]; then
        pal_log "error" "Git binary not found at $CONTINUITY_GIT_BIN"
        return 1
    fi
    return 0
}

# pal_is_online — check network reachability to GitHub
# Tries ping first, falls back to wget if ping unavailable.
pal_is_online() {
    ping -c 1 -W 3 github.com >/dev/null 2>&1 ||
    wget --spider -q -T 3 https://github.com 2>/dev/null
}

# pal_log — log a message at the given level to stderr
# Usage: pal_log <level> <message>
pal_log() {
    printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >&2
}

# pal_get_platform_map — print the absolute path to the NextUI platform map
pal_get_platform_map() {
    printf '%s\n' "$CONTINUITY_PAK_DIR/config/platform_maps/nextui.json"
}
