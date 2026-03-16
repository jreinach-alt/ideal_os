# Sprint 1.1 — NextUI Daemon

**Status:** Draft
**Date:** 2026-03-15
**Dependencies:** Sprint 0.10 (sync notifications), Sprint 0.9 (conflict ops), Sprint 0.7 (stale boot), Sprint 0.6 (runtime poll), Sprint 0.5 (boot pull), Sprint 0.4 (cold start), Sprint 0.3 (enrollment)

---

## Goal

Phase 0 built the engine. Sprint 1.1 wraps it in a daemon that runs on a TrimUI Brick.

When the user powers on the Brick, the daemon starts automatically via the NextUI `auto.sh` hook. It figures out what kind of boot this is — cold start (first run), stale boot (crash recovery), or normal boot (pull latest saves). It runs the appropriate sync phase, then enters a poll loop checking for save changes every 30 seconds. When the user powers off, the daemon catches SIGTERM, pushes any pending commits, marks a clean shutdown, and exits.

If WiFi drops during a session, commits queue locally. When the daemon detects connectivity has returned, it pushes everything that was queued. The user never has to think about this.

The daemon also implements `pal_on_sync_result` on NextUI — calling `show2.elf` to display colored status dots (green/yellow/red) on the device screen. This is the first time the user actually *sees* sync happening.

**What this sprint does NOT include:** The Tool PAK UI (status screen, manual sync, conflict resolution UI). That's Sprint 1.2. This sprint is the headless daemon — it runs in the background, does its job, and shows brief status dots.

---

## Reference Specs

- `docs/design/pal.md` — PAL interface, `pal_on_sync_result` hook contract
- `docs/design/architecture.md` — Sync flow, daemon lifecycle, notification model
- `src/core/cold_start.sh` — `cs_run()`, `cs_is_cold_start()` (Sprint 0.4)
- `src/core/boot_pull.sh` — `bp_run()` (Sprint 0.5)
- `src/core/stale_boot.sh` — `sb_run()`, `sb_is_stale()`, `sb_mark_clean_shutdown()` (Sprint 0.7)
- `src/core/runtime_poll.sh` — `rp_run()` (Sprint 0.6)
- `src/core/sync_engine.sh` — `se_init()`, `se_push()`, `se_has_unpushed_commits()` (Sprint 0.3)
- `src/core/sync_status.sh` — `ss_notify()` (Sprint 0.10)
- `src/core/enrollment.sh` — `enroll_is_enrolled()` (Sprint 0.3)
- `src/platforms/nextui/pal_nextui.sh` — NextUI PAL (Sprint 0.2)
- `src/platforms/nextui/enroll_sd_card.sh` — SD card enrollment (Sprint 0.3)

---

## Design

### Daemon Lifecycle

