# Ideal OS – Development Roadmap

## Roadmap Philosophy

This roadmap is **skeletal by design**. Only the current and next sprint are fully detailed. Future sprints have a scope outline but no acceptance criteria — those are filled in iteratively as we approach them.

This prevents premature over-specification while keeping the overall trajectory visible.

---

## Phase 0 — Foundation

**Goal:** Establish the repo, tooling, and development workflow so all future sprints have a stable base to build on.

### Sprint 0.1 — Repo Scaffolding and Test Harness

**Status:** Complete

**Scope:**
- Create the canonical directory tree per `ideal_os_repo_structure_spec.md`
- Implement a POSIX sh test runner (`scripts/test.sh`)
- Add initial test fixtures and a sample test to validate the harness
- Create `docs/agent-workflow.md` (orchestrator/coder/QA protocol)
- Create `docs/testing.md` (how to write and run tests)
- Add `.gitkeep` files to preserve empty directory structure

**Acceptance Criteria:**
- All directories from the repo structure spec exist
- `scripts/test.sh` runs and reports pass/fail
- At least one sample test passes
- Agent workflow and testing docs are complete

**Sprint Spec:** `docs/sprints/sprint-0.1.md`

---

### Sprint 0.2 — Shared Data Contracts

**Status:** Complete

**Scope:**
- Implement `src/common/game_identity.sh` — game_id format (`system:game_name`), system taxonomy, ROM path conventions
- Implement `src/common/event_bus.sh` — file-based event log (append events to `runtime/events/`, consumers tail/poll)
- Define event schema: `{"_schema_version": "1.0", "timestamp": "...", "source": "...", "event_type": "...", "payload": {...}}`
- Unit tests for game identity parsing and event log read/write

---

### Sprint 0.3 — NextUI Hard Fork and Analysis (outline)

**Scope (tentative):**
- Bring NextUI source into `upstream/nextui/src/` as a hard fork baseline (not an upstream-tracking dependency) ✅
- Walk the full source tree and produce a file-level component map
- Disposition every component against the audit matrix (keep / eventually-replace) — but **remove nothing yet**
- Document the build system: makefiles, toolchain, cross-compilation, artifact output
- Document NextUI's existing update mechanism (critical path for Phase 2)
- Produce `upstream/nextui/manifest.md` documenting every component and its disposition

**Key principle:** Analyze and map everything. Keep the system intact and bootable. Stripping happens incrementally as replacements are built.

---

### Sprint 0.4 — Boot Flow Analysis (outline)

**Scope (tentative):**
- Trace the NextUI boot sequence from power-on through launcher display
- Document every script, binary, and config file involved in the boot chain
- Identify Ideal OS hook points (boot animation, session resume, launcher handoff)
- Produce `upstream/nextui/notes/boot-flow-analysis.md`

---

### Sprint 0.5 — Conflict Analysis and Integration Boundaries (outline)

**Scope (tentative):**
- Deep analysis of NextUI subsystems that overlap with Ideal OS goals (launcher, updater, `.system/` folder, PAK store)
- Document specific wrap vs. replace strategies with file-level detail
- Define the integration boundary: where NextUI platform layer ends and Ideal OS core services begin
- Produce `upstream/nextui/notes/conflict-analysis.md`

---

### Sprint 0.6 — CI and Code Quality Baseline (outline)

**Scope (tentative):**
- ShellCheck integration for all `.sh` files
- JSON validation for all `.json` files
- GitHub Actions workflow for test + lint on push
- Pre-commit hooks (optional)

---

## Phase 1 — Build Pipeline and First Boot

**Goal:** Produce a flashable Ideal OS image from source and boot it on the TrimUI Brick. No functional changes from NextUI — just prove we own the build.

### Sprint 1.1 — Cross-Compilation and Build System (outline)

- Understand and document the NextUI build toolchain (ARM cross-compiler, makefile structure)
- Reproduce the NextUI build from source in CI or local dev environment
- Produce a flashable SD card image or update package

### Sprint 1.2 — First Boot and Smoke Test (outline)

- Flash the build to a TrimUI Brick
- Verify boot, launcher display, and emulator launch all work
- Document any delta from stock NextUI behavior
- Establish the "known good baseline" — this is the starting point for all future changes

### Sprint 1.3 — Ideal OS Branding Pass (outline)

- Boot logo, launcher name, about screen
- Minimal reskin to distinguish Ideal OS from stock NextUI
- No functional changes — cosmetic only

---

## Phase 2 — OTA Updates

**Goal:** In-place upgrades without SD card reflash. This is the critical dev iteration loop — the sooner OTA works, the faster everything else moves.

