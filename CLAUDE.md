# Ideal OS – Claude Code Operating Manual

## Project Overview

Ideal OS is a curated appliance-style operating system for the TrimUI Brick retro gaming handheld, built on top of NextUI. The device should feel like a console, not a Linux project.

Target hardware: TrimUI Brick (ARM Linux)
Versioning: Stardate format `YYMM.R` (e.g., Stardate 2601.1)

## Repository Structure Contract

The canonical layout is defined in `docs/architecture/ideal_os_repo_structure_spec.md`. That document is the binding authority on where files go.

### Strict Rules

1. **No new top-level folders** without updating the repo structure spec first.
2. **No source code** in `upstream/`, `assets/`, or `release/`.
3. **No generated files** in `src/` or `config/`.
4. **No runtime data** scattered in docs — schemas go under `runtime/`.
5. **Module-first placement** — if code belongs to launcher, session, library, emulation, system, updater, tasks, sync, notifications, or common, place it in that `src/` module.

### Key Paths

- `src/` — All Ideal OS source code
- `config/` — Version-controlled default configurations (not runtime data)
- `runtime/` — On-device runtime layout templates and schemas
- `tests/` — All tests (unit, integration, fixtures, manual checklists)
- `scripts/` — Build and automation scripts
- `tools/` — Developer utilities (not shipped)
- `upstream/` — Upstream tracking only (NextUI patches, notes, references)
- `packages/` — OTA-oriented package definitions
- `release/` — Release manifests and artifacts

## Development Methodology

### Sprint-Based, Spec-Driven

All work is organized into micro-sprints. Each sprint:

1. Starts with an approved spec (scope, acceptance criteria, tests required, out-of-scope)
2. Is implemented by coding agents
3. Is validated by a QA agent against the spec
4. Ends with a working, tested increment

Do not begin implementation without an approved sprint spec.

### Agent Team Protocol

| Role | Responsibility |
|------|---------------|
| **Orchestrator** | Writes sprint specs, coordinates agents, reviews results, merges work |
| **Coding Agent** | Implements the spec. Works in isolated worktrees when possible. |
| **QA Agent** | Validates implementation against acceptance criteria. Runs tests. Reports defects. |

Feedback loop: Spec → Implement → QA Validate → Fix Defects → QA Re-validate → Merge.

### Branch and Worktree Convention

**Branch naming:**

| Purpose | Pattern | Example |
|---------|---------|---------|
| Sprint implementation | `sprint/<X.Y>` | `sprint/0.1` |
| Defect fix during QA | `fix/sprint-<X.Y>-defect-<N>` | `fix/sprint-0.1-defect-1` |
| Exploratory/throwaway | `scratch/<short-desc>` | `scratch/test-busybox-compat` |

**Merge target:** Sprint branches merge into `main` (or the designated development branch) via the orchestrator. Coding agents never merge their own branches.

**When to use worktrees:**

Coding agents **must** use an isolated worktree when:
- The sprint modifies files that other agents or the orchestrator may be reading concurrently.
- Multiple sprints or defect fixes are in flight at the same time.

Coding agents **may** work directly on the sprint branch (no worktree) when:
- They are the only agent active on the repo.
- The orchestrator explicitly instructs direct-branch work.

**Worktree lifecycle:**
1. Create: `git worktree add ../sprint-X.Y sprint/X.Y`
2. Work and commit in the worktree.
3. Push the sprint branch.
4. The orchestrator merges and removes the worktree: `git worktree remove ../sprint-X.Y`

### What Requires User Approval

- Sprint specs (before implementation begins)
- New top-level folders or spec changes
- Any device-affecting changes (boot flow, power management)
- Architectural decisions not covered by existing specs
- Pushing to any branch other than the designated development branch

### When Coding Agents Must Stop and Escalate

Stop work and escalate to the orchestrator (or user) immediately when:

