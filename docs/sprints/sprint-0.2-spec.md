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
- `upstream/nextui/src/` — NextUI source (platform constraints reference)

---

## Platform Constraints (from upstream analysis)

Key findings from inspecting the NextUI source that affect this sprint:

1. **No git binary on device.** NextUI does not ship git. A static git binary must be provided by the Continuity PAK (platform sprint concern, but the core engine must document this as a prerequisite).
2. **FAT32/exFAT filesystem.** SD card mtime has 2-second granularity and is unreliable. `find -newer` is not a viable change detection strategy.
3. **No file monitoring.** NextUI uses `stat()` for file size only, never mtime. No inotify or polling infrastructure exists.
4. **Auto.sh hook path** is `/mnt/SDCARD/.userdata/tg5040/auto.sh` (runs before NextUI main loop in `MinUI.pak/launch.sh`).
5. **Available shell utilities:** BusyBox ash with standard applets (`grep`, `sed`, `cp`, `mkdir`, `rm`, `cat`, `printf`, `touch`, `sleep`, `md5sum`/`sha256sum` TBD).

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

Detects changed `.srm` files by copying saves into the repo working tree and letting git identify what differs. This avoids any dependency on filesystem mtime (unreliable on FAT32).

**Strategy: copy-and-diff**

1. Walk all watched save directories (from `pm_list_watched_dirs`).
2. For each `.srm` file found, compute the repo-relative path (via `pm_local_to_repo`).
3. Copy the file into the corresponding location in the repo working tree.
4. Ask git what changed: `git status --porcelain`.
5. Return the list of changed repo-relative paths.

Git compares file content by SHA hash — identical files produce no diff, no stage, no commit. This is inherently persistent across reboots because the repo working tree **is** the state tracker.

**Functions:**

| Function | Signature | Description |
|----------|-----------|-------------|
| `cd_sync_saves_to_repo` | `(repo_dir)` | Copy all `.srm` files from device save dirs into the repo working tree at their mapped paths. Requires path mapper to be loaded. |
| `cd_detect_changes` | `(repo_dir)` | Run `git status --porcelain` in the repo, return list of changed/new `.srm` files (repo-relative paths), one per line. Returns empty if nothing changed. |
| `cd_sync_repo_to_saves` | `(repo_dir)` | Copy all `.srm` files from the repo working tree back out to device save dirs at their mapped paths. Used after `se_pull` to land incoming saves where the emulator expects them. |

**Implementation notes:**
- `cd_sync_saves_to_repo` creates parent directories in the repo as needed (`mkdir -p`).
- `cd_sync_repo_to_saves` creates parent directories on the device as needed (`mkdir -p`).
- Only `.srm` files are copied in both directions — other files are ignored.
- Directories that don't exist on the device are silently skipped (a system with no saves yet).
- The copy is cheap: `.srm` files are 8–128 KB each, and typical game libraries have dozens, not thousands.
- `cd_detect_changes` filters `git status` output to only `.srm` files (ignoring `.conflict`, `.local`, or other metadata that may exist in the repo).
- `cd_sync_repo_to_saves` does a simple overwrite for now. Sprint 0.3 will add conflict guards (e.g. skip copy if local file was also modified since last sync).

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
- Git binary is a platform prerequisite. The core engine assumes `git` is on `PATH`. Platform PAKs are responsible for providing it (Sprint 1.x).

---

### 4. WiFi Monitor (`src/core/wifi_monitor.sh`)

Connectivity check before network operations.

**Functions:**

| Function | Signature | Description |
|----------|-----------|-------------|
| `wm_is_online` | `()` | Returns 0 if network-connected, 1 if offline |

**Implementation notes:**
- Primary check: `ping -c 1 -W 3 github.com >/dev/null 2>&1`.
- Fallback if `ping` is unavailable or blocked: `wget --spider -q -T 3 https://github.com 2>/dev/null`.
- Does NOT check for WiFi specifically — just general network reachability to GitHub.
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
| Shipping a static git binary for constrained devices | 1.2 (NextUI PAK) |
| inotify-based change detection (RetroDeck) | 2.2 |
| Android FileObserver | 3.2 |
| Conflict-aware reverse sync (skip if local also modified) | 0.3 |

`se_pull` returns a distinct code on divergence but does not resolve it — Sprint 0.3's conflict handler will consume that signal.

