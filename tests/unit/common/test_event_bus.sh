#!/bin/sh
set -e

# Tests for src/common/event_bus.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Override event log dir before sourcing
TEST_TMP="$(mktemp -d /tmp/test_event_bus.XXXXXX)"
EVENT_LOG_DIR="$TEST_TMP/events"
EVENT_LOG_FILE="$EVENT_LOG_DIR/system-events.log"
export EVENT_LOG_DIR EVENT_LOG_FILE

trap 'rm -rf "$TEST_TMP"' EXIT

. "$REPO_ROOT/src/common/event_bus.sh"

passed=0
total=0

assert_eq() {
    _desc="$1"
    _expected="$2"
    _actual="$3"
    total=$((total + 1))
    if [ "$_expected" = "$_actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$_desc" "$_expected" "$_actual" >&2
        exit 1
    fi
}

assert_rc() {
    _desc="$1"
    _expected_rc="$2"
    shift 2
    total=$((total + 1))
    _actual_rc=0
    "$@" 2>/dev/null || _actual_rc=$?
    if [ "$_actual_rc" -eq "$_expected_rc" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected rc: %d\n  actual rc:   %d\n' "$_desc" "$_expected_rc" "$_actual_rc" >&2
        exit 1
    fi
}

# Helper to reset the log between tests
reset_log() {
    rm -rf "$EVENT_LOG_DIR"
    event_bus_init
}

# --- AC 7: Init creates log ---

test_init_creates_dir() {
    rm -rf "$EVENT_LOG_DIR"
    event_bus_init
    total=$((total + 1))
    if [ -d "$EVENT_LOG_DIR" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: init did not create directory\n' >&2
        exit 1
    fi
}

test_init_creates_file() {
    total=$((total + 1))
    if [ -f "$EVENT_LOG_FILE" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: init did not create log file\n' >&2
        exit 1
    fi
}

test_init_idempotent() {
    event_bus_init
    event_bus_init
    total=$((total + 1))
    if [ -f "$EVENT_LOG_FILE" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: init not idempotent\n' >&2
        exit 1
    fi
}

# --- AC 8: Emit appends event ---

test_emit_appends_one_line() {
    reset_log
    event_bus_emit "session" "session_created" '{"id":"test"}'
    _lines="$(wc -l < "$EVENT_LOG_FILE")"
    _lines="$(printf '%s' "$_lines" | tr -d ' ')"
    assert_eq "emit adds one line" "1" "$_lines"
}

test_emit_appends_multiple() {
    reset_log
    event_bus_emit "session" "session_created" '{"id":"1"}'
    event_bus_emit "sync" "backup_completed" '{"id":"2"}'
    _lines="$(wc -l < "$EVENT_LOG_FILE")"
    _lines="$(printf '%s' "$_lines" | tr -d ' ')"
    assert_eq "emit adds two lines" "2" "$_lines"
}

# --- AC 9: Emitted event has all fields ---

test_emit_has_schema_version() {
    reset_log
    event_bus_emit "session" "session_created" '{}'
    _line="$(cat "$EVENT_LOG_FILE")"
    total=$((total + 1))
    case "$_line" in
        *'"_schema_version":"1.0"'*)
            passed=$((passed + 1))
            ;;
        *)
            printf 'FAIL: missing _schema_version in: %s\n' "$_line" >&2
            exit 1
            ;;
    esac
}

test_emit_has_timestamp() {
    reset_log
    event_bus_emit "session" "test_event" '{}'
    _line="$(cat "$EVENT_LOG_FILE")"
    total=$((total + 1))
    case "$_line" in
        *'"timestamp":"'*'T'*'Z"'*)
            passed=$((passed + 1))
            ;;
        *)
            printf 'FAIL: missing or malformed timestamp in: %s\n' "$_line" >&2
            exit 1
            ;;
    esac
}

test_emit_has_source() {
    reset_log
    event_bus_emit "session" "test_event" '{}'
    _line="$(cat "$EVENT_LOG_FILE")"
    total=$((total + 1))
    case "$_line" in
        *'"source":"session"'*)
            passed=$((passed + 1))
            ;;
        *)
            printf 'FAIL: missing source in: %s\n' "$_line" >&2
            exit 1
            ;;
    esac
}

