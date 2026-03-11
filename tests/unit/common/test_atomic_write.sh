#!/bin/sh
set -e

# Tests for src/common/atomic_write.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

. "$REPO_ROOT/src/common/atomic_write.sh"

# Create a temp directory for all tests; clean up on exit
TEST_TMP="$(mktemp -d /tmp/test_atomic_write.XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT

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

# --- Tests ---

# AC 13: Basic write works
test_basic_write() {
    _dest="$TEST_TMP/basic.json"
    atomic_write "$_dest" '{"key":"value"}'
    _content="$(cat "$_dest")"
    assert_eq "basic write content" '{"key":"value"}' "$_content"
}

# AC 14: Atomic property — file has correct content after write
test_overwrite() {
    _dest="$TEST_TMP/overwrite.txt"
    atomic_write "$_dest" "original"
    atomic_write "$_dest" "updated"
    _content="$(cat "$_dest")"
    assert_eq "overwrite content" "updated" "$_content"
}

# AC 15: Stdin variant
test_stdin_write() {
    _dest="$TEST_TMP/stdin.json"
    printf '{"from":"stdin"}' | atomic_write_stdin "$_dest"
    _content="$(cat "$_dest")"
    assert_eq "stdin write content" '{"from":"stdin"}' "$_content"
}

# AC 13 variant: File copy variant
test_file_copy() {
    _src="$TEST_TMP/source.txt"
    _dest="$TEST_TMP/dest.txt"
    printf 'file content here' > "$_src"
    atomic_write_file "$_dest" "$_src"
    _content="$(cat "$_dest")"
    assert_eq "file copy content" "file content here" "$_content"
}

# AC 16: Failure — dest directory doesn't exist
test_fail_missing_dir() {
    assert_rc "missing dir returns 1" 1 atomic_write "$TEST_TMP/nonexistent/file.txt" "data"
}

# AC 16: No temp files left after failure
test_fail_no_temp_files() {
    atomic_write "$TEST_TMP/nonexistent_dir/file.txt" "data" 2>/dev/null || true
    _tmp_count="$(find "$TEST_TMP" -name '.tmp.*' 2>/dev/null | wc -l)"
    _tmp_count="$(printf '%s' "$_tmp_count" | tr -d ' ')"
    assert_eq "no leftover temp files" "0" "$_tmp_count"
}

# Empty content is valid
test_empty_content() {
    _dest="$TEST_TMP/empty.txt"
    atomic_write "$_dest" ""
    _content="$(cat "$_dest")"
    assert_eq "empty content" "" "$_content"
}

# Missing dest_path argument
test_fail_no_dest() {
    assert_rc "no dest returns 1" 1 atomic_write "" "data"
}

# atomic_write_file with missing source
test_fail_missing_source() {
    assert_rc "missing source returns 1" 1 atomic_write_file "$TEST_TMP/dest.txt" "$TEST_TMP/no_such_file"
}

# atomic_write_stdin with missing dest dir
test_stdin_fail_missing_dir() {
    printf 'data' | assert_rc "stdin missing dir returns 1" 1 atomic_write_stdin "$TEST_TMP/nonexistent/file.txt"
}

# --- Run all tests ---

test_basic_write
test_overwrite
test_stdin_write
test_file_copy
test_fail_missing_dir
test_fail_no_temp_files
test_empty_content
test_fail_no_dest
test_fail_missing_source
test_stdin_fail_missing_dir

printf 'All atomic_write tests passed (%d/%d)\n' "$passed" "$total"
