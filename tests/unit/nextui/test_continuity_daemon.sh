#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests for src/platforms/nextui/continuity_daemon.sh
# QA against sprint 1.1 (PID, module loading, enrollment), 1.2 (boot
# dispatch), and 1.3 (shutdown marker logic) acceptance criteria.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

passed=0
failed=0

assert_eq() {
    local desc expected actual
    desc="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$desc" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_rc() {
    local desc expected actual
    desc="$1"; expected="$2"; actual="$3"
    if [ "$expected" -eq "$actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected rc: %s\n  actual rc:   %s\n' "$desc" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_file_exists() {
    local desc filepath
    desc="$1"; filepath="$2"
    if [ -e "$filepath" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  file not found: %s\n' "$desc" "$filepath" >&2
        failed=$((failed + 1))
    fi
}

assert_file_not_exists() {
    local desc filepath
    desc="$1"; filepath="$2"
    if [ ! -e "$filepath" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  file should not exist: %s\n' "$desc" "$filepath" >&2
        failed=$((failed + 1))
    fi
}

# --- Setup ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Source the daemon functions without running the daemon. PID file must be
# redirected BEFORE sourcing — the daemon locks it with readonly.
CONTINUITY_PID_FILE="$TEST_TMPDIR/continuity.pid"
CONTINUITY_DAEMON_NO_MAIN=1
. "$PROJECT_ROOT/src/platforms/nextui/continuity_daemon.sh"

# Quiet log capture for assertions on logged messages
LOG_CAPTURE="$TEST_TMPDIR/log_capture.txt"
pal_log() {
    printf '%s: %s\n' "$1" "$2" >> "$LOG_CAPTURE"
}

# Real file-predicate + marker functions from core
. "$PROJECT_ROOT/src/core/cold_start.sh"
. "$PROJECT_ROOT/src/core/stale_boot.sh"

# ═══ Sprint 1.1 — PID management (AC 1-6) ═══════════════════════════

# AC 5: cd_write_pid writes current PID
cd_write_pid
assert_file_exists "AC5: PID file written" "$CONTINUITY_PID_FILE"
assert_eq "AC5: PID file contains \$\$" "$$" "$(cat "$CONTINUITY_PID_FILE")"

# AC 1: running process detected
sleep 60 &
live_pid=$!
printf '%s\n' "$live_pid" > "$CONTINUITY_PID_FILE"
rc=0; cd_is_running || rc=$?
assert_rc "AC1: live PID detected as running" 0 "$rc"
kill "$live_pid" 2>/dev/null
wait "$live_pid" 2>/dev/null || true

# AC 3: stale PID removed and reported not-running
sleep 0.1 &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
printf '%s\n' "$dead_pid" > "$CONTINUITY_PID_FILE"
rc=0; cd_is_running || rc=$?
assert_rc "AC3: stale PID reports not running" 1 "$rc"
assert_file_not_exists "AC3: stale PID file removed" "$CONTINUITY_PID_FILE"

# AC 2: absent PID file
rc=0; cd_is_running || rc=$?
assert_rc "AC2: absent PID file reports not running" 1 "$rc"

# AC 4: non-numeric PID content
printf 'garbage\n' > "$CONTINUITY_PID_FILE"
rc=0; cd_is_running || rc=$?
assert_rc "AC4: garbage PID reports not running" 1 "$rc"
assert_file_not_exists "AC4: garbage PID file removed" "$CONTINUITY_PID_FILE"

# AC 6: cd_remove_pid idempotent
cd_write_pid
cd_remove_pid
assert_file_not_exists "AC6: PID file removed" "$CONTINUITY_PID_FILE"
rc=0; cd_remove_pid || rc=$?
assert_rc "AC6: second remove still returns 0" 0 "$rc"

# ═══ Sprint 1.1 — Module loading (AC 8-11) ══════════════════════════

FAKE_PAK="$TEST_TMPDIR/pak"
mkdir -p "$FAKE_PAK/scripts/core"
ln -s "$PROJECT_ROOT/src/platforms/nextui/pal_nextui.sh" "$FAKE_PAK/scripts/pal_nextui.sh"
ln -s "$PROJECT_ROOT/src/platforms/nextui/enroll_sd_card.sh" "$FAKE_PAK/scripts/enroll_sd_card.sh"
for m in pal path_mapper sync_engine enrollment change_detector cold_start \
         boot_pull stale_boot runtime_poll conflict_handler sync_status; do
    ln -s "$PROJECT_ROOT/src/core/$m.sh" "$FAKE_PAK/scripts/core/$m.sh"
done

# AC 8-9: happy path — all modules load, key functions defined
out=$(
    CONTINUITY_PAK_DIR="$FAKE_PAK"
    cd_load_modules 2>/dev/null
    ok=1
    for fn in enroll_is_enrolled se_init pm_load_platform_map \
              cs_is_cold_start sb_is_stale bp_run rp_run esd_import; do
        command -v "$fn" >/dev/null 2>&1 || ok=0
    done
    printf '%s' "$ok"
)
assert_eq "AC8/9: modules load and all key functions defined" "1" "$out"

# AC 10-11: missing module → exit 1, PID file cleaned up
rm "$FAKE_PAK/scripts/core/runtime_poll.sh"
cd_write_pid
rc=0
( CONTINUITY_PAK_DIR="$FAKE_PAK"; cd_load_modules ) 2>/dev/null || rc=$?
assert_rc "AC10: missing module exits 1" 1 "$rc"
assert_file_not_exists "AC11: PID cleaned up on module failure" "$CONTINUITY_PID_FILE"
ln -s "$PROJECT_ROOT/src/core/runtime_poll.sh" "$FAKE_PAK/scripts/core/runtime_poll.sh"

# ═══ Sprint 1.1 — Enrollment check (AC 12-26) ═══════════════════════

# AC 12-13: already enrolled — esd_import not called
enroll_is_enrolled() { return 0; }
esd_detect_setup_file() { return 0; }
esd_import() { touch "$TEST_TMPDIR/import_called"; return 0; }
rc=0; cd_check_enrollment || rc=$?
assert_rc "AC12: already enrolled returns 0" 0 "$rc"
assert_file_not_exists "AC12: esd_import not called when enrolled" "$TEST_TMPDIR/import_called"

# AC 21-22: not enrolled, no setup.json
enroll_is_enrolled() { return 1; }
esd_detect_setup_file() { return 1; }
: > "$LOG_CAPTURE"
rc=0; cd_check_enrollment || rc=$?
assert_rc "AC21: no setup.json returns 1" 1 "$rc"
if grep -q "setup.json" "$LOG_CAPTURE"; then
    assert_eq "AC22: missing setup.json logged" "logged" "logged"
else
    assert_eq "AC22: missing setup.json logged" "logged" "not-logged"
fi

# AC 14/17: fresh enrollment succeeds
esd_detect_setup_file() { return 0; }
rc=0; cd_check_enrollment || rc=$?
assert_rc "AC17: fresh enrollment returns 0" 0 "$rc"
assert_file_exists "AC14: esd_import called" "$TEST_TMPDIR/import_called"

# AC 24-25: enrollment failure
esd_import() { return 1; }
: > "$LOG_CAPTURE"
rc=0; cd_check_enrollment || rc=$?
assert_rc "AC24: failed enrollment returns 1" 1 "$rc"
if grep -qi "failed" "$LOG_CAPTURE"; then
    assert_eq "AC25: enrollment failure logged" "logged" "logged"
else
    assert_eq "AC25: enrollment failure logged" "logged" "not-logged"
fi

# ═══ Sprint 1.2 — Boot dispatch (AC 1-11) ═══════════════════════════

REPO="$TEST_TMPDIR/repo"
mkdir -p "$REPO/.continuity"

cs_run() { printf '%s' "$1" > "$TEST_TMPDIR/cs_run_arg"; }
sb_run() { printf '%s' "$1" > "$TEST_TMPDIR/sb_run_arg"; }
bp_run() { printf '%s' "$1" > "$TEST_TMPDIR/bp_run_arg"; }
reset_phase_flags() {
    rm -f "$TEST_TMPDIR/cs_run_arg" "$TEST_TMPDIR/sb_run_arg" "$TEST_TMPDIR/bp_run_arg"
}

# AC 1: no sentinel → cold start, repo_dir passed through
reset_phase_flags
rm -f "$REPO/.continuity/sentinel" "$REPO/.continuity/clean_shutdown"
: > "$LOG_CAPTURE"
rc=0; cd_boot_dispatch "$REPO" || rc=$?
assert_rc "1.2-AC1: cold start dispatch returns 0" 0 "$rc"
assert_file_exists "1.2-AC1: cs_run called" "$TEST_TMPDIR/cs_run_arg"
assert_eq "1.2-AC1: cs_run got repo_dir" "$REPO" "$(cat "$TEST_TMPDIR/cs_run_arg")"
assert_file_not_exists "1.2-AC1: sb_run not called" "$TEST_TMPDIR/sb_run_arg"
assert_file_not_exists "1.2-AC1: bp_run not called" "$TEST_TMPDIR/bp_run_arg"
if grep -qi "cold start" "$LOG_CAPTURE"; then
    assert_eq "1.2-AC6/7: cold start phase logged" "logged" "logged"
else
    assert_eq "1.2-AC6/7: cold start phase logged" "logged" "not-logged"
fi

# AC 2: sentinel, no marker → stale recovery
reset_phase_flags
touch "$REPO/.continuity/sentinel"
rm -f "$REPO/.continuity/clean_shutdown"
: > "$LOG_CAPTURE"
rc=0; cd_boot_dispatch "$REPO" || rc=$?
assert_file_exists "1.2-AC2: sb_run called" "$TEST_TMPDIR/sb_run_arg"
assert_eq "1.2-AC2: sb_run got repo_dir" "$REPO" "$(cat "$TEST_TMPDIR/sb_run_arg")"
assert_file_not_exists "1.2-AC2: cs_run not called" "$TEST_TMPDIR/cs_run_arg"
if grep -qi "stale" "$LOG_CAPTURE"; then
    assert_eq "1.2-AC7: stale phase logged" "logged" "logged"
else
    assert_eq "1.2-AC7: stale phase logged" "logged" "not-logged"
fi

# AC 3-4: sentinel + marker → boot pull, marker consumed
reset_phase_flags
sb_mark_clean_shutdown "$REPO"
: > "$LOG_CAPTURE"
rc=0; cd_boot_dispatch "$REPO" || rc=$?
assert_file_exists "1.2-AC3: bp_run called" "$TEST_TMPDIR/bp_run_arg"
assert_eq "1.2-AC3: bp_run got repo_dir" "$REPO" "$(cat "$TEST_TMPDIR/bp_run_arg")"
assert_file_not_exists "1.2-AC4: clean shutdown marker consumed" \
    "$REPO/.continuity/clean_shutdown"
if grep -qi "normal" "$LOG_CAPTURE"; then
    assert_eq "1.2-AC7: normal phase logged" "logged" "logged"
else
    assert_eq "1.2-AC7: normal phase logged" "logged" "not-logged"
fi

# AC 5/8: cs_run failure code propagates
rm -f "$REPO/.continuity/sentinel"
cs_run() { return 1; }
rc=0; cd_boot_dispatch "$REPO" || rc=$?
assert_rc "1.2-AC8: cs_run rc=1 propagates" 1 "$rc"

# AC 10: bp_run failure code propagates
touch "$REPO/.continuity/sentinel"
sb_mark_clean_shutdown "$REPO"
bp_run() { return 2; }
rc=0; cd_boot_dispatch "$REPO" || rc=$?
assert_rc "1.2-AC10: bp_run rc=2 propagates" 2 "$rc"

# ═══ Sprint 1.3 — Shutdown marker logic ═════════════════════════════

CONTINUITY_REPO_DIR="$REPO"
pal_is_online() { return 0; }

# Case A: nothing to push → marker written, PID removed, exit 0
rm -f "$REPO/.continuity/clean_shutdown"
se_has_unpushed_commits() { return 1; }
se_push() { touch "$TEST_TMPDIR/push_called"; }
cd_write_pid
rc=0; ( cd_shutdown ) 2>/dev/null || rc=$?
assert_rc "1.3-A: shutdown exits 0" 0 "$rc"
assert_file_exists "1.3-A: clean marker written" "$REPO/.continuity/clean_shutdown"
assert_file_not_exists "1.3-A: PID removed" "$CONTINUITY_PID_FILE"
assert_file_not_exists "1.3-A: no push when nothing unpushed" "$TEST_TMPDIR/push_called"

# Case B: unpushed + online + push succeeds → pushed, marker written
rm -f "$REPO/.continuity/clean_shutdown" "$TEST_TMPDIR/pushed_flag"
se_has_unpushed_commits() { [ ! -f "$TEST_TMPDIR/pushed_flag" ]; }
se_push() { touch "$TEST_TMPDIR/pushed_flag"; }
cd_write_pid
rc=0; ( cd_shutdown ) 2>/dev/null || rc=$?
assert_rc "1.3-B: shutdown exits 0" 0 "$rc"
assert_file_exists "1.3-B: final push ran" "$TEST_TMPDIR/pushed_flag"
assert_file_exists "1.3-B: clean marker written after push" "$REPO/.continuity/clean_shutdown"
assert_file_not_exists "1.3-B: PID removed" "$CONTINUITY_PID_FILE"

# Case C: unpushed + push fails → NO clean marker, PID still removed
rm -f "$REPO/.continuity/clean_shutdown"
se_has_unpushed_commits() { return 0; }
se_push() { return 1; }
cd_write_pid
rc=0; ( cd_shutdown ) 2>/dev/null || rc=$?
assert_rc "1.3-C: shutdown still exits 0" 0 "$rc"
assert_file_not_exists "1.3-C: no clean marker after failed push" \
    "$REPO/.continuity/clean_shutdown"
assert_file_not_exists "1.3-C: PID removed even on failed push" "$CONTINUITY_PID_FILE"

# Case D: unpushed + offline → NO clean marker
rm -f "$REPO/.continuity/clean_shutdown"
pal_is_online() { return 1; }
se_push() { touch "$TEST_TMPDIR/offline_push"; return 1; }
cd_write_pid
rc=0; ( cd_shutdown ) 2>/dev/null || rc=$?
assert_rc "1.3-D: shutdown exits 0 offline" 0 "$rc"
assert_file_not_exists "1.3-D: no push attempted offline" "$TEST_TMPDIR/offline_push"
assert_file_not_exists "1.3-D: no clean marker offline with unpushed" \
    "$REPO/.continuity/clean_shutdown"

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
