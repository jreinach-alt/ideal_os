#!/bin/sh
# Continuity Tool PAK — launch.sh
#
# Entry point for the Continuity tool. On first launch, installs the sync
# daemon into $USERDATA_PATH/auto.sh; on subsequent launches, shows the
# daemon's last status line.
#
# Set CONTINUITY_DEBUG=1 in the calling environment to capture an xtrace
# log to ./launch_debug.log inside the PAK directory.
#
# CONTINUITY_HOME and CONTINUITY_SD_ROOT are overridable for off-device
# testing; on the device they default to the SD card paths.

cd "$(dirname "$0")" || exit 1

# One-line breadcrumb on every launch, before anything can fail — a launch
# that produces no visible output must never be invisible in the logs too.
printf '%s launch.sh started\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> ./launch.log

if [ -n "$CONTINUITY_DEBUG" ]; then
    exec 2>>./launch_debug.log
    set -x
fi

LOGO="/mnt/SDCARD/.system/res/logo.png"
SD_ROOT="${CONTINUITY_SD_ROOT:-/mnt/SDCARD}"
CONTINUITY_HOME="${CONTINUITY_HOME:-/mnt/SDCARD/.continuity}"
HOOK_MARKER="$CONTINUITY_HOME/.hook_installed"
FIFO="/tmp/show2.fifo"
SHOW_PID=""

# ── show2.elf helpers ───────────────────────────────────────────────
# show2.elf lives on $PATH (NextUI exports $SYSTEM_PATH/bin via PATH),
# so we invoke it unqualified — portable across tg5040 and tg5050.

# show_simple — display a static message for $2 seconds, then return.
show_simple() {
    show2.elf --mode=simple --image="$LOGO" --bgcolor=0x000000 \
        --text="$1" --fontsize=28 --timeout="$2"
}

# show_daemon_start — start show2 in daemon mode in the background.
# Sets $SHOW_PID. Caller must invoke show_daemon_stop before exit.
show_daemon_start() {
    show2.elf --mode=daemon --image="$LOGO" --bgcolor=0x000000 \
        --text="$1" --fontsize=28 &
    SHOW_PID=$!
    # Brief pause so show2 has time to mkfifo before we write to it.
    sleep 1
}

# show_daemon_text — push a new text line into the running daemon.
show_daemon_text() {
    [ -p "$FIFO" ] && printf 'TEXT:%s\n' "$1" > "$FIFO"
}

# show_daemon_stop — gracefully tear down the daemon and wait for exit.
show_daemon_stop() {
    [ -n "$SHOW_PID" ] || return 0
    [ -p "$FIFO" ] && printf 'QUIT\n' > "$FIFO"
    wait "$SHOW_PID" 2>/dev/null
    SHOW_PID=""
}

# ── First run: install daemon hook ──────────────────────────────────

if [ ! -f "$HOOK_MARKER" ]; then
    mkdir -p "$CONTINUITY_HOME"

    USERDATA_PATH="${USERDATA_PATH:-/mnt/SDCARD/.userdata/tg5040}"
    AUTO_SH="$USERDATA_PATH/auto.sh"

    # Idempotently append the daemon launch into the global auto.sh hook.
    # The daemon is fully detached from the boot shell's stdio: it manages
    # its own log file, and a daemon holding the boot console open is the
    # kind of thing that hangs a boot sequence.
    if ! grep -qF "continuity_daemon.sh" "$AUTO_SH" 2>/dev/null; then
        mkdir -p "$USERDATA_PATH"
        pak_abs="$(pwd)"
        hook_line="\"$pak_abs/scripts/continuity_daemon.sh\" </dev/null >/dev/null 2>&1 &"
        if [ -f "$AUTO_SH" ]; then
            printf '\n# Continuity save sync daemon\n%s\n' "$hook_line" >> "$AUTO_SH"
        else
            printf '#!/bin/sh\n# Continuity save sync daemon\n%s\n' "$hook_line" > "$AUTO_SH"
            chmod +x "$AUTO_SH"
        fi
    fi

    touch "$HOOK_MARKER"

    # If a setup.json is staged on the SD card, run enrollment now so the
    # user sees the result immediately rather than after a reboot.
    if [ -f "$SD_ROOT/setup.json" ]; then
        # Verify all sourced modules are present before touching any of them.
        for f in scripts/pal_nextui.sh scripts/core/pal.sh \
                 scripts/core/path_mapper.sh scripts/core/sync_engine.sh \
                 scripts/core/enrollment.sh scripts/enroll_sd_card.sh \
                 scripts/enroll_ui.sh; do
            if [ ! -f "./$f" ]; then
                show_simple "Continuity install corrupt: missing $f" 5
                exit 1
            fi
        done

        show_daemon_start "Enrolling device...  (B cancels, X/Y shows log)"

        CONTINUITY_PAK_DIR="$(pwd)"
        export CONTINUITY_PAK_DIR
        . ./scripts/pal_nextui.sh
        . ./scripts/core/pal.sh
        . ./scripts/core/path_mapper.sh
        . ./scripts/core/sync_engine.sh
        . ./scripts/core/enrollment.sh
        . ./scripts/enroll_sd_card.sh
        . ./scripts/enroll_ui.sh

        # Supervised enrollment: live log line on screen, B cancels,
        # X/Y replays the log, watchdog kills a stuck run. Everything is
        # logged to .continuity/enroll.log regardless of outcome.
        ENROLL_LOG="$CONTINUITY_HOME/enroll.log"
        rc=0
        eui_run_enrollment "$ENROLL_LOG" || rc=$?

        case "$rc" in
            0)  show_daemon_text "Enrolled! Reboot to start syncing." ;;
            2)  show_daemon_text "Enrollment cancelled. Launch again to retry." ;;
            3)  show_daemon_text "Enrollment timed out. Log: SD/.continuity/enroll.log" ;;
            *)  last_err=$(grep -i "error" "$ENROLL_LOG" 2>/dev/null | tail -1 | cut -c1-64)
                show_daemon_text "${last_err:-Enrollment failed.}"
                sleep 4
                show_daemon_text "Full log: SD card/.continuity/enroll.log" ;;
        esac

        sleep 3
        show_daemon_stop
    else
        show_simple "Installed! Reboot to start daemon." 3
    fi

    exit 0
fi

# ── Subsequent runs: show daemon status ─────────────────────────────

LOG_FILE="$CONTINUITY_HOME/continuity.log"

if [ -f "$LOG_FILE" ]; then
    last_status=$(grep -E "(Sync complete|Push complete|Pull complete|Enrollment complete)" \
                       "$LOG_FILE" 2>/dev/null | tail -1)
    show_simple "${last_status:-Continuity is running.}" 3
else
    show_simple "Daemon not started yet. Reboot device." 3
fi
