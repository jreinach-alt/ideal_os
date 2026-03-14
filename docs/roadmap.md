# Continuity — Development Roadmap

## Roadmap Philosophy

Small, modular sprints. Each sprint produces a testable, working increment. All core sync logic is platform-agnostic, built on the Platform Abstraction Layer (PAL). Platform clients share core logic and provide only platform-specific entry points and configuration.

**Ordering principle:** Each sprint is testable the moment it's complete. No sprint depends on hardware or infrastructure that doesn't exist yet. Automated tests use the test PAL; on-device validation uses the NextUI PAL.

---

## Phase 0 — Foundation and Core Sync

**Goal:** PAL framework, enrollment, and all sync phases — fully tested, platform-agnostic. Everything a platform daemon needs to function.

### Sprint 0.1 — Repo Scaffolding and System Taxonomy

**Status:** Complete

**Scope:**
- Pivot repo from Ideal OS to Continuity
- Establish directory structure per CLAUDE.md
- Define canonical system taxonomy (`config/system_taxonomy.json`)
- Define platform path mappings (`config/platform_maps/*.json`)
- Write foundational design specs (architecture, security, roadmap)
- Set up test harness (`scripts/test.sh`)

**Acceptance Criteria:**
- Directory structure matches CLAUDE.md spec
- System taxonomy JSON is valid, covers all target systems
- Platform maps exist for NextUI, Onion OS, RetroDeck, Android
- Design docs cover architecture, security model, enrollment flow
- Test harness runs and reports pass/fail

---

### Sprint 0.2 — Platform Abstraction Layer and Path Mapper

**Status:** Complete

**Scope:**
- Define the PAL interface (`src/core/pal.sh`) — required variables, required functions, validator
- Implement NextUI PAL (`src/platforms/nextui/pal_nextui.sh`)
- Implement test PAL (`tests/fixtures/pal_test.sh`)
- Implement path mapper (`src/core/path_mapper.sh`) — uses PAL for platform map selection
- Unit tests proving same path mapper code works with both test PAL and NextUI PAL

**Acceptance Criteria:**
- PAL validator catches missing variables and functions
- NextUI PAL sets all required variables and implements all required functions
- Test PAL provides synthetic environment for CI
- Path mapper correctly translates paths for all 4 platforms
- Path mapper round-trips: `repo_to_local(local_to_repo(path)) == path`
- Paths with spaces (RetroArch Android) handled correctly
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.1 (taxonomy and platform maps)

**Reference Specs:** `docs/design/pal.md`

---

### Sprint 0.3 — Enrollment

**Status:** Complete

**Scope:**
- Implement core enrollment logic (`src/core/enrollment.sh`) — clone repo, register device, store credentials, write device name
- Implement NextUI enrollment trigger (`src/platforms/nextui/enroll_sd_card.sh`) — detect and import `setup.json` from SD card
- Implement test enrollment helper (`tests/fixtures/enroll_test.sh`) — scripted setup for CI (no SD card, no user interaction)
- Implement sync engine (`src/core/sync_engine.sh`) — git clone, add, commit, push, pull (needed by enrollment for initial clone and device registration push)
- Device registration in `.continuity/devices/<name>.json` (committed to repo)
- Device name stored locally for PAL to read

**Acceptance Criteria:**
- Core enrollment: clones repo, writes device JSON, commits and pushes registration
- NextUI enrollment: detects `setup.json` on SD card, imports credentials, deletes setup file
- Test enrollment: scripted setup creates cloned repo with device registered
- Device name persisted and readable by PAL on next boot
- Credential stored at platform-appropriate location
- All tests pass under `busybox ash` (104 new tests)

**Dependencies:** Sprint 0.2 (PAL, path mapper)

---

### Sprint 0.4 — Cold Start Sync

**Status:** Complete

**Scope:**
- Implement cold start sync flow (`src/core/cold_start.sh`) — first run with no prior state (no sentinel, no stored commit)
- `cmp -s` all `.srm` files in both directions (device → repo, repo → device)
- Write only files that actually differ
- Conflicting files (same game, different bytes): repo wins, device version preserved as `.<device_name>.local` and committed
- Create sentinel file and store commit hash after initial sync
- Unit tests for cold start flow
- Integration test: cold start merge between device saves and repo saves