1. **Spec ambiguity requiring an architectural decision.** If the spec can be read two ways and each leads to a different design, do not guess — escalate.
2. **Missing file or dependency.** A file, library, or upstream component referenced by the spec does not exist in the repo and cannot be stubbed.
3. **Out-of-table file creation.** Implementation would require creating or modifying files not listed in the sprint's "Files to Create or Modify" table.
4. **Hardware-dependent test.** A required test cannot be written or executed without physical device access. Log it as a manual validation item and escalate.
5. **Failing unrelated tests.** Pre-existing tests that were passing before the sprint now fail due to the changes. Do not suppress — escalate.

When escalating, the agent must state: *what* it was doing, *which* criterion or file triggered the stop, and *what decision* it needs.

### What Agents May Do Autonomously

- Implement code within an approved sprint spec
- Write and run tests
- Fix defects found by QA within the sprint scope
- Create commits on the development branch
- Refactor within module boundaries if required by the sprint

### Agent Handoff Artifacts

When a coding agent finishes implementation (before QA begins), it must create a sprint summary:

**File:** `docs/sprints/sprint-X.Y-summary.md`

**Required sections:**

```markdown
# Sprint X.Y — Implementation Summary

## Files Created
| Path | Purpose |
|------|---------|

## Files Modified
| Path | What Changed |
|------|--------------|

## Tests Written
| Test | Location | What It Validates |
|------|----------|-------------------|

## Deviations from Spec
| Deviation | Rationale |
|-----------|-----------|
(None if spec was followed exactly.)

## Open Items
- Anything the QA agent or orchestrator should be aware of
```

The QA agent reads this summary as its starting point. The orchestrator uses it to verify scope compliance before merge.

## Coding Standards

### Shell Scripts

- Use `#!/bin/sh` (POSIX sh) unless bash-specific features are required. The target device runs BusyBox ash.
- Always use `set -e` at the top of scripts.
- Quote all variable expansions: `"$var"`, not `$var`.
- Use `snake_case` for function and variable names.
- Prefer `printf` over `echo` for portability.
- Error handling: check return codes, provide meaningful error messages to stderr.
- Use `readonly` for constants.

### BusyBox Ash Compatibility

The TrimUI Brick runs BusyBox ash, not bash or full POSIX sh. Code that is technically POSIX-compliant may still fail on-device. Avoid these constructs:

| Construct | Problem | Use Instead |
|-----------|---------|-------------|
| `local var=$(cmd)` | `local` masks `$?` — cannot check exit status | `local var; var=$(cmd)` |
| `[[ ... ]]` | Not available in ash | `[ ... ]` with proper quoting |
| `${var//pattern/replace}` | Parameter substitution not supported | `printf '%s' "$var" \| sed 's/pattern/replace/g'` |
| `${var:offset:length}` | Substring extraction not supported | `printf '%s' "$var" \| cut -c offset-end` |
| Arrays (`arr=(a b c)`) | No array support in ash | Use positional params or newline-delimited strings |
| `echo -e` | Behavior varies; not portable | `printf 'text\n'` |
| `read -r -a` | `-a` (array) not supported | `read -r` into single variable, parse with `cut`/`awk` |
| `function name()` | `function` keyword not supported | `name() { ... }` |
| `here-strings` (`<<<`) | Not supported | `printf '%s' "$var" \| cmd` |
| Process substitution `<(cmd)` | Not supported | Use temp files or pipes |
| `trap ... ERR` | `ERR` pseudo-signal not supported | Check return codes explicitly |
| `set -o pipefail` | Not supported in ash | Check each pipeline stage or use temp files |
| `mktemp --tmpdir` | BusyBox mktemp uses different flags | `mktemp /tmp/prefix.XXXXXX` |

**Testing:** When feasible, validate shell scripts with `busybox ash -n script.sh` (syntax check) in addition to ShellCheck.

### JSON

- 2-space indentation.
- No trailing commas.
- All keys in `snake_case`.
- Include a `_schema_version` field in all data files that may evolve (e.g., `"_schema_version": "1.0"`).

