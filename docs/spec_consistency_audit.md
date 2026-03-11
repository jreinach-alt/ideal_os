# Ideal OS — Spec Consistency Audit

**Date:** 2026-03-11
**Scope:** All 10 technical spec documents, CLAUDE.md, roadmap
**Purpose:** Identify internal contradictions across data formats, module boundaries, and dependency ordering before Sprint 0.1 launch.

---

## Executive Summary

The audit found **28 distinct issues** across three dimensions. The most critical cluster is a **governance gap in the repo structure spec** — it omits three entire subsystem modules (`tasks`, `sync`, `notifications`) from `src/`, `runtime/`, and `config/`, despite each having a full specification document. This will block implementation the moment any coding agent tries to create files for those modules.

The second critical cluster is **data format fragmentation**: the `game_id` field has two incompatible definitions, `_schema_version` has three conflicting conventions, and the on-device path namespace (`runtime/X/` vs `/ideal/X/`) is unresolved.

The third is a **coordination vacuum around power events** — three specs independently describe shutdown/sleep handling with no shared protocol.

---

## Part 1 — Data Format Contradictions

### DF-1: `game_id` format mismatch (HIGH)

| Spec | Format | Example |
|------|--------|---------|
| Session Manager (line 313) | `system:game_name` | `snes:super_metroid` |
| Cloud Sync (line 187) | bare game name | `super_metroid` |

Cross-module lookups by `game_id` will fail. One includes the system prefix, the other doesn't.

**Resolution needed:** Pick one format. Recommend `system:game_name` since it's globally unique.

### DF-2: `_schema_version` — three conflicting conventions (HIGH)

| Source | Field Name | Type | Example |
|--------|-----------|------|---------|
| CLAUDE.md (line 186) | `_schema_version` | string | `"1.0"` |
| Session Manager (lines 324, 355) | `schema_version` | integer | `1` |
| OTA spec (line 219) | `schemas` | object of integers | `{"sessions": 1}` |

CLAUDE.md mandates the underscore-prefixed string convention. Every spec example violates it.

**Resolution needed:** Align all specs to the CLAUDE.md convention, or update CLAUDE.md to match reality.

### DF-3: Missing `_schema_version` in multiple record types (MEDIUM)

The following JSON examples lack the mandated `_schema_version` field:
- Task Scheduler: task record (line 402)
- Cloud Sync: artifact index record (lines 182-194)
- OTA: channel manifest (line 179), release manifest (line 199)

### DF-4: Hash field naming divergence (MEDIUM)

| Spec | Field | Convention |
|------|-------|-----------|
| Cloud Sync (line 193) | `"hash"` | Generic name, algorithm in value |
| OTA (line 207) | `"sha256"` | Algorithm IS the field name |
| CLAUDE.md (line 245) | `a13fd98c` (in session ID) | Truncated, algorithm unspecified |

**Resolution needed:** Standardize on one convention. Recommend `"sha256": "<hash>"` for explicitness.

### DF-5: Timestamp field names for "last changed" (MEDIUM)

| Spec | Field |
|------|-------|
| Session Manager (line 321) | `updated_at` |
| Cloud Sync (line 189) | `last_modified` |
| Session Manager index (line 363) | `sort_key` |

Three names for the same concept. When Cloud Sync syncs session metadata, these will collide.

### DF-6: `device_id` referenced but never defined (MEDIUM)

Cloud Sync (line 191) introduces `"device_id": "brick-a"`. Notification spec (line 119) references "device nickname." No system-level spec defines device identity generation, storage, or format.

### DF-7: ROM fingerprint vs hash ambiguity (LOW)

Cloud Sync (line 307) lists "ROM fingerprint" as required metadata. The artifact record (line 193) uses `"hash"`. Unclear if these are the same field.

### DF-8: Session ID timestamp format vs JSON timestamp format (LOW)

Session IDs use compact ISO 8601 (`20260310T211455Z`). JSON fields use extended ISO 8601 (`2026-03-10T21:14:55Z`). This is internally consistent by context but never explicitly documented as intentional.

