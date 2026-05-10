#!/bin/sh
# Continuity Tool PAK — launch.sh

cd $(dirname "$0")

# Marker + debug log so we can confirm the script ran
date >> ./launch_debug.log
exec 2>>./launch_debug.log
set -x

SHOW2="/mnt/SDCARD/.system/tg5040/bin/show2.elf"
LOGO="/mnt/SDCARD/.system/res/logo.png"
CONTINUITY_HOME="/mnt/SDCARD/.continuity"
HOOK_MARKER="$CONTINUITY_HOME/.hook_installed"

show_message() {
    if [ -x "$SHOW2" ] && [ -f "$LOGO" ]; then
        "$SHOW2" --mode=simple --image="$LOGO" --bgcolor=0x000000 \
            --logoheight=1 --text="$1" --fontsize=28 --timeout="$2"
    else
        sleep "$2"
    fi
}

# ── First run: install boot hook ────────────────────────────────────
if [ ! -f "$HOOK_MARKER" ]; then
    mkdir -p "$CONTINUITY_HOME"
    USERDATA_PATH="${USERDATA_PATH:-/mnt/SDCARD/.userdata/tg5040}"
    AUTO_SH="$USERDATA_PATH/auto.sh"

    # Install hook into auto.sh
    if ! grep -qF "continuity_daemon.sh" "$AUTO_SH" 2>/dev/null; then
        mkdir -p "$USERDATA_PATH"
        pak_abs="$(pwd)"
        if [ -f "$AUTO_SH" ]; then
            printf '\n# Continuity save sync daemon\n"%s/scripts/continuity_daemon.sh" &\n' "$pak_abs" >> "$AUTO_SH"
        else
            printf '#!/bin/sh\n# Continuity save sync daemon\n"%s/scripts/continuity_daemon.sh" &\n' "$pak_abs" > "$AUTO_SH"
            chmod +x "$AUTO_SH"
        fi
    fi

    touch "$HOOK_MARKER"

    # Try enrollment if setup.json present
    if [ -f "/mnt/SDCARD/setup.json" ]; then
        export CONTINUITY_PAK_DIR="$(pwd)"
        . ./scripts/pal_nextui.sh
        . ./scripts/core/pal.sh
        . ./scripts/core/path_mapper.sh
        . ./scripts/core/sync_engine.sh
        . ./scripts/core/enrollment.sh
        . ./scripts/enroll_sd_card.sh

        if esd_import; then
            show_message "Enrolled! Reboot to start syncing." 3
        else
            show_message "Enrollment failed. Check setup.json." 3
        fi
    else
        show_message "Installed! Reboot to start daemon." 3
    fi

    exit 0
fi

# ── Subsequent runs: show status ────────────────────────────────────
LOG_FILE="$CONTINUITY_HOME/continuity.log"

if [ -f "$LOG_FILE" ]; then
    last_status=$(grep -E "(Sync complete|Push complete|Pull complete|Enrollment complete)" "$LOG_FILE" 2>/dev/null | tail -1)
    show_message "${last_status:-Continuity is running.}" 3
else
    show_message "Daemon not started yet. Reboot device." 3
fi
