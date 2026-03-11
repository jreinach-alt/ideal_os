#!/bin/sh
set -e

# Tests for src/common/game_identity.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

. "$REPO_ROOT/src/common/game_identity.sh"

TEST_TMP="$(mktemp -d /tmp/test_game_identity.XXXXXX)"
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

# --- AC 1: Parse system ---

test_parse_system() {
    _result="$(game_id_parse_system "snes:super_metroid")"
    assert_eq "parse system basic" "snes" "$_result"
}

test_parse_system_with_spaces() {
    _result="$(game_id_parse_system "gba:Metroid Fusion (U)")"
    assert_eq "parse system with spaces" "gba" "$_result"
}

test_parse_system_no_colon() {
    assert_rc "parse system no colon" 1 game_id_parse_system "nocolon"
}

# --- AC 2: Parse name ---

test_parse_name() {
    _result="$(game_id_parse_name "snes:super_metroid")"
    assert_eq "parse name basic" "super_metroid" "$_result"
}

test_parse_name_with_spaces() {
    _result="$(game_id_parse_name "gba:Metroid Fusion (U)")"
    assert_eq "parse name with spaces" "Metroid Fusion (U)" "$_result"
}

test_parse_name_no_colon() {
    assert_rc "parse name no colon" 1 game_id_parse_name "nocolon"
}

# --- AC 3: Validate rejects bad IDs ---

test_validate_empty() {
    assert_rc "validate empty" 1 game_id_validate ""
}

test_validate_no_colon() {
    assert_rc "validate no colon" 1 game_id_validate "nocolon"
}

test_validate_multiple_colons() {
    assert_rc "validate multiple colons" 1 game_id_validate "bad:name:extra"
}

test_validate_empty_system() {
    assert_rc "validate empty system" 1 game_id_validate ":game_name"
}

test_validate_empty_name() {
    assert_rc "validate empty name" 1 game_id_validate "snes:"
}

test_validate_unknown_system() {
    assert_rc "validate unknown system" 1 game_id_validate "dreamcast:sonic"
}

# --- AC 4: Validate accepts good IDs ---

test_validate_snes() {
    assert_rc "validate snes" 0 game_id_validate "snes:super_metroid"
}

test_validate_gba() {
    assert_rc "validate gba" 0 game_id_validate "gba:metroid_fusion"
}

test_validate_psx() {
    assert_rc "validate psx" 0 game_id_validate "psx:final_fantasy_7"
}

test_validate_arcade() {
    assert_rc "validate arcade" 0 game_id_validate "arcade:street_fighter_2"
}

test_validate_name_with_spaces() {
    assert_rc "validate name with spaces" 0 game_id_validate "gba:Metroid Fusion (U)"
}

test_validate_name_with_dots() {
    assert_rc "validate name with dots" 0 game_id_validate "nes:Dr. Mario"
}

# --- AC 5: Path helpers ---

test_rom_dir() {
    _result="$(game_id_rom_dir "snes:super_metroid")"
    assert_eq "rom dir snes" "/Roms/SNES" "$_result"
}

test_rom_dir_gba() {
    _result="$(game_id_rom_dir "gba:metroid_fusion")"
    assert_eq "rom dir gba" "/Roms/GBA" "$_result"
}

test_save_dir() {
    _result="$(game_id_save_dir "snes:super_metroid")"
    assert_eq "save dir snes" "/userdata/saves/snes" "$_result"
}

test_save_dir_psx() {
    _result="$(game_id_save_dir "psx:ff7")"
    assert_eq "save dir psx" "/userdata/saves/psx" "$_result"
}

# --- AC 6: Hash generation ---

test_hash() {
    # Create a known file and verify hash
    printf 'hello' > "$TEST_TMP/hashtest.txt"
    _expected="2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    _result="$(game_id_hash "$TEST_TMP/hashtest.txt")"
    assert_eq "sha256 hash" "$_expected" "$_result"
}

test_short_hash() {
    printf 'hello' > "$TEST_TMP/hashtest2.txt"
    _result="$(game_id_short_hash "$TEST_TMP/hashtest2.txt")"
    assert_eq "short hash" "2cf24dba" "$_result"
}

test_hash_missing_file() {
    assert_rc "hash missing file" 1 game_id_hash "$TEST_TMP/no_such_file"
}

test_hash_empty_arg() {
    assert_rc "hash empty arg" 1 game_id_hash ""
}

# --- System taxonomy ---

test_system_supported_yes() {
    assert_rc "snes supported" 0 game_id_system_supported "snes"
}

test_system_supported_no() {
    assert_rc "dreamcast not supported" 1 game_id_system_supported "dreamcast"
}

test_system_supported_empty() {
    assert_rc "empty not supported" 1 game_id_system_supported ""
}

# --- game_id_create ---

test_create() {
    _result="$(game_id_create "snes" "super_metroid")"
    assert_eq "create game_id" "snes:super_metroid" "$_result"
}

# --- Run all tests ---

test_parse_system
test_parse_system_with_spaces
test_parse_system_no_colon
test_parse_name
test_parse_name_with_spaces
test_parse_name_no_colon
test_validate_empty
test_validate_no_colon
test_validate_multiple_colons
test_validate_empty_system
test_validate_empty_name
test_validate_unknown_system
test_validate_snes
test_validate_gba
test_validate_psx
test_validate_arcade
test_validate_name_with_spaces
test_validate_name_with_dots
test_rom_dir
test_rom_dir_gba
test_save_dir
test_save_dir_psx
test_hash
test_short_hash
test_hash_missing_file
test_hash_empty_arg
test_system_supported_yes
test_system_supported_no
test_system_supported_empty
test_create

printf 'All game_identity tests passed (%d/%d)\n' "$passed" "$total"