---

## Part 2 — Module Boundary Conflicts

### MB-1: Save state file paths — two authoritative locations (HIGH)

| Spec | Path | Purpose |
|------|------|---------|
| Session Manager (line 180) | `runtime/sessions/store/<id>/state.sav` | Session-managed save states |
| Cloud Sync (line 188) | `/userdata/saves/<system>/<game>.srm` | Sync source for save files |

Neither spec acknowledges the other's path. Cloud Sync could sync stale data if Session Manager has moved the authoritative copy.

**Resolution needed:** Define the canonical save state location and whether Session Manager copies or references in-place.

### MB-2: Power event orchestration — three independent handlers (HIGH)

| Module | Claim |
|--------|-------|
| Session Manager (lines 246-258) | `src/session/power/` coordinates timing with emulator exit |
| Task Scheduler (lines 442-477) | Defines full sleep/shutdown pipeline as numbered sequence |
| Cloud Sync (lines 236-258) | Own shutdown behavior with UI overlay and skip button |

Session Manager says it coordinates timing. Task Scheduler says it orchestrates the sequence. Cloud Sync implements its own UI. These are contradictory ownership claims.

**Resolution needed:** Choose one orchestrator (recommend Task Scheduler) and make the others registered participants.

### MB-3: Game launch orchestration — unowned (HIGH)

| Source | Claim |
|--------|-------|
| Session Manager (lines 406-415) | Describes itself orchestrating the full launch flow |
| Repo structure (lines 157-158) | Assigns "launch orchestration" to `src/emulation/` |
| Platform audit (line 57) | Says launch path should be "wrapped" |

No spec defines `src/emulation/`'s API. The actual call chain is undefined.

### MB-4: No other spec acknowledges the Task Scheduler (HIGH)

The scheduler assumes it coordinates Cloud Sync, Session Manager, OTA, and Notifications. None of those specs mention the scheduler. Cloud Sync defines its own "Background Worker" (line 165) and internal upload queue. This is a fundamental integration gap.

### MB-5: Dual queue for sync operations (MEDIUM)

- Cloud Sync: maintains queue at `runtime/sync/queue/` (line 222)
- Task Scheduler: defines sync queue at `runtime/tasks/queues/sync.json` (line 588)

Two queues for the same domain, owned by different modules.

### MB-6: "Recently Played" — Library vs Session Manager (MEDIUM)

Repo structure assigns "recents" to Library. Session Manager tracks recency via the resume stack. Games without suspend support (e.g., N64) would not create sessions and would be invisible to the resume stack. No spec defines whether "recents" derives from Library, Session Manager, or both.

### MB-7: Boot flow has no single owner (MEDIUM)

- Session Manager (lines 596-617): boot starts with `last-session.json`
- Task Scheduler (lines 620-633): boot starts with scheduler state restoration
- Cloud Sync (lines 262-275): boot starts with startup pull

No spec defines the canonical boot sequence or who orchestrates it.

### MB-8: Schema migration ownership is split (MEDIUM)

OTA Updater (lines 376-408) and Session Manager (line 699) both claim `tools/migration/`. No naming convention distinguishes whose migrations are whose.

### MB-9: Cloud Sync bypasses notification architecture (LOW)

Cloud Sync (line 248) creates its own "Syncing saves..." overlay with "B = Skip" button during shutdown. This bypasses the centralized Notification Policy Engine defined in the notification spec (lines 273-283).

### MB-10: User settings have no unified model (LOW)

Cloud Sync, Notifications, OTA Updater, and Session Manager each define their own configuration paths. No spec defines a unified settings data model for the launcher's settings UI to consume.

---

## Part 3 — Dependency Ordering Issues

### DO-1: Library Manager data model needed much earlier than Phase 7 (HIGH)

The `game_id` format appears in Session Manager session IDs, Cloud Sync artifact records, and OTA migration references — all of which are built in Phases 1-5. But Library Manager (which would own the game identity taxonomy) is at build position 7 / roadmap Phase 6+.

