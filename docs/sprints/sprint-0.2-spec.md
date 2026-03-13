# Sprint 0.2 — Cold Start Sync

**Status:** Draft — Awaiting Approval
**Date:** 2026-03-13
**Dependencies:** Sprint 0.1 (complete — taxonomy, platform maps, test harness)

## Goal

Build the core shell modules (path mapping, sync engine, WiFi monitoring) and implement the **cold start sync flow** — the first-ever sync on a freshly enrolled device where no prior state exists. This is the foundation all subsequent sync phases build on.

Cold start is the one scenario where a full bidirectional scan is justified. It happens exactly once per device.

---

## Reference Specs

- `docs/design/architecture.md` — component descriptions and interfaces
- `config/system_taxonomy.json` — canonical system names
- `config/platform_maps/*.json` — per-platform path mappings
- `upstream/nextui/src/` — NextUI source (platform constraints reference)

---

## Context: The Four Sync Phases

Sprint 0.2 is the first of four sync-phase sprints. Each phase handles a distinct scenario with its own detection strategy, ordered by testability:

| Sprint | Phase | When | Detection | Writes |
|--------|-------|------|-----------|--------|
| **0.2** | **Cold start** | First run ever, no sentinel/commit | `cmp -s` all files both directions | Only differing files |
| 0.3 | Boot pull | Normal boot | `git diff --name-only` vs stored commit | Only remote changes → device |
| 0.4 | Runtime poll | Every 30s during gameplay | `find -newer` sentinel → `cmp -s` candidates | Only confirmed changes → repo |
| 0.5 | Stale boot | Boot after crash/unclean shutdown | Boot pull + catch-up scan | Only actual changes |

Each sprint builds on the previous one. Cold start establishes the core modules, sentinel file, and commit tracking that all subsequent phases depend on.

---

## Platform Constraints (from upstream analysis)

Key findings from inspecting the NextUI source that affect this sprint:

1. **No git binary on device.** NextUI does not ship git. A static git binary must be provided by the Continuity PAK (platform sprint concern, but the core engine must document this as a prerequisite).
2. **FAT32/exFAT filesystem.** SD card mtime has 2-second granularity and is unreliable. Cold start uses `cmp -s` (byte comparison), not mtime.
3. **No file monitoring.** No inotify or polling infrastructure exists on constrained devices.
4. **Auto.sh hook path** is `/mnt/SDCARD/.userdata/tg5040/auto.sh` (runs before NextUI main loop in `MinUI.pak/launch.sh`).
5. **Available shell utilities:** BusyBox ash with standard applets (`grep`, `sed`, `cp`, `mkdir`, `rm`, `cat`, `printf`, `touch`, `sleep`, `cmp`, `md5sum`).

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

### 2. Sync Engine (`src/core/sync_engine.sh`)

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
| `se_get_head_commit` | `()` | Print current HEAD commit hash to stdout |