### File Naming

- `snake_case` for all source files and scripts.
- `.sh` extension for shell scripts.
- `.json` extension for JSON data and config files.
- Directories in `kebab-case` only where already established by spec (e.g., `session-manager` package). Otherwise use `snake_case`.

### Commit Messages

Format:
```
<type>(<scope>): <short description>

<optional body>
```

Types: `feat`, `fix`, `test`, `docs`, `refactor`, `build`, `chore`
Scopes: `session`, `launcher`, `library`, `emulation`, `system`, `updater`, `common`, `tests`, `scripts`, `config`, `docs`

Examples:
- `feat(session): add atomic write helper for session persistence`
- `test(session): add registry CRUD unit tests`
- `docs(roadmap): detail Sprint 0.2 scope`

### Testing Requirements

- **Every code change must include tests.** No exceptions.
- Unit tests go in `tests/unit/<module>/`.
- Integration tests go in `tests/integration/`.
- Test fixtures go in `tests/fixtures/`.
- Tests must be runnable via `scripts/test.sh` (once it exists).
- Tests should be self-contained — create their own temp directories, clean up after themselves.
- Test names should describe the behavior being tested, not the implementation.

## Architecture Reference

### Shared Infrastructure (`src/common/`)

These are built in Phase 0 (Sprint 0.2) before any subsystem:

- **Game Identity Model** (`src/common/game_identity.sh`) — `game_id` format is `system:game_name` (e.g., `snes:super_metroid`). Provides system taxonomy, ROM path conventions, and hash generation.
- **Event Bus** (`src/common/event_bus.sh`) — File-based event log. Modules append JSON events to `runtime/events/`. Consumers tail/poll. Event schema: `{"_schema_version": "1.0", "timestamp": "...", "source": "...", "event_type": "...", "payload": {...}}`.
- **Atomic Write Helper** (`src/common/atomic_write.sh`) — Write to temp → fsync → rename into place.

### Core Subsystems (dependency order)

1. **Session Manager** (`src/session/`) — Resume stack, suspend/resume, session persistence
2. **Background Task Scheduler** (`src/tasks/`) — Coordinates all background work, owns power-event pipeline
3. **Cloud Sync Engine** (`src/sync/`) — Save backup, cross-device continuity
4. **Notification System** (`src/notifications/`) — Tiered alerts, guardian mode
5. **OTA Updater** (`src/updater/`) — Package-oriented in-place upgrades
6. **Library Manager** (`src/library/`) — ROM discovery, favorites, collections
7. **Emulation Layer** (`src/emulation/`) — Launch orchestration, core selection
8. **Launcher** (`src/launcher/`) — UI, navigation, game switcher (integration point for all subsystems)

### Architectural Decisions

**Power-event orchestration:** The Task Scheduler is the sole orchestrator of sleep/shutdown sequences. Session Manager, Cloud Sync, and Notification System register as participants with defined priority ordering. They do not independently listen for OS-level power events.

**Save state file ownership:** Session Manager references emulator save states in-place at their native paths (e.g., `/userdata/saves/snes/`). It does NOT copy saves into its own store. Cloud Sync and Session Manager always reference the same file.

**Inter-module events:** All inter-module communication uses the file-based event bus in `src/common/`. Modules emit events (e.g., `session_corrupted`, `sync_upload_failed`); the Notification System and Task Scheduler subscribe by tailing the event log.

**Background work coordination:** The Task Scheduler decides *when* background tasks run. Subsystems (Cloud Sync, OTA, Library) decide *what* needs doing and submit tasks to the scheduler. Cloud Sync's internal upload queue is a task submission queue, not an independent execution engine.

### Platform Decisions

