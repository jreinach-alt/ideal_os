# Sprint 0.2 — Core Sync Engine (Shell)

**Status:** Draft — Awaiting Approval
**Date:** 2026-03-13
**Dependencies:** Sprint 0.1 (complete — taxonomy, platform maps, test harness)

## Goal

Implement the four core shell modules that all platform clients build on: path mapping, change detection, sync engine (git operations), and WiFi monitoring. Everything in `src/core/` must be BusyBox ash compatible.

---

## Reference Specs

- `docs/design/architecture.md` — component descriptions and interfaces
- `config/system_taxonomy.json` — canonical system names
- `config/platform_maps/*.json` — per-platform path mappings

---

## Scope

### 1. Path Mapper (`src/core/path_mapper.sh`)

Translates between platform-specific save paths and canonical repo paths.

**Functions:**

| Function | Signature | Description |
|----------|-----------|-------------|
| `pm_load_platform_map` | `(platform_map_file)` | Parse platform map JSON, set module globals for `saves_root`, `save_extension`, and system path mappings |
| `pm_local_to_repo` | `(local_path)` | Convert a local device path (e.g. `/mnt/SDCARD/Saves/SFC/super_metroid.srm`) to a repo-relative path (e.g. `snes/super_metroid.srm`) |
| `pm_repo_to_local` | `(repo_path)` | Convert a repo-relative path back to a local device path |
| `pm_list_watched_dirs` | `()` | List all local save directories that should be monitored (constructed from `saves_root` + each system path) |

**Implementation notes:**
- JSON parsing via `grep`/`sed` — no `jq` available on constrained devices.
- The mapper builds an in-memory lookup (shell variables or temp file) from the platform map JSON on load.
- Unknown system directories are ignored (logged to stderr, not fatal).
- Paths with spaces must be handled correctly (RetroArch Android has them: `"Nintendo - Game Boy"`).

---

### 2. Change Detector (`src/core/change_detector.sh`)

Polls for modified `.srm` files using `find -newer`.

**Functions:**

| Function | Signature | Description |
|----------|-----------|-------------|
| `cd_init` | `(marker_dir)` | Create marker directory and initial marker file if it doesn't exist |
| `cd_detect_changes` | `(search_dirs, marker_file)` | Return list of `.srm` files modified since marker timestamp, one per line |
| `cd_update_marker` | `(marker_file)` | Touch the marker file to current timestamp |

**Implementation notes:**
- `search_dirs` is a newline-delimited list of directories (from `pm_list_watched_dirs`).
- Uses `find <dir> -name "*.srm" -newer <marker> -type f` for each directory.
- Directories that don't exist are silently skipped (a system with no saves yet).
- Marker file lives outside the repo clone (e.g. `/tmp/continuity_marker`).
- The caller is responsible for calling `cd_update_marker` after processing changes (not automatic — allows retry on failure).

---

### 3. Sync Engine (`src/core/sync_engine.sh`)

Git operations layer: pull, stage, commit, push.

**Functions:**

| Function | Signature | Description |
|----------|-----------|-------------|
| `se_init` | `(repo_dir, device_name)` | Set the repo directory and device name for commit metadata |
| `se_pull` | `()` | `git pull --ff-only origin main`. Returns 0 on success, 1 on conflict (diverged), 2 on network error |
| `se_stage_files` | `(file_list)` | `git add` each repo-relative path in the newline-delimited list |
| `se_commit` | `(file_list)` | Commit staged files with auto-generated message including system/filename, device name, and ISO 8601 timestamp |
| `se_push` | `()` | `git push origin main`. Retries with exponential backoff (2s, 4s, 8s, 16s) on network failure. Returns 0 on success, 1 on persistent failure |
| `se_has_staged_changes` | `()` | Returns 0 if there are staged changes, 1 if clean |
| `se_has_unpushed_commits` | `()` | Returns 0 if local is ahead of remote, 1 if up to date |

