#!/bin/sh
# Continuity Tool PAK — launch.sh
# Entry point when user opens "Continuity" from the NextUI Tools menu.
#
# First run: installs boot hook into .userdata/tg5040/auto.sh, runs
# enrollment if setup.json present, tells user to reboot.
# Subsequent runs: shows sync status.

PAK_DIR="$(dirname "$0")"
USERDATA_PATH="${USERDATA_PATH:-/mnt/SDCARD/.userdata/tg5040}"
AUTO_SH="$USERDATA_PATH/auto.sh"
CONTINUITY_HOME="/mnt/SDCARD/.continuity"
LOG_FILE="$CONTINUITY_HOME/continuity.log"
HOOK_MARKER="$CONTINUITY_HOME/.hook_installed"

# show2.elf for displaying messages (if available)
SHOW2="${PAK_DIR}/bin/show2.elf"
if [ ! -x "$SHOW2" ]; then
    SHOW2="/mnt/SDCARD/.system/tg5040/bin/show2.elf"
fi

# show_message — display a message to the user
# Falls back to sleep if show2.elf is not available.
show_message() {
    local msg duration
    msg="$1"
    duration="${2:-3}"

    if [ -x "$SHOW2" ]; then
        printf '%s\n' "$msg" > /tmp/show2.fifo 2>/dev/null || true
        sleep "$duration"
    else
        sleep "$duration"
    fi
}

# install_boot_hook — add Continuity daemon start to auto.sh
install_boot_hook() {
    local hook_line
    hook_line="\"$PAK_DIR/scripts/continuity_daemon.sh\" &"

    mkdir -p "$USERDATA_PATH"

    # Check if hook already present
    if [ -f "$AUTO_SH" ] && grep -qF "continuity_daemon.sh" "$AUTO_SH" 2>/dev/null; then
        return 0
    fi

    # Append our hook (preserve existing auto.sh content)
    if [ -f "$AUTO_SH" ]; then
        printf '\n# Continuity save sync daemon\n%s\n' "$hook_line" >> "$AUTO_SH"
    else
        printf '#!/bin/sh\n# Continuity save sync daemon\n%s\n' "$hook_line" > "$AUTO_SH"
        chmod +x "$AUTO_SH"
    fi

    mkdir -p "$CONTINUITY_HOME"
    touch "$HOOK_MARKER"
    return 0
}

# run_enrollment — attempt enrollment if setup.json exists
run_enrollment() {
    if [ ! -f "/mnt/SDCARD/setup.json" ]; then
        return 1
    fi

    # Source PAL and core modules for enrollment
    export CONTINUITY_PAK_DIR="$PAK_DIR"
    . "$PAK_DIR/scripts/pal_nextui.sh"
    . "$PAK_DIR/scripts/core/pal.sh"
    . "$PAK_DIR/scripts/core/path_mapper.sh"
    . "$PAK_DIR/scripts/core/sync_engine.sh"
    . "$PAK_DIR/scripts/core/enrollment.sh"
    . "$PAK_DIR/scripts/enroll_sd_card.sh"

    if esd_import; then
        return 0
    fi
    return 1
}

# ── Main ─────────────────────────────────────────────────────────────

# First run: install boot hook
if [ ! -f "$HOOK_MARKER" ]; then
    show_message "Installing Continuity..." 1

    if install_boot_hook; then
        show_message "Boot hook installed." 1
    else
        show_message "ERROR: Failed to install boot hook." 3
        exit 1
    fi

    # Try enrollment if setup.json present
    if [ -f "/mnt/SDCARD/setup.json" ]; then
        show_message "Enrolling device..." 1
        if run_enrollment; then
            show_message "Enrollment complete! Please reboot." 3
        else
            show_message "Enrollment failed. Check setup.json." 3
        fi
    else
        show_message "Place setup.json on SD card and reboot." 3
    fi

    exit 0
fi

# Subsequent runs: show status
if [ -f "$LOG_FILE" ]; then
    # Get last sync status from log
    last_status=$(grep -E "(Sync complete|Push complete|Pull complete|Enrollment complete)" "$LOG_FILE" 2>/dev/null | tail -1)
    if [ -n "$last_status" ]; then
        show_message "$last_status" 3
    else
        show_message "Continuity is running." 3
    fi
else
    show_message "Continuity daemon not yet started. Reboot device." 3
fi

exit 0