test_emit_has_event_type() {
    reset_log
    event_bus_emit "session" "test_event" '{}'
    _line="$(cat "$EVENT_LOG_FILE")"
    total=$((total + 1))
    case "$_line" in
        *'"event_type":"test_event"'*)
            passed=$((passed + 1))
            ;;
        *)
            printf 'FAIL: missing event_type in: %s\n' "$_line" >&2
            exit 1
            ;;
    esac
}

test_emit_has_payload() {
    reset_log
    event_bus_emit "session" "test_event" '{"key":"val"}'
    _line="$(cat "$EVENT_LOG_FILE")"
    total=$((total + 1))
    case "$_line" in
        *'"payload":{"key":"val"}'*)
            passed=$((passed + 1))
            ;;
        *)
            printf 'FAIL: missing payload in: %s\n' "$_line" >&2
            exit 1
            ;;
    esac
}

test_emit_default_payload() {
    reset_log
    event_bus_emit "session" "test_event"
    _line="$(cat "$EVENT_LOG_FILE")"
    total=$((total + 1))
    case "$_line" in
        *'"payload":{}'*)
            passed=$((passed + 1))
            ;;
        *)
            printf 'FAIL: default payload not {} in: %s\n' "$_line" >&2
            exit 1
            ;;
    esac
}

# --- AC 10: Read filters by source ---

test_read_filter_source() {
    reset_log
    event_bus_emit "session" "session_created" '{"id":"1"}'
    event_bus_emit "sync" "backup_completed" '{"id":"2"}'
    event_bus_emit "session" "session_suspended" '{"id":"3"}'

    _result="$(event_bus_read --source session)"
    _count="$(printf '%s\n' "$_result" | wc -l)"
    _count="$(printf '%s' "$_count" | tr -d ' ')"
    assert_eq "filter by source count" "2" "$_count"
}

# --- AC 11: Read filters by type ---

test_read_filter_type() {
    reset_log
    event_bus_emit "session" "session_created" '{"id":"1"}'
    event_bus_emit "sync" "backup_completed" '{"id":"2"}'
    event_bus_emit "session" "session_created" '{"id":"3"}'

    _result="$(event_bus_read --type session_created)"
    _count="$(printf '%s\n' "$_result" | wc -l)"
    _count="$(printf '%s' "$_count" | tr -d ' ')"
    assert_eq "filter by type count" "2" "$_count"
}

test_read_filter_combined() {
    reset_log
    event_bus_emit "session" "session_created" '{"id":"1"}'
    event_bus_emit "sync" "session_created" '{"id":"2"}'
    event_bus_emit "session" "session_suspended" '{"id":"3"}'

    _result="$(event_bus_read --source session --type session_created)"
    _count="$(printf '%s\n' "$_result" | wc -l)"
    _count="$(printf '%s' "$_count" | tr -d ' ')"
    assert_eq "combined filter count" "1" "$_count"
}

test_read_after() {
    reset_log
    event_bus_emit "session" "event_1" '{}'
    event_bus_emit "session" "event_2" '{}'
    event_bus_emit "session" "event_3" '{}'

    _result="$(event_bus_read --after 2)"
    _count="$(printf '%s\n' "$_result" | wc -l)"
    _count="$(printf '%s' "$_count" | tr -d ' ')"
    assert_eq "read after skips lines" "1" "$_count"
}

test_read_no_match() {
    reset_log
    event_bus_emit "session" "session_created" '{}'
    _result="$(event_bus_read --source nonexistent)"
    assert_eq "no match returns empty" "" "$_result"
}

