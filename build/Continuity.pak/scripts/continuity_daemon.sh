#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Continuity Daemon — NextUI (TrimUI Brick)
# Started via auto.sh boot hook. Manages enrollment, sync, and lifecycle.
set -e

readonly CONTINUITY_PID_FILE="/tmp/continuity.pid"
readonly CONTINUITY_VERSION="0.1.0"

# ── PID Management ───────────────────────────────────────────────────

# cd_write_pid — write current PID to file
cd_write_pid() {
    printf '%s\n' "$$" > "$CONTINUITY_PID_FILE"
}

# cd_is_running — check if another daemon instance is alive
# Returns: 0 if running, 1 if not
cd_is_running() {
    [ -f "$CONTINUITY_PID_FILE" ] || return 1

    local pid
    pid=$(cat "$CONTINUITY_PID_FILE")

    # Non-numeric PID → stale
    case "$pid" in
        ''|*[!0-9]*) rm -f "$CONTINUITY_PID_FILE"; return 1 ;;
    esac

    # Check if process is alive
    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    # Stale PID
    rm -f "$CONTINUITY_PID_FILE"
    return 1
}

# cd_remove_pid — remove PID file
cd_remove_pid() {
    rm -f "$CONTINUITY_PID_FILE"
    return 0
}

# ── Module Loading ───────────────────────────────────────────────────

# cd_source_file — source a file with error handling
# Usage: cd_source_file <path>
# Pre-pal_log: uses printf to stderr directly
cd_source_file() {
    local file
    file="$1"
    if [ ! -f "$file" ]; then
        printf '[%s] error: module not found: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$file" >&2
        cd_remove_pid
        exit 1
    fi
    # shellcheck disable=SC1090
    . "$file"
}

# cd_load_modules — source PAL and all core modules
cd_load_modules() {
    local scripts_dir core_dir
    scripts_dir="$CONTINUITY_PAK_DIR/scripts"
    core_dir="$scripts_dir/core"

    # PAL first (provides pal_log, platform vars)
    cd_source_file "$scripts_dir/pal_nextui.sh"

    # PAL validator
    cd_source_file "$core_dir/pal.sh"

    # Core modules in dependency order
    cd_source_file "$core_dir/path_mapper.sh"
    cd_source_file "$core_dir/sync_engine.sh"
    cd_source_file "$core_dir/enrollment.sh"
    cd_source_file "$core_dir/change_detector.sh"
    cd_source_file "$core_dir/cold_start.sh"
    cd_source_file "$core_dir/boot_pull.sh"
    cd_source_file "$core_dir/stale_boot.sh"
    cd_source_file "$core_dir/runtime_poll.sh"
    cd_source_file "$core_dir/conflict_handler.sh"
    cd_source_file "$core_dir/sync_status.sh"

    # Platform modules
    cd_source_file "$scripts_dir/enroll_sd_card.sh"
}

# ── Enrollment ───────────────────────────────────────────────────────

# cd_check_enrollment — verify or perform enrollment
# Returns: 0 if enrolled, 1 if not
cd_check_enrollment() {
    # Already enrolled?
    if enroll_is_enrolled; then
        pal_log "info" "Device is enrolled"
        return 0
    fi

    # Not enrolled — check for setup.json
    if ! esd_detect_setup_file; then
        pal_log "error" "Not enrolled, no setup.json found"
        return 1
    fi

    # Run enrollment
    pal_log "info" "setup.json found, running enrollment"
    if ! esd_import; then
        pal_log "error" "Enrollment failed"
        return 1
    fi

    # Re-init PAL (device_name now exists)
    if ! pal_init; then
        pal_log "error" "PAL init failed after enrollment"
        return 1
    fi

    # Re-init sync engine with new device name
    se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME"

    pal_log "info" "Enrollment complete: $CONTINUITY_DEVICE_NAME"
    return 0
}

# ── Boot Dispatch (Sprint 1.2) ──────────────────────────────────────

# cd_boot_dispatch — route to correct sync phase
cd_boot_dispatch() {
    if cs_is_cold_start; then
        pal_log "info" "Cold start detected — running initial sync"
        cs_run || pal_log "warn" "Cold start had errors"
    elif sb_is_stale; then
        pal_log "info" "Stale boot detected — running recovery"
        sb_run || pal_log "warn" "Stale boot recovery had errors"
    else
        pal_log "info" "Normal boot — pulling latest saves"
        bp_run || pal_log "warn" "Boot pull had errors"
    fi
}

