#!/bin/sh
set -e

# Ideal OS — Atomic Write Helper
# Write to temp file → fsync → rename into place.
# Ensures readers never see partial content at the destination path.

# Guard against double-sourcing
if [ -n "$_ATOMIC_WRITE_LOADED" ]; then
    return 0
fi
readonly _ATOMIC_WRITE_LOADED=1

# Track whether we've warned about fsync fallback
_atomic_write_fsync_warned=0

# _atomic_write_fsync <file>
#   Attempt fsync on a single file. Fall back to full sync if unavailable.
_atomic_write_fsync() {
    _aw_file="$1"

    if busybox fsync "$_aw_file" 2>/dev/null; then
        return 0
    fi

    if [ "$_atomic_write_fsync_warned" -eq 0 ]; then
        printf 'atomic_write: warning: fsync not available, falling back to sync\n' >&2
        _atomic_write_fsync_warned=1
    fi

    sync
}

# _atomic_write_cleanup <tmp_file>
#   Remove temp file on failure. Silent if file doesn't exist.
_atomic_write_cleanup() {
    rm -f "$1"
}

# atomic_write <dest_path> <content>
#   Write content string to dest_path atomically.
#   Parent directory of dest_path must exist.
#   Returns 0 on success, 1 on failure (with message to stderr).
atomic_write() {
    _aw_dest="$1"
    _aw_content="$2"

    if [ -z "$_aw_dest" ]; then
        printf 'atomic_write: error: dest_path is required\n' >&2
        return 1
    fi

    _aw_dir="$(dirname "$_aw_dest")"
    if [ ! -d "$_aw_dir" ]; then
        printf 'atomic_write: error: directory does not exist: %s\n' "$_aw_dir" >&2
        return 1
    fi

    _aw_tmp="$(mktemp "$_aw_dir/.tmp.XXXXXX")" || {
        printf 'atomic_write: error: failed to create temp file in %s\n' "$_aw_dir" >&2
        return 1
    }

    if ! printf '%s' "$_aw_content" > "$_aw_tmp"; then
        printf 'atomic_write: error: failed to write to temp file\n' >&2
        _atomic_write_cleanup "$_aw_tmp"
        return 1
    fi

    _atomic_write_fsync "$_aw_tmp"

    if ! mv -f "$_aw_tmp" "$_aw_dest"; then
        printf 'atomic_write: error: failed to rename temp file to %s\n' "$_aw_dest" >&2
        _atomic_write_cleanup "$_aw_tmp"
        return 1
    fi

    return 0
}

# atomic_write_file <dest_path> <source_path>
#   Copy source_path to dest_path atomically.
#   Parent directory of dest_path must exist. source_path must be readable.
#   Returns 0 on success, 1 on failure.
atomic_write_file() {
    _aw_dest="$1"
    _aw_src="$2"

    if [ -z "$_aw_dest" ]; then
        printf 'atomic_write_file: error: dest_path is required\n' >&2
        return 1
    fi

    if [ -z "$_aw_src" ] || [ ! -r "$_aw_src" ]; then
        printf 'atomic_write_file: error: source file not readable: %s\n' "$_aw_src" >&2
        return 1
    fi

    _aw_dir="$(dirname "$_aw_dest")"
    if [ ! -d "$_aw_dir" ]; then
        printf 'atomic_write_file: error: directory does not exist: %s\n' "$_aw_dir" >&2
        return 1
    fi

    _aw_tmp="$(mktemp "$_aw_dir/.tmp.XXXXXX")" || {
        printf 'atomic_write_file: error: failed to create temp file in %s\n' "$_aw_dir" >&2
        return 1
    }

    if ! cp "$_aw_src" "$_aw_tmp"; then
        printf 'atomic_write_file: error: failed to copy source to temp file\n' >&2
        _atomic_write_cleanup "$_aw_tmp"
        return 1
    fi

    _atomic_write_fsync "$_aw_tmp"

    if ! mv -f "$_aw_tmp" "$_aw_dest"; then
        printf 'atomic_write_file: error: failed to rename temp file to %s\n' "$_aw_dest" >&2
        _atomic_write_cleanup "$_aw_tmp"
        return 1
    fi

    return 0
}

# atomic_write_stdin <dest_path>
#   Read stdin and write to dest_path atomically.
#   Parent directory of dest_path must exist.
#   Returns 0 on success, 1 on failure.
atomic_write_stdin() {
    _aw_dest="$1"

    if [ -z "$_aw_dest" ]; then
        printf 'atomic_write_stdin: error: dest_path is required\n' >&2
        return 1
    fi

    _aw_dir="$(dirname "$_aw_dest")"
    if [ ! -d "$_aw_dir" ]; then
        printf 'atomic_write_stdin: error: directory does not exist: %s\n' "$_aw_dir" >&2
        return 1
    fi

    _aw_tmp="$(mktemp "$_aw_dir/.tmp.XXXXXX")" || {
        printf 'atomic_write_stdin: error: failed to create temp file in %s\n' "$_aw_dir" >&2
        return 1
    }

    if ! cat > "$_aw_tmp"; then
        printf 'atomic_write_stdin: error: failed to write stdin to temp file\n' >&2
        _atomic_write_cleanup "$_aw_tmp"
        return 1
    fi

    _atomic_write_fsync "$_aw_tmp"

    if ! mv -f "$_aw_tmp" "$_aw_dest"; then
        printf 'atomic_write_stdin: error: failed to rename temp file to %s\n' "$_aw_dest" >&2
        _atomic_write_cleanup "$_aw_tmp"
        return 1
    fi

    return 0
}