**Implementation notes:**
- All git commands run with `GIT_DIR` and `GIT_WORK_TREE` pointing to the repo clone, not the current working directory.
- `se_pull` uses `--ff-only` to avoid auto-merge. If fast-forward fails, it returns 1 so the caller (or a future conflict handler) can deal with it. Sprint 0.2 does NOT implement conflict resolution — that's Sprint 0.3.
- Commit message format:
  ```
  <system>/<filename> updated

  device: <device_name>
  timestamp: <ISO 8601>
  ```
  If multiple files changed, the subject line lists the count: `3 saves updated`.
- `se_push` captures stderr to distinguish network errors (retry) from other failures (abort).
- On constrained devices, git may be BusyBox `git` or a minimal git binary. Avoid git features beyond basic add/commit/push/pull.

---

### 4. WiFi Monitor (`src/core/wifi_monitor.sh`)

Connectivity check before network operations.

**Functions:**

| Function | Signature | Description |
|----------|-----------|-------------|
| `wm_is_online` | `()` | Returns 0 if network-connected, 1 if offline |

**Implementation notes:**
- Primary check: `ping -c 1 -W 3 github.com >/dev/null 2>&1`.
- Fallback if `ping` is unavailable or blocked: attempt a TCP connection via `/dev/tcp` or `wget --spider`.
- Does NOT check for WiFi specifically — just general network reachability.
- Designed to be called before `se_push` and `se_pull`.

---

## Out of Scope

These are explicitly **not** part of Sprint 0.2:

| Item | Sprint |
|------|--------|
| Conflict detection and resolution | 0.3 |
| Enrollment / credential import | 1.1 |
| Platform daemon loops (NextUI, RetroDeck) | 1.2+ |
| `.continuity/` metadata (config.json, device JSON) | 1.1 |
| inotify-based change detection | 2.2 (RetroDeck) |
| Android FileObserver | 3.2 |

