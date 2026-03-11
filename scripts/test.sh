#!/bin/sh
set -e

# Ideal OS Test Runner
# Discovers and runs test files, reports pass/fail results.
# Compatible with BusyBox ash.

readonly REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    printf 'Usage: %s [OPTIONS] [TEST_FILE]\n' "$0"
    printf '\n'
    printf 'Run Ideal OS tests.\n'
    printf '\n'
    printf 'Options:\n'
    printf '  --help    Show this help message\n'
    printf '\n'
    printf 'If TEST_FILE is given, run only that test.\n'
    printf 'If no arguments, discover and run all tests.\n'
}

discover_tests() {
    find "$REPO_ROOT/tests/unit" "$REPO_ROOT/tests/integration" \
        -name 'test_*.sh' -type f 2>/dev/null | sort
}

run_test() {
    test_file="$1"
    rel_path="${test_file#"$REPO_ROOT"/}"

    if busybox ash "$test_file" >/dev/null 2>&1; then
        printf '[PASS] %s\n' "$rel_path"
        return 0
    else
        printf '[FAIL] %s\n' "$rel_path"
        return 1
    fi
}

# Parse arguments
case "${1:-}" in
    --help)
        usage
        exit 0
        ;;
esac

# Determine which tests to run
if [ $# -gt 0 ]; then
    test_file="$1"
    if [ ! -f "$test_file" ]; then
        printf 'Error: test file not found: %s\n' "$test_file" >&2
        exit 1
    fi
    # Normalize to absolute path
    case "$test_file" in
        /*) ;;
        *) test_file="$(pwd)/$test_file" ;;
    esac
    test_files="$test_file"
else
    test_files="$(discover_tests)"
    if [ -z "$test_files" ]; then
        printf 'No tests found.\n'
        exit 0
    fi
fi

passed=0
failed=0
total=0

printf '%s\n' "$test_files" | while read -r tf; do
    total=$((total + 1))
    if run_test "$tf"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi

    # Write counters to temp file (subshell workaround)
    printf '%d %d %d\n' "$passed" "$failed" "$total" > "$REPO_ROOT/.test_counts"
done

# Read final counters
if [ -f "$REPO_ROOT/.test_counts" ]; then
    read -r passed failed total < "$REPO_ROOT/.test_counts"
    rm -f "$REPO_ROOT/.test_counts"
fi

printf '\nResults: %d passed, %d failed, %d total\n' "$passed" "$failed" "$total"

if [ "$failed" -gt 0 ]; then
    exit 1
fi

exit 0