# --- event_bus_count ---

test_count_empty() {
    reset_log
    _count="$(event_bus_count)"
    assert_eq "count empty log" "0" "$_count"
}

test_count_after_emits() {
    reset_log
    event_bus_emit "a" "b" '{}'
    event_bus_emit "c" "d" '{}'
    event_bus_emit "e" "f" '{}'
    _count="$(event_bus_count)"
    assert_eq "count after 3 emits" "3" "$_count"
}

# --- AC 12: Validate rejects incomplete ---

test_validate_complete() {
    _line='{"_schema_version":"1.0","timestamp":"2026-03-10T21:14:55Z","source":"session","event_type":"session_created","payload":{}}'
    assert_rc "validate complete event" 0 event_bus_validate "$_line"
}

test_validate_missing_schema() {
    _line='{"timestamp":"2026-03-10T21:14:55Z","source":"session","event_type":"test","payload":{}}'
    assert_rc "validate missing schema" 1 event_bus_validate "$_line"
}

test_validate_missing_timestamp() {
    _line='{"_schema_version":"1.0","source":"session","event_type":"test","payload":{}}'
    assert_rc "validate missing timestamp" 1 event_bus_validate "$_line"
}

test_validate_missing_source() {
    _line='{"_schema_version":"1.0","timestamp":"2026-03-10T21:14:55Z","event_type":"test","payload":{}}'
    assert_rc "validate missing source" 1 event_bus_validate "$_line"
}

test_validate_missing_event_type() {
    _line='{"_schema_version":"1.0","timestamp":"2026-03-10T21:14:55Z","source":"session","payload":{}}'
    assert_rc "validate missing event_type" 1 event_bus_validate "$_line"
}

test_validate_missing_payload() {
    _line='{"_schema_version":"1.0","timestamp":"2026-03-10T21:14:55Z","source":"session","event_type":"test"}'
    assert_rc "validate missing payload" 1 event_bus_validate "$_line"
}

test_validate_empty() {
    assert_rc "validate empty string" 1 event_bus_validate ""
}

# --- Emit validation ---

test_emit_missing_source() {
    reset_log
    assert_rc "emit missing source" 1 event_bus_emit "" "test_event"
}

test_emit_missing_type() {
    reset_log
    assert_rc "emit missing type" 1 event_bus_emit "session" ""
}

# --- Fixture file validation ---

test_fixture_events_valid() {
    _fixture="$REPO_ROOT/tests/fixtures/event_samples.jsonl"
    total=$((total + 1))
    if [ ! -f "$_fixture" ]; then
        printf 'FAIL: fixture file missing: %s\n' "$_fixture" >&2
        exit 1
    fi
    _line_num=0
    while IFS= read -r _line; do
        _line_num=$((_line_num + 1))
        if ! event_bus_validate "$_line"; then
            printf 'FAIL: fixture line %d invalid: %s\n' "$_line_num" "$_line" >&2
            exit 1
        fi
    done < "$_fixture"
    passed=$((passed + 1))
}

# --- Run all tests ---

test_init_creates_dir
test_init_creates_file
test_init_idempotent
test_emit_appends_one_line
test_emit_appends_multiple
test_emit_has_schema_version
test_emit_has_timestamp
test_emit_has_source
test_emit_has_event_type
test_emit_has_payload
test_emit_default_payload
test_read_filter_source
test_read_filter_type
test_read_filter_combined
test_read_after
test_read_no_match
test_count_empty
test_count_after_emits
test_validate_complete
test_validate_missing_schema
test_validate_missing_timestamp
test_validate_missing_source
test_validate_missing_event_type
test_validate_missing_payload
test_validate_empty
test_emit_missing_source
test_emit_missing_type
test_fixture_events_valid

printf 'All event_bus tests passed (%d/%d)\n' "$passed" "$total"