**Reference spec:** `docs/architecture/ideal_os_ota_update_architecture_spec.md`

### Sprint 2.1 — Existing Updater Analysis (outline)

- Deep-dive into NextUI's current update mechanism
- Determine what can be reused vs. what needs replacing
- Define Ideal OS OTA architecture (may evolve the existing updater rather than replacing from scratch)

### Sprint 2.2 — Manifest System and Version Comparison (outline)

- Package manifests, version diffing, update eligibility checks

### Sprint 2.3 — Package Download and Staging (outline)

- Download update packages from a remote source, stage for apply

### Sprint 2.4 — Apply and Migration (outline)

- Apply staged updates, handle schema migrations, rollback on failure

### Sprint 2.5 — Channel Workflow (stable/beta/dev) (outline)

- Update channels for staged rollouts

---

## Phase 3 — Session Manager

**Goal:** Build the core differentiating feature — resume-centric gameplay.

**Reference spec:** `docs/architecture/ideal_os_session_manager_technical_architecture_spec.md`

### Sprint 3.1 — Session Data Model and Persistence (outline)

- Session record schema
- Atomic write helper (`src/common/`)
- Registry CRUD operations (`src/session/registry/`)
- Unit tests for all persistence operations

### Sprint 3.2 — Session API (outline)

- `create_session`, `suspend_current_session`, `resume_session`
- `get_active_session`, `list_sessions`, `discard_session`
- API integration tests

### Sprint 3.3 — Resume Stack (outline)

- Stack data structure and operations
- Max session limit (8) and auto-prune
- `restore_last_session` flow

### Sprint 3.4 — Power Event Hooks (outline)

- Sleep/shutdown detection
- Auto-suspend on power events
- Boot resume flow (`last-session.json`)

### Sprint 3.5 — Session Hardening (outline)

- Validation and recovery
- Corrupt state handling
- Edge case tests

---

## Phase 4 — Background Task Scheduler

**Goal:** Coordinate all background work so gameplay is never disrupted.

**Reference spec:** `docs/architecture/ideal_os_background_services_and_task_scheduler_spec.md`

### Sprint 4.1 — Core Scheduler (outline)
### Sprint 4.2 — Policy Engine and Resource Budgets (outline)
### Sprint 4.3 — Scheduler Integration Tests (outline)

---

## Phase 5 — Cloud Sync

**Goal:** Automatic save backup and cross-device continuity.

**Reference spec:** `docs/architecture/ideal_os_cloud_sync_and_cross_device_continuity_spec.md`

### Sprint 5.1 — Local Sync Engine (outline)
### Sprint 5.2 — Cloud Upload (OneDrive/Google Drive) (outline)
### Sprint 5.3 — Conflict Resolution (outline)
### Sprint 5.4 — Cross-Device Pull (outline)

---

## Phase 6 — Notifications and Guardian Alerts

**Goal:** System health communication and family-safe reliability.

**Reference spec:** `docs/architecture/ideal_os_notifications_and_guardian_alerts_spec.md`

### Sprint 6.1 — Local Notification Engine (outline)
### Sprint 6.2 — Guardian Alerts (outline)

---

## Phase 7 — Library Manager

**Goal:** ROM discovery, game identity management, favorites, collections.

### Sprint 7.1 — ROM Scanner and Game Database (outline)
### Sprint 7.2 — Favorites, Recents, and Collections (outline)
### Sprint 7.3 — Search Index (outline)

---

## Phase 8 — Emulation Layer

**Goal:** Wrap NextUI emulator launch path with session and scheduler integration.

### Sprint 8.1 — Launch Orchestration and Core Selection (outline)
### Sprint 8.2 — Save State and Suspend/Resume Wrappers (outline)

---

## Phase 9 — Launcher Integration

**Goal:** Tie all subsystems together in the user-facing launcher.

### Sprint 9.1 — Session Manager and Library Integration (outline)
### Sprint 9.2 — Sync Status and Notifications (outline)
### Sprint 9.3 — OTA Update UI (outline)

---

## Phase 10 — Polish and Public Release

### Sprint 10.1 — Performance Optimization (outline)
### Sprint 10.2 — Documentation and Release Notes (outline)
### Sprint 10.3 — Release Candidate Testing (outline)

---

## Versioning

Each completed phase that produces a shippable increment gets a Stardate version:

| Milestone | Target Stardate |
|-----------|----------------|
| First bootable build (unmodified NextUI from our build pipeline) | TBD |
| OTA update working (dev iteration loop closed) | TBD |
| Session Manager functional | TBD |
| Cloud Sync functional | TBD |
| Public release | TBD |

Dates are intentionally omitted — we ship when it's ready, not when a calendar says so.
