#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC1091
# Continuity Tool PAK — launch.sh
# Entry point when user opens "Continuity" from the NextUI Tools menu.
#
# First run: installs boot hook into .userdata/tg5040/auto.sh, runs
# enrollment if setup.json present, tells user to reboot.
# Subsequent runs: shows sync status.

# Match standard PAK pattern: cd into PAK directory first
cd $(dirname "$0")

# Debug log inside PAK directory — always visible next to launch.sh
exec 2>>./launch_debug.log
set -x

USERDATA_PATH="${USERDATA_PATH:-/mnt/SDCARD/.userdata/tg5040}"
AUTO_SH="$USERDATA_PATH/auto.sh"
CONTINUITY_HOME="/mnt/SDCARD/.continuity"
LOG_FILE="$CONTINUITY_HOME/continuity.log"
HOOK_MARKER="$CONTINUITY_HOME/.hook_installed"
mkdir -p "$CONTINUITY_HOME" || true

# show2.elf for displaying messages (if available)
SHOW2="/mnt/SDCARD/.system/tg5040/bin/show2.elf"
SHOW2_PID=""

# Logo image — show2.elf requires --image
LOGO="/mnt/SDCARD/.system/res/logo.png"

# start_display — launch show2.elf daemon for message display
start_display() {
    local initial_text
    initial_text="${1:-Please wait...}"

    if [ -x "$SHOW2" ] && [ -f "$LOGO" ]; then
        "$SHOW2" --mode=daemon --image="$LOGO" --bgcolor=0x000000 \
            --logoheight=1 --text="$initial_text" --fontsize=28 &
        SHOW2_PID=$!
        sleep 0.5
    fi
}

# update_display — update the on-screen message
update_display() {
    local msg
    msg="$1"

    if [ -n "$SHOW2_PID" ]; then
        printf 'TEXT:%s\n' "$msg" > /tmp/show2.fifo 2>/dev/null || true
    fi
}

# stop_display — show a final message, then quit show2.elf
stop_display() {
    local msg duration
    msg="${1:-}"
    duration="${2:-2}"

    if [ -n "$SHOW2_PID" ]; then
        if [ -n "$msg" ]; then
            printf 'TEXT:%s\n' "$msg" > /tmp/show2.fifo 2>/dev/null || true
        fi
        sleep "$duration"
        printf 'QUIT\n' > /tmp/show2.fifo 2>/dev/null || true
        wait "$SHOW2_PID" 2>/dev/null || true
        SHOW2_PID=""
    else
        sleep "$duration"
    fi
}

# install_boot_hook — add Continuity daemon start to auto.sh
install_boot_hook() {
    local hook_line pak_abs
    pak_abs="$(pwd)"
    hook_line="\"$pak_abs/scripts/continuity_daemon.sh\" &"

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
    export CONTINUITY_PAK_DIR="$(pwd)"
    . ./scripts/pal_nextui.sh
    . ./scripts/core/pal.sh
    . ./scripts/core/path_mapper.sh
    . ./scripts/core/sync_engine.sh
    . ./scripts/core/enrollment.sh
    . ./scripts/enroll_sd_card.sh

    if esd_import; then
        return 0
    fi
    return 1
}

# ── Main ─────────────────────────────────────────────────────────────

# First run: install boot hook
if [ ! -f "$HOOK_MARKER" ]; then
    start_display "Installing Continuity..."

    if install_boot_hook; then
        update_display "Boot hook installed."
        sleep 1
    else
        update_display "ERROR: Failed to install boot hook."
        sleep 2
        stop_display "" 1
        exit 1
    fi

    # Try enrollment if setup.json present
    if [ -f "/mnt/SDCARD/setup.json" ]; then
        update_display "Enrolling device..."
        if run_enrollment; then
            stop_display "Enrollment complete! Please reboot." 3
        else
            stop_display "Enrollment failed. Check setup.json." 3
        fi
    else
        stop_display "Hook installed. Reboot to start daemon." 3
    fi

    exit 0
fi

# Subsequent runs: show status
start_display "Continuity"

if [ -f "$LOG_FILE" ]; then
    last_status=$(grep -E "(Sync complete|Push complete|Pull complete|Enrollment complete)" "$LOG_FILE" 2>/dev/null | tail -1)
    if [ -n "$last_status" ]; then
        update_display "$last_status"
    else
        update_display "Continuity is running."
    fi
else
    update_display "Daemon not started. Reboot device."
fi

stop_display "" 3
exit 0
