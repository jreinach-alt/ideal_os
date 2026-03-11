#!/bin/sh
set -e

# Test: Validate that all canonical directories from the repo structure spec exist.
# Exits 0 if all present, 1 on first missing directory.

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

check_dir() {
    if [ ! -d "$REPO_ROOT/$1" ]; then
        printf 'MISSING: %s\n' "$1" >&2
        exit 1
    fi
}

# docs
check_dir "docs"
check_dir "docs/sprints"
check_dir "docs/architecture"
check_dir "docs/implementation"
check_dir "docs/product"
check_dir "docs/release"

# upstream
check_dir "upstream"
check_dir "upstream/nextui"
check_dir "upstream/nextui/patches"
check_dir "upstream/nextui/notes"
check_dir "upstream/references"

# src
check_dir "src"
check_dir "src/launcher"
check_dir "src/session"
check_dir "src/library"
check_dir "src/emulation"
check_dir "src/system"
check_dir "src/updater"
check_dir "src/tasks"
check_dir "src/sync"
check_dir "src/notifications"
check_dir "src/common"

# config
check_dir "config"
check_dir "config/emulators"
check_dir "config/emulators/systems"
check_dir "config/emulators/cores"
check_dir "config/emulators/hotkeys"
check_dir "config/ui"
check_dir "config/power"
check_dir "config/portmaster"
check_dir "config/updater"
check_dir "config/tasks"
check_dir "config/sync"
check_dir "config/notifications"

# assets
check_dir "assets"
check_dir "assets/boot"
check_dir "assets/branding"
check_dir "assets/themes"
check_dir "assets/icons"
check_dir "assets/boxart-placeholders"

# runtime
check_dir "runtime"
check_dir "runtime/filesystem"
check_dir "runtime/filesystem/overlay"
check_dir "runtime/filesystem/userdata"
check_dir "runtime/filesystem/migrations"
check_dir "runtime/sessions"
check_dir "runtime/sessions/schema"
check_dir "runtime/library"
check_dir "runtime/library/schema"
check_dir "runtime/updater"
check_dir "runtime/updater/schema"
check_dir "runtime/updater/staging"
check_dir "runtime/tasks"
check_dir "runtime/tasks/queues"
check_dir "runtime/sync"
check_dir "runtime/sync/queue"
check_dir "runtime/notifications"
check_dir "runtime/notifications/logs"
check_dir "runtime/events"

# packages
check_dir "packages"
check_dir "packages/base"
check_dir "packages/launcher"
check_dir "packages/session-manager"
check_dir "packages/library"
check_dir "packages/assets"
check_dir "packages/updater"
check_dir "packages/task-scheduler"
check_dir "packages/cloud-sync"
check_dir "packages/notifications"

# scripts
check_dir "scripts"
check_dir "scripts/setup"
check_dir "scripts/build"
check_dir "scripts/package"
check_dir "scripts/ota"
check_dir "scripts/release"

# tools
check_dir "tools"
check_dir "tools/dev"
check_dir "tools/diagnostics"
check_dir "tools/migration"

# tests
check_dir "tests"
check_dir "tests/unit"
check_dir "tests/unit/scaffold"
check_dir "tests/integration"
check_dir "tests/fixtures"
check_dir "tests/manual"

# release
check_dir "release"
check_dir "release/manifests"
check_dir "release/channels"
check_dir "release/notes"
check_dir "release/artifacts"

# .github
check_dir ".github"
check_dir ".github/workflows"
check_dir ".github/ISSUE_TEMPLATE"

printf 'All %d canonical directories present.\n' 93