**Acceptance Criteria:**
- Cold start with empty repo + device saves: all device saves copied to repo, committed, pushed
- Cold start with repo saves + empty device: all repo saves copied to device at correct paths
- Cold start with identical saves on both sides: no unnecessary writes, no `.local` file
- Cold start with differing saves: repo wins on device, device version preserved as `.<device_name>.local` in repo and committed
- Sentinel file created after successful cold start
- Commit hash stored for boot pull comparison
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.3 (enrollment — cloned repo must exist)

---

### Sprint 0.5 — Boot Pull

**Status:** Complete

**Scope:**
- Implement boot pull sync (`src/core/boot_pull.sh`) — normal boot with existing sentinel and stored commit
- `git diff --name-only` against stored commit to identify remote changes
- Apply only changed remote saves to device
- Update stored commit hash after pull
- Unit and integration tests for boot pull flow

**Acceptance Criteria:**
- Detects remote changes since last stored commit
- Copies only changed saves to device (unchanged files untouched)
- Updates stored commit hash after successful pull
- No-op when no remote changes exist
- Handles the case where remote has new systems/files not on device (creates dirs)
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.4 (cold start — sentinel and commit tracking established)

---

### Sprint 0.6 — Runtime Poll

**Status:** Complete

**Scope:**
- Implement runtime change detection (`src/core/runtime_poll.sh`) — `find -newer` sentinel + `cmp -s` candidates
- Single poll cycle: detect local `.srm` changes, stage, commit, push confirmed changes
- Update sentinel after each sync cycle
- Unit and integration tests for runtime detection

**Acceptance Criteria:**
- `find -newer` sentinel identifies candidate changed files
- `cmp -s` against repo copy filters out false positives (touched but identical)
- Only truly changed files are committed and pushed
- Sentinel updated after each successful sync cycle
- Poll cycle is idempotent — no commit when nothing changed
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.5 (boot pull — sentinel lifecycle in steady state)

---

### Sprint 0.7 — Stale Boot Recovery

**Status:** Planned

**Scope:**
- Handle stale boot (`src/core/stale_boot.sh`) — sentinel exists but may be outdated (crash, unclean shutdown)
- Combine boot pull (fetch remote changes) with catch-up scan (detect local changes missed during interrupted session)
- Reconcile both directions before resuming normal operation
- Unit and integration tests for stale boot scenarios

**Acceptance Criteria:**
- Detects stale state (sentinel present but no clean shutdown marker)
- Pulls remote changes AND scans for local changes
- Correctly reconciles both directions without data loss
- Transitions to normal steady-state after recovery
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.6 (runtime poll — full sentinel lifecycle)

---

### Sprint 0.8 — Conflict Handler

**Status:** Planned

**Scope:**
- Implement `src/core/conflict_handler.sh` — detect git merge conflicts, preserve both versions with device attribution
- Conflict metadata format (`.conflict` JSON files with device names, timestamps)
- Resolution logic: `prompt`, `keep_newest`, `keep_device`
- Enumerate existing `.local` files across the repo for resolution UI
- Unit tests for conflict scenarios
- Integration test: simulate two-device conflict, verify both saves preserved

**Acceptance Criteria:**
- Merge conflict on `.srm` file preserves both versions (`.<device_name>.local` + canonical)
- Conflict metadata JSON written with device names and timestamps
- Resolution removes `.local` and `.conflict` artifacts and commits result
- Enumeration lists all `.local` files with device attribution
- No save data is ever silently overwritten
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.7 (all sync phases operational)

---

## Phase 1 — NextUI Platform Client (TrimUI Brick)

**Goal:** Working save sync on a TrimUI Brick. Core sync is already built — this phase wraps it in platform-specific daemon lifecycle and user-facing UI.

### Sprint 1.1 — NextUI Daemon

**Status:** Planned