**Resolution needed:** Extract the Library data model (game identity, system taxonomy) into Phase 0 or Phase 1 as a shared contract, even if the full Library Manager is deferred.

### DO-2: Emulation Layer has no spec but is a dependency for Session Manager (HIGH)

Session Manager's launch/suspend/resume flow requires emulation APIs (launch, save state, load state, detect exit). No emulation spec exists. The emulation layer is at build position 8 but Session Manager needs it at position 1.

**Resolution needed:** Write a minimal emulation interface spec before Sprint 1.1.

### DO-3: System module has no spec but is universally assumed (MEDIUM)

Power events, WiFi status, system state (gameplay/idle/launcher), and device identity have no defined source. Multiple modules need these signals. No `src/system/` spec exists.

### DO-4: No event bus or pub-sub infrastructure defined (MEDIUM)

Notification spec (lines 240-267) and Task Scheduler (lines 480-493) both assume event subscription from other modules. Neither Cloud Sync nor Session Manager defines event emission. No shared infrastructure exists.

### DO-5: Notification spec expects events from modules that don't define them (MEDIUM)

The notification spec lists specific events it expects:
- From Cloud Sync: backup completed, upload failure, provider disconnected, storage quota exceeded, conflict detected
- From Session Manager: corrupted save state, resume failure, session data invalid

Neither source spec defines these event interfaces.

### DO-6: Roadmap has no phases for Library Manager or Emulation Layer (MEDIUM)

CLAUDE.md lists them at build positions 7 and 8. The roadmap's Phase 6 is "Launcher Integration" and Phase 7 is "Polish." Library and Emulation have no dedicated implementation phases.

### DO-7: No event bus or pub-sub infrastructure exists anywhere (MEDIUM-HIGH)

The Notification spec (lines 240-267) assumes it can subscribe to events from Cloud Sync and Session Manager. The Task Scheduler (lines 480-493) assumes event subscription for escalation hooks. Neither Cloud Sync nor Session Manager defines an event emission or subscription mechanism. This implies a **missing foundational infrastructure component** — a common event bus or pub-sub system in `src/common/` — that no spec, roadmap phase, or sprint addresses.

Without this infrastructure, the Notification System has no events to classify, the Task Scheduler cannot receive subsystem-originated task requests, and Cloud Sync cannot receive session lifecycle events for Tier 3 artifacts.

### DO-8: Cloud Sync describes its own "Background Worker" that conflicts with Task Scheduler (MEDIUM)

Cloud Sync (line 166) defines a "Background Worker" as an internal architecture component with its own upload queue at `runtime/sync/queue/`. The Task Scheduler (lines 69-76) explicitly claims Cloud Sync as a managed subsystem: "the Sync Manager decides *what* needs upload; the scheduler decides *when* upload may run."

The Cloud Sync spec never mentions the Task Scheduler. It describes its own independent background worker with its own queue, shutdown flush behavior, and timing constraints. This creates ambiguity about whether sync background work is self-managed or scheduler-managed.

### DO-9: Task Scheduler forward-depends on Notification System (LOW)

Task Scheduler (position 2) needs Notification System (position 4) for escalation hooks. Mitigated by the scheduler's internal phasing deferring notification integration to its Phase 3.

### DO-10: No circular dependencies found

This is a positive finding. Despite the gaps above, no A→B→A cycles exist.

---

## Part 4 — Repo Structure Spec Gaps

The repo structure spec (`docs/ideal_os_repo_structure_spec.md`) is designated as "the binding authority on where files go" by CLAUDE.md. It is missing the following paths that other specs reference:

### Missing from `src/`

| Path | Referenced By |
|------|-------------|
| `src/tasks/` | CLAUDE.md, Task Scheduler spec |
| `src/sync/` | CLAUDE.md, Cloud Sync spec, Fork-and-Harvest Plan |
| `src/notifications/` | CLAUDE.md, Fork-and-Harvest Plan |

