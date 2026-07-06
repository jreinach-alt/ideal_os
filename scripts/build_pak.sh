#!/bin/sh
# Assemble Continuity.pak from source files and cross-compiled git binary.
# Output: build/Continuity.pak/ — ready to copy to SD card Tools/ directory.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PAK_DIR="$PROJECT_ROOT/build/Continuity.pak"
GIT_BIN="$PROJECT_ROOT/build/aarch64/prefix/bin/git"
PLATFORM_DIR="$PROJECT_ROOT/src/platforms/nextui"
CORE_DIR="$PROJECT_ROOT/src/core"
CONFIG_DIR="$PROJECT_ROOT/config"

# Fall back to the previously-bundled git binary if a fresh cross-compile
# isn't available. Lets us iterate on launch.sh / scripts without rebuilding
# git from scratch. Stage it outside $PAK_DIR so the rm -rf below can't eat it.
if [ ! -f "$GIT_BIN" ] && [ -f "$PAK_DIR/bin/git" ]; then
    GIT_BIN="$PROJECT_ROOT/build/git.preserved"
    cp "$PAK_DIR/bin/git" "$GIT_BIN"
fi

if [ ! -f "$GIT_BIN" ]; then
    printf 'ERROR: Git binary not found at %s or %s\n' \
        "$PROJECT_ROOT/build/aarch64/prefix/bin/git" "$PAK_DIR/bin/git" >&2
    printf 'Run scripts/build_git.sh first.\n' >&2
    exit 1
fi

# Clean and create PAK structure
rm -rf "$PAK_DIR"
mkdir -p "$PAK_DIR/bin"
mkdir -p "$PAK_DIR/scripts/core"
mkdir -p "$PAK_DIR/config/platform_maps"

# ── Copy files ───────────────────────────────────────────────────────

# Git binary
cp "$GIT_BIN" "$PAK_DIR/bin/git"

# PAK root: launch.sh (Tool menu entry point)
cp "$PLATFORM_DIR/launch.sh" "$PAK_DIR/launch.sh"

# Scripts: daemon and platform modules
cp "$PLATFORM_DIR/continuity_daemon.sh" "$PAK_DIR/scripts/"
cp "$PLATFORM_DIR/pal_nextui.sh" "$PAK_DIR/scripts/"
cp "$PLATFORM_DIR/enroll_sd_card.sh" "$PAK_DIR/scripts/"
cp "$PLATFORM_DIR/update.sh" "$PAK_DIR/scripts/"

# Core modules
for f in "$CORE_DIR"/*.sh; do
    [ -f "$f" ] && cp "$f" "$PAK_DIR/scripts/core/"
done

# Config
cp "$CONFIG_DIR/platform_maps/nextui.json" "$PAK_DIR/config/platform_maps/"

# System taxonomy (needed by path_mapper)
cp "$CONFIG_DIR/system_taxonomy.json" "$PAK_DIR/config/"

# Version file
printf '%s\n' "0.1.0-$(date '+%Y%m%d')" > "$PAK_DIR/version.txt"

# ── Permissions ──────────────────────────────────────────────────────

find "$PAK_DIR" -name "*.sh" -exec chmod +x {} +
chmod +x "$PAK_DIR/bin/git"

# ── Line-ending sanity check ─────────────────────────────────────────
# CRLF in any shell script makes the kernel exec fail silently on the
# device (it reads `#!/bin/sh\r` as the interpreter path). Catch this
# at build time, not after the user has copied the PAK to their SD card.

cr=$(printf '\r')
crlf_files=$(find "$PAK_DIR" \( -name '*.sh' -o -name '*.json' -o -name '*.txt' \) \
                 -exec grep -lU "$cr" {} + 2>/dev/null || true)
if [ -n "$crlf_files" ]; then
    printf 'ERROR: CRLF line endings detected in PAK files:\n' >&2
    printf '  %s\n' $crlf_files >&2
    printf 'NextUI cannot exec scripts with CRLF; fix the source and rebuild.\n' >&2
    exit 1
fi

# ── Summary ──────────────────────────────────────────────────────────

file_count=$(find "$PAK_DIR" -type f | wc -l)
total_size=$(du -sh "$PAK_DIR" | cut -f1)

printf '\n=== Continuity.pak assembled ===\n\n'
printf '  Location: %s\n' "$PAK_DIR"
printf '  Files:    %s\n' "$file_count"
printf '  Size:     %s\n' "$total_size"
printf '\n  Structure:\n'
find "$PAK_DIR" -type f | sort | while read -r f; do
    printf '    %s\n' "${f#"$PROJECT_ROOT"/build/}"
done

printf '\n  Deploy: cp -r %s /path/to/sdcard/Tools/tg5040/\n\n' "$PAK_DIR"