```
┌──────────────────────────────────────────────────────────────────┐
│                        auto.sh (boot)                            │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │             continuity_daemon.sh (background)              │  │
│  │                                                            │  │
│  │  1. PID guard ─── if already running → exit                │  │
│  │  2. Source PAL + core modules                              │  │
│  │  3. pal_init() + pal_validate()                            │  │
│  │  4. se_init()                                              │  │
│  │  5. Enrollment check ─── if not enrolled → exit            │  │
│  │  6. Boot dispatch:                                         │  │
│  │     ├── cold start? → cs_run()                             │  │
│  │     ├── stale boot? → sb_run()                             │  │
│  │     └── normal boot → bp_run()                             │  │
│  │  7. Set SIGTERM trap                                       │  │
│  │  8. Poll loop (30s):                                       │  │
│  │     ├── WiFi recovery (push queued commits)                │  │
│  │     ├── rp_run()                                           │  │
│  │     └── Log rotation check                                 │  │
│  │  9. On SIGTERM:                                            │  │
│  │     ├── Final push attempt                                 │  │
│  │     ├── sb_mark_clean_shutdown()                            │  │
│  │     ├── Remove PID file                                    │  │
│  │     └── exit 0                                             │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

### Why These Design Choices

**PID file in `/tmp/` (tmpfs), not on the SD card.** FAT32 has no file locking, 2-second mtime granularity, and survives reboots. A PID file on FAT32 would be stale after every reboot, requiring extra cleanup logic. `/tmp/` is tmpfs on the Brick — it vanishes on reboot, so stale PIDs clean themselves up.

**30-second poll interval.** Matches the core runtime poll design (Sprint 0.6). Frequent enough to feel responsive (save → sync in under 30s), infrequent enough to not hammer the SD card or battery. The interval is a constant, not configurable — simplicity over flexibility for v0.1.

**WiFi recovery at poll-loop top.** Instead of a separate connectivity watcher, every poll cycle checks for unpushed commits when online. This is the simplest approach — no background threads, no event listeners, no race conditions. If WiFi returns while sleeping, the next poll cycle catches it.

**Boot dispatch is NOT a core module.** The decision tree (`cs_is_cold_start` → `sb_is_stale` → `bp_run`) is 10 lines of platform-specific orchestration. It doesn't belong in `src/core/` because different platforms may have different boot flows (e.g., Android might skip SD card enrollment check, RetroDeck might integrate with systemd). Each platform daemon owns its boot dispatch.

**Log rotation, not log truncation.** Simple size-based rotation: when the log exceeds 256 KB, rename to `.1` and start fresh. Keep one backup. This caps total log usage at ~512 KB — acceptable on a 64+ GB SD card. No external dependencies (logrotate, etc.).

---

## Scope

### Part 1: Boot Hook — `auto.sh`

**File:** `src/platforms/nextui/auto.sh`

NextUI runs `auto.sh` from each Tool PAK directory on boot. This is the entry point.

```sh
#!/bin/sh
# Continuity auto.sh — boot hook for NextUI
# Launched by NextUI on device boot. Starts the daemon in the background.