`cd_sync_repo_to_saves` performs a simple overwrite copy-back after pull. Sprint 0.3 will wrap this with conflict detection (what if the device file was also modified since last sync?).

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/core/path_mapper.sh` | Platform path ↔ repo path translation |
| `src/core/change_detector.sh` | Copy-and-diff change detection using git status |
| `src/core/sync_engine.sh` | Git add/commit/push/pull operations |
| `src/core/wifi_monitor.sh` | Network connectivity check |
| `tests/unit/core/test_path_mapper.sh` | Unit tests for path mapper |
| `tests/unit/core/test_change_detector.sh` | Unit tests for change detector |
| `tests/unit/core/test_sync_engine.sh` | Unit tests for sync engine |
| `tests/unit/core/test_wifi_monitor.sh` | Unit tests for WiFi monitor |
| `tests/integration/test_detect_stage_commit.sh` | Integration test: full sync cycle (local only) |

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
5. `cd_sync_saves_to_repo` copies `.srm` files into correct repo paths.
6. `cd_sync_saves_to_repo` ignores non-`.srm` files in save directories.
7. `cd_sync_saves_to_repo` skips missing directories without error.
8. `cd_detect_changes` returns changed paths when saves differ from repo HEAD.
9. `cd_detect_changes` returns empty when saves are identical to repo HEAD.
10. Newly added `.srm` files (no prior repo version) are detected as changes.
11. `cd_sync_repo_to_saves` copies `.srm` files from repo to correct device save paths.
12. `cd_sync_repo_to_saves` creates device directories as needed.
13. `cd_sync_repo_to_saves` ignores non-`.srm` files in repo.

### Sync Engine
14. `se_stage_files` + `se_commit` creates a git commit with the correct message format.
15. `se_commit` with a single file uses `<system>/<filename> updated` as subject.
16. `se_commit` with multiple files uses `N saves updated` as subject.
17. `se_push` retries on network error with exponential backoff (verify via mock/log).
18. `se_pull` returns 0 on success, 1 on divergence, 2 on network error.
19. `se_has_unpushed_commits` correctly reports when local is ahead.

### WiFi Monitor
20. `wm_is_online` returns 0 when network is reachable.
21. `wm_is_online` returns 1 when network is unreachable.

### Integration
22. End-to-end outbound: create `.srm` in fake save dir → `cd_sync_saves_to_repo` copies to repo → `cd_detect_changes` reports it → `se_stage_files` + `se_commit` creates commit → git log shows correct message → file at correct repo-relative path.
23. End-to-end inbound: commit a new `.srm` in a remote repo → `se_pull` fetches it → `cd_sync_repo_to_saves` copies it to the correct device save path.
24. Running the outbound cycle a second time with no file changes produces no new commit.
25. All tests pass under `busybox ash`.

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
- Set up: fake save directory tree, initialized git repo.
- Copy saves to repo, verify files appear at correct paths.
- Verify `cd_detect_changes` reports new files.
- Modify a save file, re-copy, verify `cd_detect_changes` reports only the modified file.
- Re-copy without changes, verify `cd_detect_changes` reports nothing.
- Verify non-`.srm` files are not copied.
- Verify missing save directories are skipped.
- Test `cd_sync_repo_to_saves`: place `.srm` files in repo, run sync, verify they appear at correct device paths.
- Test `cd_sync_repo_to_saves`: verify device directories are created as needed.

**Sync Engine tests** (`tests/unit/core/test_sync_engine.sh`):
- Init a bare git repo + working clone. Stage and commit a file. Verify commit message format.
- Test `se_has_staged_changes` and `se_has_unpushed_commits`.
- Test `se_pull` fast-forward success.
- Test `se_pull` divergence detection (commit on both sides).
- Push/pull between two local repos (no network needed).

**WiFi Monitor tests** (`tests/unit/core/test_wifi_monitor.sh`):
- Verify `wm_is_online` returns 0 or 1 (basic smoke test — actual connectivity depends on environment).
- Mock by overriding `ping`/`wget` with wrapper scripts that simulate failure.

### Integration Test

**`tests/integration/test_detect_stage_commit.sh`:**
1. Set up: bare git repo + two working clones ("device A" and "device B"), fake saves directory tree (NextUI layout), platform map loaded.
2. **Outbound sync:** Place `.srm` files in device A's fake save directories.
3. Run `cd_sync_saves_to_repo` → `cd_detect_changes` → `se_stage_files` → `se_commit` → `se_push`.
4. Verify: git log shows commit with expected message format.
5. Verify: committed file exists at correct repo-relative path (e.g. `snes/super_metroid.srm`).
6. Run the cycle again with no changes — verify no new commit is created.
7. Modify one `.srm` file, run the cycle — verify only that file is in the new commit.
8. **Inbound sync:** From device B's clone, `se_pull` → `cd_sync_repo_to_saves` → verify `.srm` appears at correct device save path.
9. Tear down: remove all temp dirs.

---

## JSON Parsing Approach

Since constrained devices lack `jq`, the core modules parse JSON with POSIX tools. The platform map JSON files are small and have a predictable structure. Approach:

```sh
# Extract saves_root from platform map
saves_root=$(grep '"saves_root"' "$map_file" | sed 's/.*: *"\(.*\)".*/\1/')

# Build system mappings: iterate key/value pairs inside "system_paths"
# The JSON is controlled and schema-versioned — no arbitrary nesting
```

This is fragile for arbitrary JSON but reliable for our controlled, schema-versioned config files. If a future sprint needs general JSON parsing, we'll add a minimal parser or ship a static `jq` binary.

---

## Open Questions

None — all resolved during spec review.

---

## Definition of Done

- [ ] All 4 core modules implemented in `src/core/`.
- [ ] All functions documented with usage comments at top of file.
- [ ] All unit tests pass under `busybox ash`.
- [ ] Integration test passes under `busybox ash`.
- [ ] `shellcheck` passes on all `.sh` files with no errors.
- [ ] Sprint summary written to `docs/sprints/sprint-0.2-summary.md`.