- **Keep from NextUI:** Hardware integration, WiFi, PAK runtime, boxart/media, display controls
- **Wrap:** Emulator launch path, game switcher, Pak Store, performance controls
- **Rewrite (Ideal OS native):** Session Manager, Cloud Sync, Notifications, Task Scheduler, OTA orchestration
- **Do not use:** CrossMix platform scripts, `.system/` folder for Ideal OS extensions

### Data Formats

- All metadata, manifests, and configuration use JSON.
- `game_id` format: `system:game_name` (e.g., `snes:super_metroid`). Always includes the system prefix.
- Session IDs: `<system>-<game-hash>-<timestamp>` (e.g., `snes-a13fd98c-20260310T211455Z`)
- `_schema_version`: String type, always present in evolving data files (e.g., `"_schema_version": "1.0"`).
- Hash fields: Use `sha256` as the field name (e.g., `"sha256": "abc123..."`).
- Timestamp fields for "last changed": Use `updated_at` consistently across all modules.
- Atomic file writes: write to temp → fsync → rename into place.

## Session Startup Protocol

**Every agent must execute these steps at the start of every session.** This is not optional.

### Step 1 — Read CLAUDE.md

Read this file. You are doing this now. Confirms coding standards, escalation rules, and branch conventions are loaded.

### Step 2 — Verify environment

Ensure required tools are available. Install if missing:

```sh
# BusyBox ash — required for on-target shell compatibility testing
busybox ash -c 'echo ok' 2>/dev/null || apt-get install -y busybox-static

# ShellCheck — required for shell script linting
command -v shellcheck >/dev/null 2>&1 || apt-get install -y shellcheck
```

All shell scripts target BusyBox ash. Tests must pass under `busybox ash`, not just bash or dash.

### Step 3 — Read the roadmap

Read `docs/roadmap.md`. Identify the current phase and which sprint is active (look for `in-progress` or `approved` status).

### Step 4 — Read the active sprint spec

Read `docs/sprints/sprint-X.Y.md` for the sprint you are about to work on. Confirm it has an `Approved` date set. **Do not proceed if the spec is not approved.**

### Step 5 — Read referenced subsystem specs (sprint-specific only)

Read only the design documents listed in the sprint spec's "Reference Specs" section. Do not read all docs — read the sections cited by the sprint.

### Step 6 — Read the sprint summary (if resuming)

If a `docs/sprints/sprint-X.Y-summary.md` exists, read it to understand what was already implemented. This prevents duplicate work when resuming a session.

### What NOT to read

- Do not read all 10+ specification documents at session start.
- Do not read specs for future phases or unrelated subsystems.
- Do not read upstream notes unless the sprint explicitly requires it.

## Pre-Flight Check Protocol

**Every sprint must have a pre-flight check before implementation begins.** The agent performs this after reading the sprint spec and before writing any code.

### Purpose

Identify ambiguities, missing dependencies, and environmental issues early — before they become mid-sprint escalations.

### Pre-flight steps

1. **Inventory existing state.** List all files and directories in the repo. Identify what already exists vs what the sprint will create or modify.
2. **Verify the sprint's file table.** For every file in the "Files to Create or Modify" table, confirm the parent directory exists (or is being created in-sprint) and that no naming conflicts exist.
3. **Check for spec ambiguities.** Read the sprint scope and acceptance criteria. Flag any item that can be interpreted two ways, references an undefined term, or depends on a decision not yet made.
4. **Validate tool and dependency availability.** Confirm that required tools (`busybox ash`, `shellcheck`, etc.) are installed. If a sprint depends on outputs from a prior sprint, verify those outputs exist.
5. **Report findings.** Present a summary to the orchestrator (or user) with:
   - Confirmed ready items
   - Ambiguities requiring a decision
   - Missing dependencies or prerequisites
   - Recommended resolutions for each issue

### Gate

The agent **must not begin implementation** until all ambiguities are resolved — either by the agent's own recommendation being accepted or by explicit orchestrator/user decision.

If no ambiguities are found, the agent states "Pre-flight complete, no blockers" and proceeds.