SCRIPT_DIR="$(dirname "$0")"
"$SCRIPT_DIR/scripts/continuity_daemon.sh" &
```

That's it. The hook's only job is to start the daemon in the background and return immediately so it doesn't block the NextUI boot sequence.

**Important:** `auto.sh` must not block. NextUI calls all `auto.sh` hooks sequentially during boot. A blocking hook delays the entire UI from appearing. The `&` is mandatory.

---

### Part 2: PID Management

**PID file location:** `/tmp/continuity.pid`

#### `cd_write_pid` — Write PID file

**Signature:** `cd_write_pid()`

No parameters. Writes `$$` to `/tmp/continuity.pid`.

**Returns:** 0 on success, 1 on write failure.

#### `cd_is_running` — Check if another instance is running

**Signature:** `cd_is_running()`

No parameters. Reads `/tmp/continuity.pid`, checks if the PID is alive via `kill -0`.

**Returns:** 0 if another instance is running, 1 if not (or PID file absent/stale).

**Behavior:**
1. If PID file doesn't exist → return 1.
2. Read PID from file.
3. If PID is not numeric → remove file, return 1.
4. `kill -0 "$pid"` → if process alive, return 0.
5. Otherwise (stale PID) → remove file, return 1.

#### `cd_remove_pid` — Remove PID file

**Signature:** `cd_remove_pid()`

No parameters. Removes `/tmp/continuity.pid`. Idempotent.

**Returns:** 0 always.

---

### Part 3: Module Loading

The daemon sources all required modules in dependency order. This is a function so it can be tested.

#### `cd_load_modules` — Source PAL and core modules

**Signature:** `cd_load_modules()`

No parameters. Uses `CONTINUITY_PAK_DIR` to locate scripts.

**Behavior:**
1. Source `$CONTINUITY_PAK_DIR/scripts/pal_nextui.sh`
2. Source `$CONTINUITY_PAK_DIR/scripts/core/pal.sh`
3. Source core modules in order:
   - `path_mapper.sh`
   - `sync_engine.sh`
   - `enrollment.sh`
   - `change_detector.sh`
   - `cold_start.sh`
   - `boot_pull.sh`
   - `stale_boot.sh`
   - `runtime_poll.sh`
   - `conflict_handler.sh`
   - `sync_status.sh`

**Returns:** 0 on success. Exits the daemon with code 1 if any source fails.

**Note:** On-device, scripts are copied into the PAK at build time. The daemon doesn't source from `src/`. The `CONTINUITY_PAK_DIR` variable points to `/mnt/SDCARD/Tools/Continuity.pak`.

For testing, `CONTINUITY_PAK_DIR` can be overridden to point to the repo's `src/` tree.

---

### Part 4: Boot Dispatch

#### `cd_boot_dispatch` — Determine and execute the correct boot phase

**Signature:** `cd_boot_dispatch(repo_dir)`

**Parameters:**
- `repo_dir` — absolute path to the local clone of the user's save repo

**Behavior:**
1. If `cs_is_cold_start "$repo_dir"` returns 0 → run `cs_run "$repo_dir"`, return its exit code.
2. Else if `sb_is_stale "$repo_dir"` returns 0 → run `sb_run "$repo_dir"`, return its exit code.
3. Else → run `bp_run "$repo_dir"`, return its exit code.

**Returns:** The exit code of whichever sync phase ran.

**Logging:** Logs which phase was selected before running it.

**Error handling:** If the boot phase fails (non-zero return), the daemon logs the error but does NOT exit. It proceeds to the poll loop. Rationale: a boot pull failure (e.g., offline) shouldn't prevent the daemon from running — the poll loop will handle local saves and push when connectivity returns. Only an enrollment failure is fatal.

---

### Part 5: WiFi Recovery

#### `cd_wifi_recovery` — Push queued commits when connectivity returns

**Signature:** `cd_wifi_recovery(repo_dir)`

**Parameters:**
- `repo_dir` — absolute path to local clone

**Behavior:**
1. If `pal_is_online` returns non-zero → return 0 (still offline, nothing to do).
2. Check `se_has_unpushed_commits "$repo_dir"` → if no unpushed commits, return 0.
3. Push: `se_push "$repo_dir"`.
4. If push succeeds (rc=0):
   - `ss_notify "$repo_dir" "green" "Pushed queued saves"`
   - Log success.
5. If push fails with rc=1 (persistent):
   - `ss_notify "$repo_dir" "red" "Push failed — check credentials"`
   - Log error.
6. If push fails with rc=2 (network):
   - Log warning (transient — will retry next cycle).

**Returns:** 0 always. WiFi recovery is best-effort; failure doesn't interrupt the poll loop.

---

### Part 6: Runtime Poll Loop

#### `cd_poll_loop` — Main poll loop

**Signature:** `cd_poll_loop(repo_dir)`

**Parameters:**
- `repo_dir` — absolute path to local clone

**Behavior:**
```
loop:
    cd_wifi_recovery "$repo_dir"
    rp_run "$repo_dir"
    cd_check_log_rotation
    sleep 30
