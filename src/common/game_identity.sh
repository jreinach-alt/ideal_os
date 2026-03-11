#!/bin/sh
set -e

# Ideal OS — Game Identity Model
# Provides game_id format (system:game_name), system taxonomy,
# ROM/save path conventions, and hash generation.

# Guard against double-sourcing
if [ -n "$_GAME_IDENTITY_LOADED" ]; then
    return 0
fi
readonly _GAME_IDENTITY_LOADED=1

# Supported systems — space-delimited flat list (no arrays in ash)
readonly SUPPORTED_SYSTEMS="snes gba gb gbc nes n64 nds psx psp md sms gg tg16 pce a26 arcade mame fbneo"

# game_id_system_supported <system>
#   Returns 0 if system is in the taxonomy, 1 otherwise.
game_id_system_supported() {
    _gi_sys="$1"
    if [ -z "$_gi_sys" ]; then
        return 1
    fi
    # Word-boundary match in the space-delimited list
    case " $SUPPORTED_SYSTEMS " in
        *" $_gi_sys "*) return 0 ;;
        *) return 1 ;;
    esac
}

# game_id_parse_system <game_id>
#   Print the system portion of a game_id to stdout.
#   Returns 1 if game_id has no colon.
game_id_parse_system() {
    _gi_id="$1"
    case "$_gi_id" in
        *:*) printf '%s' "${_gi_id%%:*}" ;;
        *)
            printf 'game_id_parse_system: error: invalid game_id: %s\n' "$_gi_id" >&2
            return 1
            ;;
    esac
}

# game_id_parse_name <game_id>
#   Print the game name portion of a game_id to stdout.
#   Returns 1 if game_id has no colon.
game_id_parse_name() {
    _gi_id="$1"
    case "$_gi_id" in
        *:*) printf '%s' "${_gi_id#*:}" ;;
        *)
            printf 'game_id_parse_name: error: invalid game_id: %s\n' "$_gi_id" >&2
            return 1
            ;;
    esac
}

# game_id_validate <game_id>
#   Returns 0 if valid, 1 if invalid.
#   Valid: exactly one colon, non-empty system and name, system in taxonomy.
game_id_validate() {
    _gi_id="$1"

    # Must not be empty
    if [ -z "$_gi_id" ]; then
        return 1
    fi

    # Must contain at least one colon
    case "$_gi_id" in
        *:*) ;;
        *) return 1 ;;
    esac

    # Extract system (before first colon) and name (after first colon)
    _gi_sys="${_gi_id%%:*}"
    _gi_name="${_gi_id#*:}"

    # System must not be empty
    if [ -z "$_gi_sys" ]; then
        return 1
    fi

    # Name must not be empty
    if [ -z "$_gi_name" ]; then
        return 1
    fi

    # Name must not contain colons (i.e., only one colon in the whole id)
    case "$_gi_name" in
        *:*) return 1 ;;
    esac

    # System must be in taxonomy
    if ! game_id_system_supported "$_gi_sys"; then
        return 1
    fi

    return 0
}

# game_id_create <system> <game_name>
#   Print a game_id to stdout. Does not validate — caller is responsible.
game_id_create() {
    _gi_sys="$1"
    _gi_name="$2"
    printf '%s:%s' "$_gi_sys" "$_gi_name"
}

# game_id_rom_dir <game_id>
#   Print ROM directory path for the game's system.
#   NextUI convention: /Roms/<SYSTEM_UPPER>
game_id_rom_dir() {
    _gi_id="$1"
    _gi_sys="$(game_id_parse_system "$_gi_id")" || return 1
    _gi_upper="$(printf '%s' "$_gi_sys" | tr '[:lower:]' '[:upper:]')"
    printf '/Roms/%s' "$_gi_upper"
}

# game_id_save_dir <game_id>
#   Print save directory path for the game's system.
#   Convention: /userdata/saves/<system>
game_id_save_dir() {
    _gi_id="$1"
    _gi_sys="$(game_id_parse_system "$_gi_id")" || return 1
    printf '/userdata/saves/%s' "$_gi_sys"
}

# game_id_hash <file_path>
#   Print SHA-256 hash of the file to stdout.
#   Returns 1 if file not readable or sha256sum not available.
game_id_hash() {
    _gi_file="$1"

    if [ -z "$_gi_file" ] || [ ! -r "$_gi_file" ]; then
        printf 'game_id_hash: error: file not readable: %s\n' "$_gi_file" >&2
        return 1
    fi

    _gi_hash=""
    if command -v sha256sum >/dev/null 2>&1; then
        _gi_hash="$(sha256sum "$_gi_file" | cut -d ' ' -f 1)"
    elif busybox sha256sum "$_gi_file" >/dev/null 2>&1; then
        _gi_hash="$(busybox sha256sum "$_gi_file" | cut -d ' ' -f 1)"
    else
        printf 'game_id_hash: error: sha256sum not available\n' >&2
        return 1
    fi

    printf '%s' "$_gi_hash"
}

# game_id_short_hash <file_path>
#   Print first 8 characters of SHA-256 hash to stdout.
game_id_short_hash() {
    _gi_file="$1"
    _gi_full="$(game_id_hash "$_gi_file")" || return 1
    printf '%s' "$_gi_full" | cut -c 1-8
}
