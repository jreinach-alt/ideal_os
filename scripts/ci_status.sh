#!/bin/sh
# ci_status.sh — read a commit's CI conclusion over GIT transport.
#
# The CI workflow's `report` job attaches each run's conclusion as a
# git note (refs/notes/ci) on the tested commit. This works where the
# GitHub API/connector does not: dev sessions here have reliable git
# access and nothing else.
#
# Usage: ci_status.sh [commit] [--wait [timeout_seconds]]
#   no note yet -> prints "pending", exit 1
#   success     -> prints the note, exit 0
#   failure     -> prints the note, exit 2
set -eu

SHA="${1:-HEAD}"
WAIT=0
TIMEOUT=600
if [ "${2:-}" = "--wait" ]; then
    WAIT=1
    TIMEOUT="${3:-600}"
fi
SHA=$(git rev-parse "$SHA")

check_once() {
    git fetch -q -f origin '+refs/notes/ci:refs/notes/ci' 2>/dev/null || true
    git notes --ref ci show "$SHA" 2>/dev/null
}

elapsed=0
while :; do
    if note=$(check_once); then
        printf '%s\n' "$note"
        case "$note" in
            success*) exit 0 ;;
            *)        exit 2 ;;
        esac
    fi
    if [ "$WAIT" -ne 1 ] || [ "$elapsed" -ge "$TIMEOUT" ]; then
        printf 'pending (no CI note for %s)\n' "$SHA"
        exit 1
    fi
    sleep 20
    elapsed=$((elapsed + 20))
done