```

**Loop termination:** The loop runs indefinitely. It exits when the process receives SIGTERM (caught by the trap set in the main function). The `sleep 30` is interruptible — SIGTERM during sleep immediately triggers the trap handler.

**Error handling in the loop:**
- If `rp_run` returns 1, log the error and continue. Do not exit. The next cycle may succeed (transient disk error, etc.).
- The poll loop is resilient — it never exits on its own. Only SIGTERM or a fatal signal stops it.

---

### Part 7: Graceful Shutdown

#### `cd_shutdown` — SIGTERM handler

**Signature:** `cd_shutdown()` (called by `trap`)

**Behavior:**
1. Log: `"Shutdown: SIGTERM received, starting graceful shutdown"`
2. Final push attempt:
   - If online AND has unpushed commits → `se_push "$repo_dir"`.
   - Log result (success, failure, or skipped-offline).
3. Mark clean shutdown: `sb_mark_clean_shutdown "$repo_dir"`.
4. Remove PID file: `cd_remove_pid`.
5. Log: `"Shutdown: complete"`.
6. `exit 0`.

**Why final push before clean-shutdown marker:** If commits are queued and we have connectivity, push them now. This minimizes the window for stale boot on the next startup. The push is best-effort — if it fails, the next boot's stale recovery will catch it.

**Trap setup:** `trap cd_shutdown TERM`

Set after boot dispatch completes (not before — we don't want SIGTERM during boot dispatch to trigger shutdown handler, which would mark clean shutdown before the boot phase completes).

**Note on `sleep` interruptibility:** On BusyBox ash, `sleep` is interrupted by signals. When SIGTERM arrives during `sleep 30`, the trap fires immediately — the daemon doesn't wait the remaining sleep time.

---

### Part 8: Log Management

**Log file location:** `/mnt/SDCARD/.continuity/continuity.log`

This is outside the repo directory (which is `/mnt/SDCARD/.continuity/repo/`). The `.continuity/` top-level directory is Continuity's home on the SD card.

#### `cd_check_log_rotation` — Rotate log if too large

**Signature:** `cd_check_log_rotation()`

No parameters. Uses `CONTINUITY_LOG_FILE` variable.

**Behavior:**
1. If log file doesn't exist → return 0.
2. Get file size via `wc -c < "$CONTINUITY_LOG_FILE"` (BusyBox compatible).
3. If size > 262144 (256 KB):
   - `mv "$CONTINUITY_LOG_FILE" "${CONTINUITY_LOG_FILE}.1"` (overwrite previous backup).
   - New writes go to fresh `$CONTINUITY_LOG_FILE` (created by stderr redirect).
4. Return 0.

**Rotation policy:** Keep 1 backup. Max total disk usage: ~512 KB. On a 64 GB SD card, this is nothing.

**Why not use syslog:** The Brick doesn't have syslogd running. BusyBox syslogd could be started, but adding a dependency on a system service is fragile. A simple log file is more predictable.

#### Log Destination Wiring

The daemon redirects stderr to the log file at startup:

```sh
CONTINUITY_LOG_FILE="/mnt/SDCARD/.continuity/continuity.log"
mkdir -p "$(dirname "$CONTINUITY_LOG_FILE")"
exec 2>>"$CONTINUITY_LOG_FILE"
```

Since `pal_log` writes to stderr, all log messages from all modules automatically go to this file. No module changes needed.

---

### Part 9: `pal_on_sync_result` Implementation

#### Changes to `src/platforms/nextui/pal_nextui.sh`

Add `pal_on_sync_result` — display a colored dot on the Brick's screen via `show2.elf`.

**Signature:** `pal_on_sync_result(level, message)`

**Parameters:**
- `level` — `green`, `yellow`, `red`
- `message` — human-readable text (logged but not displayed on screen — no text rendering available via `show2.elf`)

**Behavior:**
1. Map level to color: `green` → green, `yellow` → yellow, `red` → red.
2. If `show2.elf` exists at `$CONTINUITY_PAK_DIR/bin/show2.elf`:
   - For `green`/`yellow`: show dot briefly, then clear (transient).
   - For `red`: show dot and leave it (persistent — re-fired each poll cycle per 0.10 contract).
3. If `show2.elf` is not available: log-only fallback (no error, no crash).

**`show2.elf` integration notes:**

`show2.elf` is a NextUI utility for rendering small overlays on the framebuffer. The exact invocation depends on the version bundled. The implementation should:
- Use a small dot (8×8 px) in the bottom-right corner of the screen
- Position: offset from bottom-right to avoid overlap with battery indicator
- Green/yellow: launch in background, `sleep 3`, then clear overlay
- Red: launch and leave running (daemon re-fires each cycle; the overlay process persists)

**Important:** The exact `show2.elf` command-line interface must be verified against the binary bundled in the PAK. If `show2.elf` is unavailable or the interface is different from expected, the function gracefully degrades to log-only. This is tested manually on-device, not in CI.

---

### Part 10: Main Daemon Entry Point

#### `cd_main` — Daemon entry point

**Signature:** `cd_main()`

No parameters. Called at script bottom.

**Behavior:**
1. Set `CONTINUITY_PAK_DIR` from script location: `$(cd "$(dirname "$0")/.." && pwd)`.
2. Set `CONTINUITY_LOG_FILE` and redirect stderr.
3. PID guard: `cd_is_running` → if yes, log and exit 0.
4. Write PID: `cd_write_pid`.
5. Load modules: `cd_load_modules`.
6. Init PAL: `pal_init` → if fails, exit 1.
7. Validate PAL: `pal_validate` → if fails, exit 1.
8. Init sync engine: `se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME"`.
9. Load platform map: `pm_load_platform_map "$(pal_get_platform_map)"`.
10. Enrollment check: if `$CONTINUITY_REPO_DIR` doesn't exist, attempt SD card enrollment (`esd_detect_setup_file` → `esd_import`). If still not enrolled → log, remove PID, exit 1.
11. Boot dispatch: `cd_boot_dispatch "$CONTINUITY_REPO_DIR"` → log result.
12. Set SIGTERM trap: `trap cd_shutdown TERM`.
13. Enter poll loop: `cd_poll_loop "$CONTINUITY_REPO_DIR"`.