**Implementation notes:**
- All git commands run with `GIT_DIR` and `GIT_WORK_TREE` pointing to the repo clone, not the current working directory.
- `se_pull` uses `--ff-only` to avoid auto-merge. If fast-forward fails, it returns 1 so the caller (or a future conflict handler) can deal with it. Sprint 0.2 does NOT implement conflict resolution — that's Sprint 0.6.
- `se_get_head_commit` is used to store the commit hash after sync (for Sprint 0.3's boot pull comparison).
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

### 3. WiFi Monitor (`src/core/wifi_monitor.sh`)

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

### 4. Cold Start Sync (`src/core/cold_start.sh`)

First-run sync when no prior state exists. This is the only time a full bidirectional scan is performed.

**Preconditions:**
- Repo has been cloned (enrollment is complete, Sprint 1.1 concern)
- Path mapper is loaded with the correct platform map
- No sentinel file exists (first run indicator)
- No stored commit hash exists

**Flow:**

```
cold_start_sync(repo_dir)
  1. se_pull                          # Get latest from remote
  2. Scan repo for .srm files         # What the repo has (from other devices)
  3. Scan device save dirs for .srm   # What the device has (local play)
  4. For each repo .srm:
       repo_path → local_path (pm_repo_to_local)
       if local file doesn't exist:
         cp repo → device              # New save from another device
       elif ! cmp -s repo_file local_file:
         cp repo → device              # Repo wins on cold start (latest from network)
         cp local → repo as .<device_name>.local  # Preserve device version (committed)
  5. For each device .srm not in repo:
       local_path → repo_path (pm_local_to_repo)
       cp device → repo                # New save, push it up
  6. Stage and commit all changes (including .local files) + push
  7. Store HEAD commit hash           # For Sprint 0.3 boot pull
  8. Create sentinel file             # Marks cold start complete
```

**Functions:**

| Function | Signature | Description |
|----------|-----------|-------------|
| `cs_run` | `(repo_dir)` | Execute the full cold start sync flow |
| `cs_is_cold_start` | `(repo_dir)` | Returns 0 if no sentinel exists (cold start needed), 1 if sentinel present |
| `cs_store_commit` | `(repo_dir, commit_hash)` | Write commit hash to `.continuity/last_known_commit` in the repo |
| `cs_read_commit` | `(repo_dir)` | Read stored commit hash, print to stdout. Returns 1 if not found |
| `cs_create_sentinel` | `(repo_dir)` | Create sentinel file at `.continuity/sentinel` |

**Implementation notes:**
- The sentinel file and commit hash live inside the repo working tree under `.continuity/`. This directory is gitignored — it's local device state, not synced.
- **Conflict file naming:** `<save>.srm.<device_name>.local` — e.g. `snes/super_metroid.srm.my-brick.local`. The device name is included so that when multiple devices enroll against the same repo, each device's conflicting version is distinguishable. These `.local` files are **committed to the repo**, not gitignored, so they're visible to all devices. This is key for the Steam Deck resolution app (Sprint 0.6): it can enumerate all `.local` files, let the user compare each device's save, and pick the authoritative version.
- Step 4 conflict behavior (repo wins, local preserved as `.<device_name>.local`): This is a conservative cold start default. The user has saves from another device in the repo AND local saves — we take the repo version (most likely to be recent, since it came from an actively syncing device) but preserve the local copy with device attribution. Sprint 0.6 will add proper conflict resolution UI.
- `cmp -s` is a byte-level comparison — reliable on any filesystem, no mtime dependency.
- The full scan is O(number of saves × number of systems). With typical libraries (dozens of games, ~15 systems), this completes in under a second even on constrained devices.
- `.continuity/` directory is created by `cs_run` if it doesn't exist.

---

### 5. Change Detector helpers (`src/core/change_detector.sh`)

Utility functions used by cold start (and later by other sync phases).

**Functions:**

| Function | Signature | Description |
|----------|-----------|-------------|
| `cd_detect_changes` | `(repo_dir)` | Run `git status --porcelain` in the repo, return list of changed/new `.srm` files (repo-relative paths), one per line. Returns empty if nothing changed. |
| `cd_list_repo_saves` | `(repo_dir)` | List all `.srm` files in the repo working tree (repo-relative paths), one per line |
| `cd_list_device_saves` | `()` | List all `.srm` files across all watched device save dirs (local paths), one per line. Requires path mapper to be loaded. |

**Implementation notes:**
- `cd_detect_changes` filters `git status` output to only `.srm` files.
- `cd_list_repo_saves` uses `find` within the repo working tree, excluding `.git/` and `.continuity/`.
- `cd_list_device_saves` walks directories from `pm_list_watched_dirs`, skipping dirs that don't exist.
- These are lower-level helpers. The cold start flow in `cs_run` uses them but also does its own `cmp -s` comparisons.

---

## Out of Scope

These are explicitly **not** part of Sprint 0.2:

| Item | Sprint |
|------|--------|
| Boot pull detection (`git diff --name-only`) | 0.3 |
| Runtime poll (`find -newer` + `cmp -s`) | 0.4 |
| Stale boot recovery | 0.5 |
| Conflict detection and resolution UI | 0.6 |
| Enrollment / credential import | 1.1 |
| Platform daemon loops (NextUI, RetroDeck) | 1.2+ |
| Device registration in `.continuity/devices/` | 1.1 |
| Shipping a static git binary for constrained devices | 1.2 (NextUI PAK) |
| inotify-based change detection (RetroDeck) | 2.2 |
| Android FileObserver | 3.2 |

The cold start flow uses a simple "repo wins, device version preserved as `.<device_name>.local`" strategy for conflicts. `.local` files are committed to the repo so all devices can see them. Full conflict resolution — where the Steam Deck app enumerates `.local` files and lets the user compare saves across devices — is Sprint 0.6.

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/core/path_mapper.sh` | Platform path ↔ repo path translation |
| `src/core/change_detector.sh` | Git status helpers and save file listing |
| `src/core/sync_engine.sh` | Git add/commit/push/pull operations |
| `src/core/wifi_monitor.sh` | Network connectivity check |
| `src/core/cold_start.sh` | Cold start sync flow (first run, full bidirectional scan) |
| `tests/unit/core/test_path_mapper.sh` | Unit tests for path mapper |
| `tests/unit/core/test_change_detector.sh` | Unit tests for change detector |
| `tests/unit/core/test_sync_engine.sh` | Unit tests for sync engine |
| `tests/unit/core/test_wifi_monitor.sh` | Unit tests for WiFi monitor |
| `tests/unit/core/test_cold_start.sh` | Unit tests for cold start sync flow |
| `tests/integration/test_cold_start_sync.sh` | Integration test: full cold start merge scenario |

### Files Modified

| File | Change |
|------|--------|
| `docs/roadmap.md` | Updated sprint breakdown (0.2–0.5 sync phases, 0.6 conflict handler) |

---

## Acceptance Criteria

### Path Mapper
1. `pm_local_to_repo` correctly maps paths for all 4 platforms (NextUI, Onion, RetroDeck, Android).
2. `pm_repo_to_local` round-trips correctly: `repo_to_local(local_to_repo(path)) == path`.
3. Paths with spaces (RetroArch Android) are handled correctly.
4. Unknown system directories produce a warning to stderr and return non-zero — not a crash.

### Change Detector
5. `cd_detect_changes` returns changed paths when saves differ from repo HEAD.
6. `cd_detect_changes` returns empty when saves are identical to repo HEAD.
7. `cd_list_repo_saves` lists all `.srm` files in repo, excludes `.git/` and `.continuity/`.
8. `cd_list_device_saves` lists all `.srm` files across watched dirs, skips missing dirs.

### Sync Engine
9. `se_stage_files` + `se_commit` creates a git commit with the correct message format.
10. `se_commit` with a single file uses `<system>/<filename> updated` as subject.
11. `se_commit` with multiple files uses `N saves updated` as subject.
12. `se_push` retries on network error with exponential backoff (verify via mock/log).
13. `se_pull` returns 0 on success, 1 on divergence, 2 on network error.
14. `se_has_unpushed_commits` correctly reports when local is ahead.
15. `se_get_head_commit` returns current HEAD hash.

### WiFi Monitor
16. `wm_is_online` returns 0 when network is reachable.
17. `wm_is_online` returns 1 when network is unreachable.

### Cold Start
18. `cs_is_cold_start` returns 0 when no sentinel exists, 1 when it does.
19. Cold start with empty repo + device saves: all device saves copied to repo, committed, pushed.
20. Cold start with repo saves + empty device: all repo saves copied to device save dirs at correct paths.
21. Cold start with both sides having the same save (identical bytes): no unnecessary writes, no `.local` file created.
22. Cold start with both sides having the same save (different bytes): repo version wins on device, device version preserved as `.<device_name>.local` in repo and committed.
23. Cold start with device-only saves and repo-only saves: both directions synced correctly.
24. Sentinel file created after successful cold start.
25. Commit hash stored after successful cold start.
26. `.continuity/` directory created if it doesn't exist.

### Integration
27. End-to-end cold start: set up bare repo with saves from "device A", set up "device B" with different saves + some overlapping saves. Run `cs_run` on device B. Verify: device B gets repo saves, repo gets device B's unique saves, overlapping saves resolved correctly, sentinel and commit hash created.
28. Running `cs_is_cold_start` after cold start returns 1 (not a cold start — sentinel exists).
29. All tests pass under `busybox ash`.

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
- Set up: initialized git repo with some `.srm` files.
- Verify `cd_detect_changes` reports new/modified files.
- Verify `cd_detect_changes` reports nothing when repo is clean.
- Verify `cd_list_repo_saves` finds all `.srm` files, excludes `.git/` and `.continuity/`.
- Verify `cd_list_device_saves` finds saves across multiple system dirs, skips missing dirs.

**Sync Engine tests** (`tests/unit/core/test_sync_engine.sh`):
- Init a bare git repo + working clone. Stage and commit a file. Verify commit message format.
- Test `se_has_staged_changes` and `se_has_unpushed_commits`.
- Test `se_pull` fast-forward success.
- Test `se_pull` divergence detection (commit on both sides).
- Test `se_get_head_commit` returns correct hash.
- Push/pull between two local repos (no network needed).

**WiFi Monitor tests** (`tests/unit/core/test_wifi_monitor.sh`):
- Verify `wm_is_online` returns 0 or 1 (basic smoke test — actual connectivity depends on environment).
- Mock by overriding `ping`/`wget` with wrapper scripts that simulate failure.

**Cold Start tests** (`tests/unit/core/test_cold_start.sh`):
- `cs_is_cold_start` returns 0 with no sentinel, 1 with sentinel.
- `cs_store_commit` / `cs_read_commit` round-trip correctly.
- `cs_create_sentinel` creates the sentinel file.
- Cold start with empty repo: device saves synced to repo.
- Cold start with empty device: repo saves synced to device.
- Cold start with identical files on both sides: no unnecessary writes.
- Cold start with different files on both sides: repo wins, local preserved as `.<device_name>.local` and committed.

### Integration Test

**`tests/integration/test_cold_start_sync.sh`:**
1. Set up: bare git repo as "remote". Clone to "device A" working dir. Commit some `.srm` files from device A and push.
2. Clone to "device B" working dir. Create a fake device B save directory tree (NextUI layout) with some overlapping and some unique `.srm` files.
3. Load NextUI platform map. Run `cs_run` on device B.
4. Verify: repo now has device B's unique saves.
5. Verify: device B's save dirs now have device A's saves.
6. Verify: overlapping saves with different content — device has repo version, repo has `.<device_name>.local` backup committed.
7. Verify: overlapping saves with identical content — no `.local` file created.
8. Verify: sentinel exists, stored commit hash matches HEAD.
9. Verify: `cs_is_cold_start` now returns 1.
10. Tear down: remove all temp dirs.

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

- [ ] All 5 core modules implemented in `src/core/`.
- [ ] All functions documented with usage comments at top of file.
- [ ] All unit tests pass under `busybox ash`.
- [ ] Integration test passes under `busybox ash`.
- [ ] `shellcheck` passes on all `.sh` files with no errors.
- [ ] Sprint summary written to `docs/sprints/sprint-0.2-summary.md`.