### Missing from `runtime/`

| Path | Referenced By |
|------|-------------|
| `runtime/tasks/` | Task Scheduler spec (line 584) |
| `runtime/sync/` | Cloud Sync spec (line 177) |
| `runtime/notifications/` | Notifications spec (line 295) |

### Missing from `config/`

| Path | Referenced By |
|------|-------------|
| `config/tasks/` | Task Scheduler spec (line 737) |
| `config/sync/` | Cloud Sync spec (line 445) |

### On-device path namespace unresolved

| Source | Convention |
|--------|-----------|
| Subsystem specs | `runtime/X/` |
| NextUI Platform Audit (lines 240-247) | `/ideal/X/` |

No document explains the mapping between repo paths and on-device paths.

### Missing OTA package definitions

The following Ideal OS-native modules need to be updatable but have no package definition in `packages/`:
- `sync`
- `tasks`
- `notifications`

---

## Resolution Status

Updated 2026-03-11 after P0/P1 fix pass.

| Priority | Action | Status | Resolution |
|----------|--------|--------|------------|
| **P0** | Update repo structure spec to include `tasks`, `sync`, `notifications` in `src/`, `runtime/`, `config/` | **RESOLVED** | Added to all sections of repo structure spec including packages/ |
| **P0** | Standardize `game_id` format across all specs | **RESOLVED** | All specs now use `system:game_name` (e.g., `snes:super_metroid`). Codified in CLAUDE.md Data Formats. |
| **P0** | Standardize `_schema_version` convention (name, type) | **RESOLVED** | All JSON examples updated to `"_schema_version": "1.0"` (underscore-prefixed, string). OTA `schemas` field renamed to `schema_versions` with string values. |
| **P1** | Extract Library data model (game identity, system taxonomy) into shared contract | **RESOLVED** | `src/common/game_identity.sh` added to Phase 0 Sprint 0.2 in roadmap. Referenced in CLAUDE.md Shared Infrastructure. |
| **P1** | Write minimal emulation interface spec | **OPEN** | Deferred to pre-Phase-7 work. Emulation Layer now has its own roadmap phase (Phase 7). |
| **P1** | Resolve power-event orchestration | **RESOLVED** | Task Scheduler is sole orchestrator. Session Manager, Cloud Sync, Notifications are registered participants. Updated in all three specs. |
| **P1** | Define canonical save state file path | **RESOLVED** | Session Manager references in-place at emulator native paths. No copying. Documented in session spec and CLAUDE.md. |
| **P1** | Define a common event bus / pub-sub mechanism | **RESOLVED** | File-based event log in `src/common/event_bus.sh`. Events appended to `runtime/events/`. Added to Phase 0 Sprint 0.2 and CLAUDE.md. |
| **P2** | Add scheduler integration sections to Cloud Sync, OTA, Session Manager, Notification specs | **PARTIALLY RESOLVED** | Cloud Sync shutdown behavior updated to reference scheduler pipeline. Session Manager power hooks updated. Full integration sections deferred to Phase 2 sprints. |
| **P2** | Define on-device path mapping (`runtime/X/` → `/ideal/X/`) | **OPEN** | Deferred to Sprint 0.3 (NextUI fork integration). |
| **P2** | Standardize hash field naming convention | **RESOLVED** | All specs use `sha256` as field name. Codified in CLAUDE.md Data Formats. |
| **P2** | Write minimal System module spec | **OPEN** | Deferred. System module receives power events from NextUI and forwards to Task Scheduler. |
| **P2** | Add Library Manager and Emulation Layer phases to roadmap | **RESOLVED** | Phase 6 (Library Manager) and Phase 7 (Emulation Layer) added to roadmap. |
| **P3** | Standardize timestamp field names for "last changed" | **RESOLVED** | All specs use `updated_at`. Codified in CLAUDE.md Data Formats. |
| **P3** | Define device identity generation and storage | **OPEN** | Deferred to Cloud Sync implementation (Phase 3). |