---

### Part 11: PAK Directory Structure

What ships in the Continuity PAK on the SD card:

```
/mnt/SDCARD/Tools/Continuity.pak/
├── auto.sh                          ← Boot hook (Part 1)
├── launch.sh                        ← Tool UI entry (Sprint 1.2 — stub for now)
├── bin/
│   ├── git                          ← Static git binary (arm, musl-linked)
│   └── show2.elf                    ← NextUI overlay utility (from upstream)
├── config/
│   └── platform_maps/
│       └── nextui.json              ← Platform map (from config/)
└── scripts/
    ├── continuity_daemon.sh         ← Main daemon (Part 10)
    ├── pal_nextui.sh                ← NextUI PAL
    ├── enroll_sd_card.sh            ← SD card enrollment
    └── core/
        ├── pal.sh                   ← PAL validator
        ├── path_mapper.sh
        ├── sync_engine.sh
        ├── enrollment.sh
        ├── change_detector.sh
        ├── cold_start.sh
        ├── boot_pull.sh
        ├── stale_boot.sh
        ├── runtime_poll.sh
        ├── conflict_handler.sh
        └── sync_status.sh
```

**Build script:** A build script (`scripts/build_pak.sh`) copies source files from the repo into this structure. The static `git` binary and `show2.elf` are stored in `upstream/` and copied at build time. The build script is out of scope for this sprint (Sprint 1.3 or a build infrastructure sprint), but the directory structure is defined here so the daemon can locate its dependencies.

**`launch.sh` stub:** Creates a minimal `launch.sh` that prints "Continuity daemon is running" and exits. The real Tool PAK UI is Sprint 1.2.

---

## Out of Scope

