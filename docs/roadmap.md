# Continuity — Development Roadmap

## Roadmap Philosophy

Small, modular sprints. Each sprint produces a testable, working increment. Platform clients are developed independently — they share core logic but have separate sprint tracks.

---

## Phase 0 — Foundation

**Goal:** Repo structure, shared core logic, test harness. Everything the platform clients build on.

### Sprint 0.1 — Repo Scaffolding and System Taxonomy

**Status:** In Progress

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

### Sprint 0.2 — Cold Start Sync

**Status:** Planned

**Scope:**
- Implement core modules: `path_mapper.sh`, `sync_engine.sh`, `wifi_monitor.sh`
- Implement cold start sync flow: first run with no prior state (no sentinel, no stored commit)
- `cmp -s` all `.srm` files in both directions (device → repo, repo → device)
- Write only files that actually differ
- Create sentinel file and store commit hash after initial sync
- Unit tests for all core functions
- Integration test: cold start merge between device saves and repo saves

**Acceptance Criteria:**
- Path mapper correctly translates all systems for all platforms
- Cold start detects and syncs saves in both directions
- Only differing files are written (identical files untouched)
- Sentinel file created after successful cold start
- Commit hash stored for future boot pull comparison
- Sync engine stages, commits, and pushes changed files
- WiFi monitor correctly reports online/offline
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.1 (taxonomy and platform maps)

---

### Sprint 0.3 — Boot Pull

**Status:** Planned

**Scope:**
- Implement boot pull sync: normal boot with existing sentinel and stored commit
- `git diff --name-only` against stored commit to identify remote changes
- Apply only changed remote saves to device
- Update stored commit hash after pull
- Unit and integration tests for boot pull flow

**Acceptance Criteria:**
- Detects remote changes since last stored commit
- Copies only changed saves to device (unchanged files untouched)
- Updates stored commit hash after successful pull
- No-op when no remote changes exist
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.2 (core modules, sentinel/commit tracking)

---

### Sprint 0.4 — Runtime Poll

**Status:** Planned

**Scope:**
- Implement runtime change detection: `find -newer` sentinel + `cmp -s` candidates
- Poll loop detects local `.srm` changes during gameplay
- Stage, commit, and push confirmed changes
- Update sentinel after each sync cycle
- Unit and integration tests for runtime detection

**Acceptance Criteria:**
- `find -newer` sentinel identifies candidate changed files
- `cmp -s` filters out false positives (touched but identical files)
- Only truly changed files are committed and pushed
- Sentinel updated after each successful sync cycle
- Poll cycle is idempotent — no commit when nothing changed
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.3 (boot pull, sentinel lifecycle)

---

### Sprint 0.5 — Stale Boot Recovery

**Status:** Planned

**Scope:**
- Handle stale boot: sentinel exists but may be outdated (crash, unclean shutdown)
- Combine boot pull (fetch remote changes) with catch-up scan (detect local changes missed by missing shutdown)
- Reconcile both directions before resuming normal operation
- Unit and integration tests for stale boot scenarios

**Acceptance Criteria:**
- Detects stale state (sentinel present but no clean shutdown marker)
- Pulls remote changes AND scans for local changes
- Correctly reconciles both directions without data loss
- Transitions to normal steady-state after recovery
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.4 (runtime poll, full sentinel lifecycle)

---

### Sprint 0.6 — Conflict Handler

**Status:** Planned

**Scope:**
- Implement `src/core/conflict_handler.sh` — detect merge conflicts, preserve both versions
- Conflict metadata format (`.conflict` JSON files)
- Resolution logic: `prompt`, `keep_newest`, `keep_device`
- Unit tests for conflict scenarios
- Integration test: simulate two-device conflict, verify both saves preserved

**Acceptance Criteria:**
- Merge conflict on `.srm` file preserves both versions (`.local` + canonical)
- Conflict metadata JSON written with device names and timestamps
- Resolution removes conflict artifacts and commits result
- No save data is ever silently overwritten
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.5 (all sync phases operational)

---

## Phase 1 — First Platform Client (NextUI / TrimUI Brick)

**Goal:** Working save sync on a TrimUI Brick. This is the proof of concept.

### Sprint 1.1 — Enrollment (SD Card Import)

**Status:** Planned

**Scope:**
- Implement `src/enrollment/sd_card_import.sh` — detect and import `.continuity/setup.json` from SD card
- Credential storage layout on device
- Initial `git clone` of user's repo
- Device registration in `.continuity/devices/`
- Unit tests for import parsing, credential storage

**Acceptance Criteria:**
- Setup JSON detected on boot, credentials imported, setup file deleted
- Repo cloned to device
- Device JSON written to `.continuity/devices/`
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.2 (core modules for git clone)

---

### Sprint 1.2 — NextUI Daemon

**Status:** Planned

**Scope:**
- Implement `src/platforms/nextui/continuity_daemon.sh` — main daemon loop
- `auto.sh` hook integration for boot-time launch
- PID file management (prevent duplicate instances)
- Pull on boot, poll loop, push on change
- Graceful shutdown on SIGTERM
- Manual test checklist for on-device validation

**Acceptance Criteria:**
- Daemon starts on boot via auto.sh
- Pulls latest saves on startup
- Detects `.srm` changes within 30 seconds
- Commits and pushes when WiFi is available
- Queues commits locally when offline, pushes when connectivity returns
- Clean shutdown on SIGTERM
- Core tests pass under `busybox ash`

**Dependencies:** Sprint 1.1 (enrollment), Sprint 0.6 (conflict handler)

---

### Sprint 1.3 — NextUI Tool PAK

**Status:** Planned

**Scope:**
- Implement `src/platforms/nextui/Continuity.pak/launch.sh` — Tool PAK for sync UI
- Status display: last sync time, pending changes, linked devices
- Manual sync trigger
- Conflict resolution UI (show conflicted saves, let user pick)
- Enrollment via local web setup (alternative to SD card)
- Unlink device option

**Acceptance Criteria:**
- PAK appears in Tools menu on device
- Shows sync status, last sync time
- Manual sync pushes/pulls immediately
- Conflict resolution presents both saves with device attribution
- Web setup flow works from phone browser

**Dependencies:** Sprint 1.2 (daemon running)

---

## Phase 2 — Second Platform (RetroDeck / Steam Deck)

**Goal:** Cross-device sync works between TrimUI Brick and Steam Deck.

### Sprint 2.1 — RetroDeck Setup Script

**Scope:**
- CLI setup script for RetroDeck (detect save paths, clone repo, install systemd service)
- Path mapping validation for RetroDeck directory structure
- systemd user service for daemon

---

### Sprint 2.2 — RetroDeck Daemon (inotify-based)

**Scope:**
- Daemon using `inotifywait` for event-driven change detection
- Same core sync engine, different change detector
- Conflict resolution via desktop notification

---

### Sprint 2.3 — Cross-Device Integration Test

**Scope:**
- End-to-end test: save on Brick → sync → verify on RetroDeck (and reverse)
- Conflict scenario: save on both devices → verify both preserved
- This sprint validates the entire architecture across two real platforms

---

## Phase 3 — Additional Platforms

### Sprint 3.1 — Onion OS Client (outline)

Similar to NextUI. Different save paths, different boot hook mechanism. Same core engine.

### Sprint 3.2 — Android Client (outline)

Java/Kotlin app wrapping the core sync logic. Native `FileObserver`, Material UI for status and conflicts.

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
