#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests for src/platforms/nextui/update.sh (git-based OTA)
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

assert_contains_str() {
    local desc haystack needle
    desc="$1"; haystack="$2"; needle="$3"
    case "$haystack" in
        *"$needle"*) passed=$((passed + 1)) ;;
        *) printf 'FAIL: %s\n  [%s] does not contain [%s]\n' "$desc" "$haystack" "$needle" >&2
           failed=$((failed + 1)) ;;
    esac
}

# --- Setup ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# Fixture "project repo" with a tracked PAK at build/Continuity.pak
UPSTREAM="$TEST_TMPDIR/upstream"
mkdir -p "$UPSTREAM"
git -C "$UPSTREAM" init -q -b main
git -C "$UPSTREAM" config user.email t@t
git -C "$UPSTREAM" config user.name t
git -C "$UPSTREAM" config uploadpack.allowFilter true

publish_pak() { # <version> <marker>
    local v m tree
    v="$1"; m="$2"
    tree="$UPSTREAM/build/Continuity.pak"
    mkdir -p "$tree/scripts/core" "$tree/config/platform_maps" "$tree/bin"
    printf '#!/bin/sh\n# marker: %s\ntrue\n' "$m" > "$tree/launch.sh"
    printf '#!/bin/sh\n# core marker: %s\ntrue\n' "$m" > "$tree/scripts/core/pal.sh"
    printf '#!/bin/sh\ntrue\n' > "$tree/scripts/update.sh"
    printf '{}\n' > "$tree/config/platform_maps/nextui.json"
    printf 'BINARYv1' > "$tree/bin/git"
    printf '%s\n' "$v" > "$tree/version.txt"
    printf 'main\n' > "$tree/ota_channel.txt"
    printf '%s %s %s\n' "$(sha256sum "$tree/bin/git" | cut -d' ' -f1)" \
        "$(wc -c < "$tree/bin/git")" "bin/git" > "$tree/checksums.txt"
    git -C "$UPSTREAM" add -A
    git -C "$UPSTREAM" commit -qm "publish $v"
}
publish_pak "0.1.0-v2" "second-build"

# Device-side fake live PAK + state home
PAK="$TEST_TMPDIR/live-pak"
HOME_DIR="$TEST_TMPDIR/chome"
mkdir -p "$PAK/scripts/core" "$PAK/bin"
printf '#!/bin/sh\n# marker: first-build\ntrue\n' > "$PAK/launch.sh"
printf '0.1.0-v1\n' > "$PAK/version.txt"
printf 'main\n' > "$PAK/ota_channel.txt"
printf 'BINARYv1' > "$PAK/bin/git"

CONTINUITY_PAK_DIR="$PAK"
CONTINUITY_HOME="$HOME_DIR"
CONTINUITY_OTA_URL="file://$UPSTREAM"
CONTINUITY_GIT_BIN="git"

. "$PROJECT_ROOT/src/platforms/nextui/update.sh"

# --- Test 1: update detected on fresh setup ---
rc=0; info=$(ota_check) || rc=$?
assert_eq "update detected" "0" "$rc"
assert_contains_str "new version reported" "$info" "0.1.0-v2"
commit="${info##* }"
assert_eq "commit is 40 hex chars" "40" "${#commit}"

# --- Test 2: apply updates scripts, version, state marker ---
rc=0; ota_apply "$commit" || rc=$?
assert_eq "apply succeeds" "0" "$rc"
assert_contains_str "launch.sh updated" "$(cat "$PAK/launch.sh")" "second-build"
assert_contains_str "core module updated" "$(cat "$PAK/scripts/core/pal.sh")" "second-build"
assert_eq "version updated" "0.1.0-v2" "$(cat "$PAK/version.txt")"
assert_eq "commit recorded" "$commit" "$(cat "$HOME_DIR/.ota_commit")"

# --- Test 3: up to date afterwards ---
rc=0; ota_check >/dev/null || rc=$?
assert_eq "no update when current" "1" "$rc"

# --- Test 4: next published build detected and applied via ota_run ---
publish_pak "0.1.0-v3" "third-build"
rc=0; ota_run || rc=$?
assert_eq "ota_run applies new build" "0" "$rc"
assert_eq "version now v3" "0.1.0-v3" "$(cat "$PAK/version.txt")"
assert_contains_str "third marker present" "$(cat "$PAK/launch.sh")" "third-build"

# --- Test 5: unchanged binary is not rewritten (size probe) ---
before=$(stat -c %Y "$PAK/bin/git" 2>/dev/null || date +%s)
sleep 1
publish_pak "0.1.0-v4" "fourth-build"
rc=0; ota_run || rc=$?
assert_eq "v4 applied" "0.1.0-v4" "$(cat "$PAK/version.txt")"
after=$(stat -c %Y "$PAK/bin/git" 2>/dev/null || printf '%s' "$before")
assert_eq "same-size binary untouched" "$before" "$after"

# --- Test 6: corrupt fetched tree refused ---
CORRUPT="$TEST_TMPDIR/corrupt-tree"
mkdir -p "$CORRUPT/scripts"
printf '#!/bin/sh\r\ntrue\r\n' > "$CORRUPT/launch.sh"
rc=0; ota_verify_tree "$CORRUPT" || rc=$?
assert_eq "CRLF tree refused" "1" "$rc"

# --- Test 7: checksum-size mismatch in fetched tree refused ---
BADSIZE="$TEST_TMPDIR/badsize-tree"
mkdir -p "$BADSIZE/scripts" "$BADSIZE/bin"
printf '#!/bin/sh\ntrue\n' > "$BADSIZE/launch.sh"
printf 'short' > "$BADSIZE/bin/git"
printf 'deadbeef 999 bin/git\n' > "$BADSIZE/checksums.txt"
rc=0; ota_verify_tree "$BADSIZE" || rc=$?
assert_eq "size-mismatched tree refused" "1" "$rc"

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