| Item | Sprint |
|------|--------|
| Tool PAK UI (status screen, manual sync, conflict resolution) | 1.2 |
| Build script (`scripts/build_pak.sh`) for assembling the PAK | 1.3 or build sprint |
| Static git binary procurement / cross-compilation | 1.3 or build sprint |
| `show2.elf` procurement from upstream NextUI | 1.3 or build sprint |
| SD card enrollment wizard UI | 1.2 |
| Notification preferences (disable, quiet hours) | post-1.0 |
| Configurable poll interval | post-1.0 |
| inotify-based change detection (RetroDeck) | 2.2 |
| systemd service (RetroDeck) | 2.1 |
| Watchdog / auto-restart on crash | post-1.0 |
| Remote pull during runtime (inbound sync while playing) | post-1.0 |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/platforms/nextui/continuity_daemon.sh` | Main daemon: PID guard, module loading, boot dispatch, poll loop, shutdown handler, log rotation |
| `src/platforms/nextui/auto.sh` | Boot hook: starts daemon in background |
| `tests/unit/platforms/nextui/test_daemon.sh` | Unit tests for all `cd_*` functions |
| `tests/integration/test_daemon_lifecycle.sh` | Integration tests: boot dispatch, poll loop, shutdown, WiFi recovery |
| `docs/sprints/sprint-1.1-spec.md` | This spec |

### Files Modified

| File | Change |
|------|--------|
| `src/platforms/nextui/pal_nextui.sh` | Add `pal_on_sync_result` function. Add `CONTINUITY_PAK_DIR` variable. |
| `docs/design/pal.md` | Document `pal_on_sync_result` NextUI implementation details (show2.elf usage). |

### Directories Created

| Directory | Purpose |
|-----------|---------|
| `tests/unit/platforms/nextui/` | Unit tests for NextUI platform code |

---

## Acceptance Criteria

### PID Management

1. `cd_is_running` returns 0 when another daemon process is alive at the recorded PID.
2. `cd_is_running` returns 1 when PID file is absent.
3. `cd_is_running` returns 1 when PID file contains a stale PID (process not running), and removes the stale file.
4. `cd_is_running` returns 1 when PID file contains non-numeric content, and removes the file.
5. `cd_write_pid` writes the current process PID to `/tmp/continuity.pid`.
6. `cd_remove_pid` removes the PID file. No error if file doesn't exist.
7. Starting the daemon when another instance is already running: new instance logs a message and exits 0 (not an error).

### Module Loading

8. `cd_load_modules` sources all required modules in correct dependency order.
9. If any module file is missing, daemon logs the error and exits 1.
10. After `cd_load_modules`, all core functions are available (`cs_run`, `bp_run`, `sb_run`, `rp_run`, etc.).

### Boot Dispatch

11. When sentinel is absent (`cs_is_cold_start` returns 0), daemon runs `cs_run`.
12. When sentinel exists and clean shutdown marker is absent (`sb_is_stale` returns 0), daemon runs `sb_run`.
13. When sentinel exists and clean shutdown marker is present (normal boot), daemon runs `bp_run`.
14. Boot dispatch logs which phase was selected.
15. If boot phase returns non-zero, daemon logs the error but continues to poll loop (does not exit).

### Poll Loop

16. Poll loop calls `rp_run` every 30 seconds.
17. Poll loop calls `cd_wifi_recovery` before each `rp_run` call.
18. Poll loop calls `cd_check_log_rotation` after each `rp_run` call.
19. If `rp_run` returns 1 (error), daemon logs the error and continues to next cycle.
20. Poll loop runs indefinitely until SIGTERM is received.

### WiFi Recovery

21. When online and unpushed commits exist, `cd_wifi_recovery` calls `se_push`.
22. When online and no unpushed commits, `cd_wifi_recovery` is a no-op.
23. When offline, `cd_wifi_recovery` is a no-op.
24. Successful WiFi recovery push fires `ss_notify` green with "Pushed queued saves".
25. Failed WiFi recovery push (rc=1) fires `ss_notify` red with credential error message.
26. Network error on WiFi recovery push (rc=2) logs warning but does not notify (transient).
27. `cd_wifi_recovery` always returns 0 (never interrupts poll loop).

### Graceful Shutdown

28. SIGTERM triggers `cd_shutdown` handler.
29. Shutdown handler attempts final push if online and unpushed commits exist.
30. Shutdown handler calls `sb_mark_clean_shutdown` to create clean shutdown marker.
31. Shutdown handler removes PID file.
32. Shutdown handler exits with code 0.
33. SIGTERM during `sleep` interrupts sleep immediately (no waiting for remaining interval).
34. SIGTERM trap is set AFTER boot dispatch completes (not before).

### Log Management

35. Daemon redirects stderr to `/mnt/SDCARD/.continuity/continuity.log` at startup.
36. `cd_check_log_rotation` rotates log when size exceeds 256 KB.
37. Rotation renames current log to `.1` and allows fresh log creation.
38. At most 1 backup log is kept (previous `.1` is overwritten).
39. Log directory is created if it doesn't exist.

### `pal_on_sync_result` (NextUI)

40. `pal_on_sync_result "green" <msg>` shows a transient green indicator (fades after ~3s).
41. `pal_on_sync_result "yellow" <msg>` shows a transient yellow indicator (fades after ~3s).
42. `pal_on_sync_result "red" <msg>` shows a persistent red indicator (stays on screen).
43. If `show2.elf` is not available, function degrades to log-only (no error, no crash).
44. Function logs the level and message via `pal_log` regardless of display availability.

### `auto.sh` Boot Hook

45. `auto.sh` starts the daemon in the background (non-blocking).
46. `auto.sh` does not produce any output to stdout.
47. `auto.sh` returns immediately (does not wait for daemon startup).

### Enrollment Integration

48. If the repo directory doesn't exist, daemon attempts SD card enrollment.
49. If enrollment succeeds, daemon continues with boot dispatch.
50. If enrollment fails (no setup.json, invalid credentials), daemon logs error, cleans up PID file, and exits 1.

### Code Quality

51. All new code passes `shellcheck` with no errors.
52. All new code passes `busybox ash -n` syntax check.
53. No banned BusyBox ash constructs (per CLAUDE.md table).
54. All variable expansions are quoted.
55. All new functions use `printf` for output, not `echo`.
56. All tests pass under `busybox ash`.

---

## Testing Strategy

### Unit Tests (`tests/unit/platforms/nextui/test_daemon.sh`)

All daemon functions are tested in isolation using the test PAL. The daemon script is sourced (not executed) so individual functions can be called.

**PID management tests:**
- `cd_write_pid`: verify PID file contains `$$`.
- `cd_is_running` with active PID: start a background `sleep` process, write its PID, verify returns 0.
- `cd_is_running` with stale PID: write a PID of a dead process, verify returns 1 and file is removed.
- `cd_is_running` with no PID file: verify returns 1.
- `cd_is_running` with non-numeric PID: write "garbage" to PID file, verify returns 1 and file is removed.
- `cd_remove_pid`: verify file removed. Call again — no error.
- Duplicate instance guard: write a live PID, verify `cd_is_running` returns 0.

**Boot dispatch tests:**
- Cold start scenario: set up repo with no sentinel → verify `cd_boot_dispatch` calls `cs_run`.
- Stale boot scenario: create sentinel, remove clean_shutdown marker → verify calls `sb_run`.
- Normal boot scenario: create sentinel + clean_shutdown marker → verify calls `bp_run`.
- Boot dispatch with failing phase: mock `cs_run` to return 1 → verify `cd_boot_dispatch` returns 1 but daemon function continues.

**WiFi recovery tests:**
- Online + unpushed commits: mock `pal_is_online` (return 0), `se_has_unpushed_commits` (return 0), `se_push` (return 0) → verify push called, green notification fired.
- Online + no unpushed: mock appropriately → verify push NOT called.
- Offline: mock `pal_is_online` (return 1) → verify nothing called.
- Push failure: mock `se_push` (return 1) → verify red notification.
- Push network error: mock `se_push` (return 2) → verify logged, no notification.

**Log rotation tests:**
- Small log (< 256 KB): verify no rotation.
- Large log (> 256 KB): verify renamed to `.1`, original path is now empty/absent.
- Rotation with existing `.1`: verify old `.1` is overwritten.
- Missing log file: verify no error.

**Module loading tests:**
- Verify all core function names are defined after `cd_load_modules`.
- Verify load fails gracefully if a module file is missing.

### Integration Tests (`tests/integration/test_daemon_lifecycle.sh`)

**Setup:** Create bare remote repo, local clone, device saves directory. Use test PAL with overrides. Set `CONTINUITY_PAK_DIR` to point at repo source tree.

**Scenario 1: Full cold start → poll → shutdown lifecycle**
1. Set up an enrolled device with no sentinel (cold start state).
2. Create a device save file.
3. Call `cd_boot_dispatch` → verify `cs_run` executed, save pushed to remote.
4. Create another save change.
5. Call `rp_run` → verify change committed and pushed.
6. Call `cd_shutdown` → verify clean shutdown marker created, PID file removed.

**Scenario 2: Stale boot recovery**
1. Create sentinel, remove clean_shutdown marker.
2. Create a device save that's different from repo.
3. Call `cd_boot_dispatch` → verify `sb_run` executed, catch-up commit pushed.

**Scenario 3: Normal boot pull**
1. Create sentinel + clean_shutdown marker.
2. Push a new save from a "second device" (second clone).
3. Call `cd_boot_dispatch` → verify `bp_run` executed, new save copied to device.

**Scenario 4: WiFi recovery**
1. Start with a committed but unpushed save (simulate offline commit).
2. Mock `pal_is_online` to return 0 (online).
3. Call `cd_wifi_recovery` → verify push succeeds, green notification fired.
4. Call `cd_wifi_recovery` again → verify no-op (nothing to push).

**Scenario 5: Offline → online transition**
1. Mock `pal_is_online` to return 1 (offline).
2. Create a save change, run `rp_run` → verify committed locally, yellow notification.
3. Switch mock to return 0 (online).
4. Call `cd_wifi_recovery` → verify queued commit pushed, green notification.

**Scenario 6: Boot dispatch error resilience**
1. Set up a state where `bp_run` will fail (e.g., corrupt repo state).
2. Call `cd_boot_dispatch` → verify returns non-zero.
3. Verify the test can continue to call `rp_run` (daemon doesn't exit on boot failure).

**Scenario 7: PID guard prevents duplicate**
1. Write a live PID to `/tmp/continuity.pid` (from a background sleep process).
2. Call `cd_is_running` → verify returns 0.
3. Verify the daemon would exit (test the guard logic).

### On-Device Test Checklist

These tests require a physical TrimUI Brick and cannot be automated in CI.

| # | Test | Steps | Expected |
|---|------|-------|----------|
| D1 | Boot auto-start | Power on Brick with Continuity PAK installed | Daemon starts, `ps` shows `continuity_daemon.sh` process |
| D2 | Cold start on first boot | First boot after enrollment | Saves synced to repo, green dot appears briefly |
| D3 | Normal boot pull | Boot after clean shutdown, with new save in repo from another device | New save appears on device, no notification (silent) |
| D4 | Stale boot recovery | Kill daemon with `kill -9` (simulate crash), reboot | Stale boot runs, any unsaved changes caught up |
| D5 | Runtime sync | Play a game, save in-game, wait 30s | Green dot appears, save visible in GitHub repo |
| D6 | Offline behavior | Disable WiFi, play and save | Yellow dot appears, save committed locally |
| D7 | WiFi recovery | Re-enable WiFi after D6, wait up to 30s | Green dot appears, queued save pushed to repo |
| D8 | Graceful shutdown | Power off Brick normally (triggers SIGTERM) | Clean shutdown marker created, pending saves pushed |
| D9 | No duplicate daemon | Manually run `continuity_daemon.sh` while daemon is running | Second instance exits immediately |
| D10 | Log rotation | Let daemon run for extended period (or manually inflate log) | Log stays under 512 KB total |
| D11 | Red notification | Create a conflict from another device, boot Brick | Red dot appears and persists |
| D12 | `show2.elf` fallback | Remove `show2.elf` from PAK, reboot, play and save | Daemon functions normally, log shows notifications, no display crash |

---

## Definition of Done

- [ ] `src/platforms/nextui/continuity_daemon.sh` implements: PID guard, module loading, boot dispatch, poll loop, WiFi recovery, graceful shutdown, log rotation.
- [ ] `src/platforms/nextui/auto.sh` starts daemon in background, non-blocking.
- [ ] `pal_on_sync_result` implemented in `pal_nextui.sh` — calls `show2.elf` or degrades to log-only.
- [ ] Boot dispatch correctly selects cold start, stale boot, or boot pull.
- [ ] Poll loop runs `rp_run` at 30-second intervals indefinitely.
- [ ] WiFi recovery pushes queued commits when connectivity returns.
- [ ] SIGTERM triggers graceful shutdown: final push, clean shutdown marker, PID cleanup.
- [ ] Log rotation caps log at ~256 KB with 1 backup.
- [ ] PID file in `/tmp/` prevents duplicate daemon instances.
- [ ] All `cd_*` functions pass unit tests under `busybox ash`.
- [ ] Integration tests cover: cold start lifecycle, stale boot, normal boot, WiFi recovery, offline→online transition, error resilience.
- [ ] All shell code passes `shellcheck` and `busybox ash -n`.
- [ ] No banned BusyBox ash constructs.
- [ ] On-device test checklist documented with steps and expected results.
- [ ] Sprint summary written to `docs/sprints/sprint-1.1-summary.md` on completion.