`se_pull` returns a distinct code on divergence but does not resolve it — Sprint 0.3's conflict handler will consume that signal.

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/core/path_mapper.sh` | Platform path ↔ repo path translation |
| `src/core/change_detector.sh` | `find -newer` polling for modified `.srm` files |
| `src/core/sync_engine.sh` | Git add/commit/push/pull operations |
| `src/core/wifi_monitor.sh` | Network connectivity check |
| `tests/unit/core/test_path_mapper.sh` | Unit tests for path mapper |
| `tests/unit/core/test_change_detector.sh` | Unit tests for change detector |
| `tests/unit/core/test_sync_engine.sh` | Unit tests for sync engine |
| `tests/unit/core/test_wifi_monitor.sh` | Unit tests for WiFi monitor |
| `tests/integration/test_detect_stage_commit.sh` | Integration test: change detection → stage → commit cycle |

### Files Modified

| File | Change |
|------|--------|
| `docs/roadmap.md` | Update Sprint 0.2 status to "In Progress" / "Complete" |

---

## Acceptance Criteria

### Path Mapper
1. `pm_local_to_repo` correctly maps paths for all 4 platforms (NextUI, Onion, RetroDeck, Android).
2. `pm_repo_to_local` round-trips correctly: `repo_to_local(local_to_repo(path)) == path`.
3. Paths with spaces (RetroArch Android) are handled correctly.
4. Unknown system directories produce a warning to stderr and return non-zero — not a crash.

### Change Detector
5. `cd_detect_changes` finds `.srm` files modified after the marker timestamp.
6. `cd_detect_changes` returns nothing when no files have been modified.
7. Non-`.srm` files are ignored even if recently modified.
8. Missing directories are silently skipped.

### Sync Engine
9. `se_stage_files` + `se_commit` creates a git commit with the correct message format.
10. `se_commit` with a single file uses `<system>/<filename> updated` as subject.
11. `se_commit` with multiple files uses `N saves updated` as subject.
12. `se_push` retries on network error with exponential backoff (verify via mock/log).
13. `se_pull` returns 0 on success, 1 on divergence, 2 on network error.
14. `se_has_unpushed_commits` correctly reports when local is ahead.

### WiFi Monitor
15. `wm_is_online` returns 0 when network is reachable.
16. `wm_is_online` returns 1 when network is unreachable.

### Integration
17. End-to-end: create `.srm` file → `cd_detect_changes` finds it → `pm_local_to_repo` maps it → `se_stage_files` + `se_commit` creates the commit → commit is in git log with correct message.
18. All tests pass under `busybox ash`.

---

## Testing Strategy

### Unit Tests

Each module gets a dedicated test file. Tests are self-contained:
- Create temp directories for fixtures and working data.
- Use local git repos (no network) for sync engine tests.
- Clean up all temp files on exit (trap on EXIT).
- Run under `busybox ash`.

**Path Mapper tests** (`tests/unit/core/test_path_mapper.sh`):
- Load each platform map, verify forward and reverse mappings for at least 3 systems.
- Test with a path containing spaces (Android).
- Test with an unknown system directory.

**Change Detector tests** (`tests/unit/core/test_change_detector.sh`):
- Create marker, create files before and after marker, verify only post-marker files detected.
- Verify non-`.srm` files are ignored.
- Verify empty result when nothing changed.
- Verify missing directory is skipped.

**Sync Engine tests** (`tests/unit/core/test_sync_engine.sh`):
- Init a bare git repo + working clone. Stage and commit a file. Verify commit message format.
- Test `se_has_staged_changes` and `se_has_unpushed_commits`.
- Test `se_pull` fast-forward success.
- Test `se_pull` divergence detection (commit on both sides).
- Push/pull between two local repos (no network needed).

**WiFi Monitor tests** (`tests/unit/core/test_wifi_monitor.sh`):
- Verify `wm_is_online` returns 0 or 1 (basic smoke test — actual connectivity depends on environment).
- If possible, mock by overriding `ping` with a function that fails.

### Integration Test

**`tests/integration/test_detect_stage_commit.sh`:**
1. Set up: local git repo, platform map (NextUI), marker file.
2. Create a `.srm` file in the fake saves directory.
3. Run change detection → path mapping → stage → commit.
4. Verify: git log shows commit with expected message format.
5. Verify: committed file exists at correct repo-relative path.
6. Tear down: remove all temp dirs.

---

## JSON Parsing Approach

Since constrained devices lack `jq`, the core modules parse JSON with POSIX tools. The platform map JSON files are small and have a predictable structure. Approach:

```sh
# Extract saves_root from platform map
saves_root=$(grep '"saves_root"' "$map_file" | sed 's/.*: *"\(.*\)".*/\1/')

# Build system mappings: iterate lines matching "canonical": "local_dir"
grep '"[a-z]' "$map_file" | while read -r line; do
    # parse key and value from "key": "value" pattern
done
```

This is fragile for arbitrary JSON but reliable for our controlled, schema-versioned config files. If a future sprint needs general JSON parsing, we'll add a minimal parser or ship a static `jq` binary.

---

## Open Questions

1. **Git binary on constrained devices:** TrimUI Brick ships a working `git` in NextUI. Should we verify the minimum git version required, or treat it as a platform prerequisite? **Recommendation:** Treat as prerequisite; document minimum version in platform notes.

2. **Marker file location:** `/tmp/continuity_marker` will be lost on reboot. This means the first poll after boot will detect all `.srm` files as "changed." Is this acceptable, or should the marker persist on SD card? **Recommendation:** Accept re-scan on boot — it results in a harmless no-op commit if files haven't actually changed (git won't commit identical content), and boot already triggers a pull which updates the repo.

---

## Definition of Done

- [ ] All 4 core modules implemented in `src/core/`.
- [ ] All functions documented with usage comments at top of file.
- [ ] All unit tests pass under `busybox ash`.
- [ ] Integration test passes under `busybox ash`.
- [ ] `shellcheck` passes on all `.sh` files with no errors.
- [ ] Sprint summary written to `docs/sprints/sprint-0.2-summary.md`.
