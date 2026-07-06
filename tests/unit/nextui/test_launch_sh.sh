#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Unit tests for src/platforms/nextui/launch.sh (Tool PAK entry point)
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

assert_contains() {
    local desc filepath needle
    desc="$1"; filepath="$2"; needle="$3"
    if grep -qF -e "$needle" "$filepath" 2>/dev/null; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  %s does not contain: %s\n' "$desc" "$filepath" "$needle" >&2
        failed=$((failed + 1))
    fi
}

# --- Setup ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Fake PAK dir with the real launch.sh
PAK="$TEST_TMPDIR/Continuity.pak"
mkdir -p "$PAK"
cp "$PROJECT_ROOT/src/platforms/nextui/launch.sh" "$PAK/launch.sh"
chmod +x "$PAK/launch.sh"

# show2.elf stub: appends its argv to a capture file (one call per line)
STUB_BIN="$TEST_TMPDIR/bin"
mkdir -p "$STUB_BIN"
SHOW2_CALLS="$TEST_TMPDIR/show2_calls.txt"
export SHOW2_CALLS
cat > "$STUB_BIN/show2.elf" <<'EOF'
#!/bin/sh
printf '%s ' "$@" >> "${SHOW2_CALLS:?}"
printf '\n' >> "$SHOW2_CALLS"
exit 0
EOF
chmod +x "$STUB_BIN/show2.elf"

# Sandboxed environment for every run
SDROOT="$TEST_TMPDIR/sdcard"
USERDATA="$SDROOT/.userdata/tg5040"
CHOME="$SDROOT/.continuity"
mkdir -p "$SDROOT"

run_launch() {
    CONTINUITY_SD_ROOT="$SDROOT" CONTINUITY_HOME="$CHOME" \
    USERDATA_PATH="$USERDATA" PATH="$STUB_BIN:$PATH" \
        busybox ash "$PAK/launch.sh"
}

# --- Test 1: first run installs the boot hook ---

# Pre-existing auto.sh content must be preserved
mkdir -p "$USERDATA"
printf '#!/bin/sh\necho preexisting\n' > "$USERDATA/auto.sh"

rc=0; run_launch || rc=$?
assert_eq "first run exits 0" "0" "$rc"

AUTO_SH="$USERDATA/auto.sh"
assert_file_exists "auto.sh exists" "$AUTO_SH"
assert_contains "auto.sh keeps pre-existing content" "$AUTO_SH" "echo preexisting"
assert_contains "auto.sh has daemon hook" "$AUTO_SH" "scripts/continuity_daemon.sh"
assert_contains "daemon hook detaches stdio" "$AUTO_SH" "</dev/null >/dev/null 2>&1 &"
assert_file_exists "hook marker created" "$CHOME/.hook_installed"
assert_file_exists "breadcrumb log created" "$PAK/launch.log"
assert_eq "breadcrumb has one line" "1" "$(wc -l < "$PAK/launch.log")"
assert_contains "first-run message shown" "$SHOW2_CALLS" "Installed! Reboot to start daemon."
assert_contains "first-run message times out" "$SHOW2_CALLS" "--timeout=3"

# --- Test 2: second run is idempotent, shows status ---

: > "$SHOW2_CALLS"
rc=0; run_launch || rc=$?
assert_eq "second run exits 0" "0" "$rc"

hook_count=$(grep -cF "continuity_daemon.sh" "$AUTO_SH")
assert_eq "hook not duplicated" "1" "$hook_count"
assert_eq "breadcrumb has two lines" "2" "$(wc -l < "$PAK/launch.log")"
assert_contains "no-daemon-yet status shown" "$SHOW2_CALLS" "Daemon not started yet. Reboot device."

# --- Test 3: status run surfaces last sync line from the daemon log ---

printf '[2026-07-06 10:00:00] info: Sync complete — 2 saves pushed\n' \
    > "$CHOME/continuity.log"
: > "$SHOW2_CALLS"
rc=0; run_launch || rc=$?
assert_eq "status run exits 0" "0" "$rc"
assert_contains "last sync status shown" "$SHOW2_CALLS" "Sync complete"

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
