# Ideal OS – Claude Code Operating Manual

## Project Overview

Ideal OS is a curated appliance-style operating system for the TrimUI Brick retro gaming handheld, built on top of NextUI. The device should feel like a console, not a Linux project.

Target hardware: TrimUI Brick (ARM Linux)
Versioning: Stardate format `YYMM.R` (e.g., Stardate 2601.1)

## Repository Structure Contract

The canonical layout is defined in `docs/ideal_os_repo_structure_spec.md`. That document is the binding authority on where files go.

### Strict Rules

1. **No new top-level folders** without updating the repo structure spec first.
2. **No source code** in `upstream/`, `assets/`, or `release/`.
3. **No generated files** in `src/` or `config/`.
4. **No runtime data** scattered in docs — schemas go under `runtime/`.
5. **Module-first placement** — if code belongs to launcher, session, library, emulation, system, updater, or common, place it in that `src/` module.

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

### What Requires User Approval

- Sprint specs (before implementation begins)
- New top-level folders or spec changes
- Any device-affecting changes (boot flow, power management)
- Architectural decisions not covered by existing specs
- Pushing to any branch other than the designated development branch

### What Agents May Do Autonomously

- Implement code within an approved sprint spec
- Write and run tests
- Fix defects found by QA within the sprint scope
- Create commits on the development branch
- Refactor within module boundaries if required by the sprint

## Coding Standards

### Shell Scripts

- Use `#!/bin/sh` (POSIX sh) unless bash-specific features are required. The target device runs BusyBox ash.
- Always use `set -e` at the top of scripts.
- Quote all variable expansions: `"$var"`, not `$var`.
- Use `snake_case` for function and variable names.
- Prefer `printf` over `echo` for portability.
- Error handling: check return codes, provide meaningful error messages to stderr.
- Use `readonly` for constants.

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

### Core Subsystems (dependency order)

1. **Session Manager** (`src/session/`) — Resume stack, suspend/resume, session persistence
2. **Background Task Scheduler** (`src/tasks/`) — Coordinates all background work
3. **Cloud Sync Engine** (`src/sync/`) — Save backup, cross-device continuity
4. **Notification System** (`src/notifications/`) — Tiered alerts, guardian mode
5. **OTA Updater** (`src/updater/`) — Package-oriented in-place upgrades
6. **Launcher** (`src/launcher/`) — UI, navigation, game switcher
7. **Library Manager** (`src/library/`) — ROM discovery, favorites, collections
8. **Emulation Layer** (`src/emulation/`) — Launch orchestration, core selection

### Platform Decisions

- **Keep from NextUI:** Hardware integration, WiFi, PAK runtime, boxart/media, display controls
- **Wrap:** Emulator launch path, game switcher, Pak Store, performance controls
- **Rewrite (Ideal OS native):** Session Manager, Cloud Sync, Notifications, Task Scheduler, OTA orchestration
- **Do not use:** CrossMix platform scripts, `.system/` folder for Ideal OS extensions

### Data Formats

- All metadata, manifests, and configuration use JSON.
- Session IDs: `<system>-<game-hash>-<timestamp>` (e.g., `snes-a13fd98c-20260310T211455Z`)
- Atomic file writes: write to temp → fsync → rename into place.

## Context Management

When starting a new session or sprint, read these files for context:

1. This file (`CLAUDE.md`)
2. `docs/roadmap.md` — Current phase and sprint status
3. The active sprint spec in `docs/sprints/`
4. Relevant subsystem specs in `docs/`

Do not re-read all 10 specification documents every session. Read only what is relevant to the current sprint.
