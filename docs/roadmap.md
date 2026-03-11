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

### Sprint 0.3 — NextUI Fork Integration (outline)

**Scope (tentative):**
- Clone/integrate NextUI into `upstream/nextui/`
- Document inherited components and their locations
- Disable conflicting NextUI subsystems per fork-and-harvest plan
- Validate minimal boot flow documentation

---

### Sprint 0.4 — CI and Code Quality Baseline (outline)

**Scope (tentative):**
- ShellCheck integration for all `.sh` files
- JSON validation for all `.json` files
- GitHub Actions workflow for test + lint on push
- Pre-commit hooks (optional)

---

## Phase 1 — Session Manager

**Goal:** Build the core differentiating feature — resume-centric gameplay.

**Reference spec:** `docs/architecture/ideal_os_session_manager_technical_architecture_spec.md`

### Sprint 1.1 — Session Data Model and Persistence (outline)

- Session record schema
- Atomic write helper (`src/common/`)
- Registry CRUD operations (`src/session/registry/`)
- Unit tests for all persistence operations

### Sprint 1.2 — Session API (outline)

- `create_session`, `suspend_current_session`, `resume_session`
- `get_active_session`, `list_sessions`, `discard_session`
- API integration tests

### Sprint 1.3 — Resume Stack (outline)

- Stack data structure and operations
- Max session limit (8) and auto-prune
- `restore_last_session` flow

### Sprint 1.4 — Power Event Hooks (outline)

- Sleep/shutdown detection
- Auto-suspend on power events
- Boot resume flow (`last-session.json`)

### Sprint 1.5 — Session Hardening (outline)

- Validation and recovery
- Corrupt state handling
- Edge case tests

---

## Phase 2 — Background Task Scheduler

**Goal:** Coordinate all background work so gameplay is never disrupted.

**Reference spec:** `docs/architecture/ideal_os_background_services_and_task_scheduler_spec.md`

### Sprint 2.1 — Core Scheduler (outline)
### Sprint 2.2 — Policy Engine and Resource Budgets (outline)
### Sprint 2.3 — Scheduler Integration Tests (outline)

---

## Phase 3 — Cloud Sync

**Goal:** Automatic save backup and cross-device continuity.

**Reference spec:** `docs/architecture/ideal_os_cloud_sync_and_cross_device_continuity_spec.md`

### Sprint 3.1 — Local Sync Engine (outline)
### Sprint 3.2 — Cloud Upload (OneDrive/Google Drive) (outline)
### Sprint 3.3 — Conflict Resolution (outline)
### Sprint 3.4 — Cross-Device Pull (outline)

---

## Phase 4 — Notifications and Guardian Alerts

**Goal:** System health communication and family-safe reliability.

**Reference spec:** `docs/architecture/ideal_os_notifications_and_guardian_alerts_spec.md`

### Sprint 4.1 — Local Notification Engine (outline)
### Sprint 4.2 — Guardian Alerts (outline)

---

## Phase 5 — OTA Updates

**Goal:** In-place upgrades without SD card reflash.

**Reference spec:** `docs/architecture/ideal_os_ota_update_architecture_spec.md`

### Sprint 5.1 — Manifest System and Version Comparison (outline)
### Sprint 5.2 — Package Download and Staging (outline)
### Sprint 5.3 — Apply and Migration (outline)
### Sprint 5.4 — Channel Workflow (stable/beta/dev) (outline)

---

## Phase 6 — Library Manager

**Goal:** ROM discovery, game identity management, favorites, collections.

### Sprint 6.1 — ROM Scanner and Game Database (outline)
### Sprint 6.2 — Favorites, Recents, and Collections (outline)
### Sprint 6.3 — Search Index (outline)

---

## Phase 7 — Emulation Layer

**Goal:** Wrap NextUI emulator launch path with session and scheduler integration.

### Sprint 7.1 — Launch Orchestration and Core Selection (outline)
### Sprint 7.2 — Save State and Suspend/Resume Wrappers (outline)

---

## Phase 8 — Launcher Integration

**Goal:** Tie all subsystems together in the user-facing launcher.

### Sprint 8.1 — Session Manager and Library Integration (outline)
### Sprint 8.2 — Sync Status and Notifications (outline)
### Sprint 8.3 — OTA Update UI (outline)

---

## Phase 9 — Polish and Public Release

### Sprint 9.1 — Performance Optimization (outline)
### Sprint 9.2 — Documentation and Release Notes (outline)
### Sprint 9.3 — Release Candidate Testing (outline)

---

## Versioning

Each completed phase that produces a shippable increment gets a Stardate version:

| Milestone | Target Stardate |
|-----------|----------------|
| First flashable build (Session Manager working) | TBD |
| Cloud Sync functional | TBD |
| OTA working | TBD |
| Public release | TBD |

Dates are intentionally omitted — we ship when it's ready, not when a calendar says so.