**Scope:**
- Implement `src/platforms/nextui/continuity_daemon.sh` — main daemon loop
- Sources NextUI PAL, then core modules
- `auto.sh` hook integration for boot-time launch
- PID file management (prevent duplicate instances)
- Boot: detect state (cold start vs normal boot vs stale boot) → run appropriate sync phase
- Runtime: poll loop calling `runtime_poll` at 30-second intervals
- Graceful shutdown on SIGTERM (final push attempt, update sentinel)
- Manual test checklist for on-device validation

**Acceptance Criteria:**
- Daemon starts on boot via auto.sh
- Correctly dispatches to cold start, boot pull, or stale boot on startup
- Runtime poll detects changes within 30 seconds
- Commits and pushes when WiFi is available
- Queues commits locally when offline, pushes when connectivity returns
- Clean shutdown on SIGTERM with sentinel update
- Core tests pass under `busybox ash`

**Dependencies:** Sprint 0.8 (all core sync phases + conflict handler)

---

### Sprint 1.2 — NextUI Tool PAK

**Status:** Planned

**Scope:**
- Implement `src/platforms/nextui/Continuity.pak/launch.sh` — Tool PAK for sync UI
- Status display: last sync time, pending changes, linked devices
- Manual sync trigger
- Conflict resolution UI (show conflicted saves with device attribution, let user pick)
- Unlink device option

**Acceptance Criteria:**
- PAK appears in Tools menu on device
- Shows sync status, last sync time
- Manual sync pushes/pulls immediately
- Conflict resolution presents all `.local` files with device names
- Unlink removes device registration and clears credentials

**Dependencies:** Sprint 1.1 (daemon running)

---

## Phase 2 — Second Platform (RetroDeck / Steam Deck)

**Goal:** Cross-device sync works between TrimUI Brick and Steam Deck. Validates the PAL architecture with a fundamentally different platform.

### Sprint 2.1 — RetroDeck PAL and Enrollment

**Scope:**
- Implement RetroDeck PAL (`src/platforms/retrodeck/pal_retrodeck.sh`)
- CLI enrollment script (detect save paths, clone repo, register device)
- systemd user service definition for daemon
- Verify all core sync phases work with RetroDeck PAL (no core code changes expected)

---

### Sprint 2.2 — RetroDeck Daemon (inotify-based)

**Scope:**
- Daemon using `inotifywait` for event-driven change detection (replaces polling)
- Same core sync engine, different detection trigger
- Conflict resolution via desktop notification

---

### Sprint 2.3 — Cross-Device Integration Test

**Scope:**
- End-to-end test: save on Brick → sync → verify on RetroDeck (and reverse)
- Conflict scenario: save on both devices → verify both preserved with device attribution
- This sprint validates the entire PAL architecture across two real platforms

---

## Phase 3 — Additional Platforms

### Sprint 3.1 — Onion OS Client (outline)

New PAL implementation + enrollment trigger. Nearly identical to NextUI. Different save paths, different boot hook mechanism. Same core engine. No core code changes.

### Sprint 3.2 — Android Client (outline)

Java/Kotlin app implementing the PAL interface natively. JGit for git operations. `FileObserver` for change detection. Material UI for status and conflict resolution.

---

## Phase 4 — Polish and Community

### Sprint 4.1 — Enrollment Web Experience (outline)

- `idealos.dev/setup` — guided repo creation and App installation
- QR code for device setup URL

### Sprint 4.2 — Token Expiry and Rotation (outline)

- Warn when PAT approaching expiry
- Guide user through rotation without losing sync

### Sprint 4.3 — Documentation and Release (outline)

- User-facing setup guides per platform
- Core selection compatibility guide ("which cores produce compatible SRAM across devices")
- First public release

---

## Versioning

SemVer: `MAJOR.MINOR.PATCH`

| Milestone | Version |
|-----------|---------|
| Core sync engine + NextUI client working | 0.1.0 |
| RetroDeck client + cross-device validated | 0.2.0 |
| Onion OS + Android clients | 0.3.0 |
| Public release | 1.0.0 |

Dates intentionally omitted — ship when ready.