# ── Poll Loop (Sprint 1.3) ──────────────────────────────────────────

readonly CONTINUITY_POLL_INTERVAL=30

# cd_shutdown — SIGTERM handler
cd_shutdown() {
    pal_log "info" "Shutdown signal received"

    # Final push attempt
    if pal_is_online; then
        if se_has_unpushed_commits "$CONTINUITY_REPO_DIR" 2>/dev/null; then
            pal_log "info" "Pushing queued commits before shutdown"
            se_push "$CONTINUITY_REPO_DIR" || pal_log "warn" "Final push failed"
        fi
    fi

    # Mark clean shutdown only if no unpushed commits remain
    if ! se_has_unpushed_commits "$CONTINUITY_REPO_DIR" 2>/dev/null; then
        sb_mark_clean_shutdown
        pal_log "info" "Clean shutdown marker written"
    else
        pal_log "warn" "Unpushed commits remain — skipping clean shutdown marker"
    fi

    cd_remove_pid
    pal_log "info" "Daemon stopped"
    exit 0
}

# cd_poll_loop — runtime sync loop
cd_poll_loop() {
    # Set trap after boot dispatch
    trap cd_shutdown TERM

    pal_log "info" "Entering poll loop (${CONTINUITY_POLL_INTERVAL}s interval)"

    while true; do
        # WiFi recovery: push queued commits when connectivity returns
        if pal_is_online; then
            if se_has_unpushed_commits "$CONTINUITY_REPO_DIR" 2>/dev/null; then
                pal_log "info" "WiFi available — pushing queued commits"
                se_push "$CONTINUITY_REPO_DIR" || pal_log "warn" "WiFi recovery push failed"
            fi
        fi

        # Runtime poll
        rp_run || pal_log "warn" "Poll cycle had errors"

        sleep "$CONTINUITY_POLL_INTERVAL" &
        wait $!
    done
}

# ── Main ─────────────────────────────────────────────────────────────

cd_main() {
    # Determine PAK directory from script location
    # Script is at: Continuity.pak/scripts/continuity_daemon.sh
    CONTINUITY_PAK_DIR="${CONTINUITY_PAK_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
    export CONTINUITY_PAK_DIR

    # Log file setup
    CONTINUITY_LOG_FILE="${CONTINUITY_LOG_FILE:-/mnt/SDCARD/.continuity/continuity.log}"
    mkdir -p "$(dirname "$CONTINUITY_LOG_FILE")"
    exec 2>>"$CONTINUITY_LOG_FILE"

    pal_log_early() {
        printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >&2
    }

    pal_log_early "info" "Daemon v${CONTINUITY_VERSION} starting (PID $$)"

    # PID guard
    if cd_is_running; then
        pal_log_early "info" "Another instance running, exiting"
        exit 0
    fi
    cd_write_pid

    # Load all modules
    cd_load_modules

    # Try PAL init (may fail if not yet enrolled — that's OK)
    if ! pal_init; then
        if [ -n "$CONTINUITY_REPO_DIR" ]; then
            pal_log "info" "PAL init deferred (not yet enrolled)"
        else
            pal_log "error" "PAL init failed — CONTINUITY_REPO_DIR not set"
            cd_remove_pid
            exit 1
        fi
    else
        pal_validate || { cd_remove_pid; exit 1; }
        se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME"
        pm_load_platform_map "$(pal_get_platform_map)"
    fi

    # Enrollment check
    if ! cd_check_enrollment; then
        cd_remove_pid
        exit 1
    fi

    # Post-enrollment: ensure PAL is fully initialized
    if [ -z "$CONTINUITY_DEVICE_NAME" ]; then
        pal_init || { pal_log "error" "PAL init failed after enrollment"; cd_remove_pid; exit 1; }
        pal_validate || { cd_remove_pid; exit 1; }
        se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME"
        pm_load_platform_map "$(pal_get_platform_map)"
    fi

    pal_log "info" "Bootstrap complete, enrolled as $CONTINUITY_DEVICE_NAME"

    # Boot dispatch
    cd_boot_dispatch

    # Poll loop (blocks until SIGTERM)
    cd_poll_loop
}

cd_main "$@"
