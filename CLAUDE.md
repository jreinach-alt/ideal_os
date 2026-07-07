# Continuity – Claude Code Operating Manual

## Project Overview

Continuity is a cross-platform SRAM save sync tool for retro gaming handhelds and emulation frontends. It uses git as its transport and versioning layer, syncing `.srm` (SRAM) save files across devices through the user's own private GitHub repository.

**Design philosophy:** The user owns their data. No cloud accounts controlled by us. No OAuth tokens we hold. The user's repo, the user's token, the user's saves.

**Target platforms:**
- TrimUI Brick (NextUI) — primary, BusyBox ash
- Anbernic devices (Onion OS) — BusyBox ash
- Steam Deck (RetroDeck) — full Linux
- Android (RetroArch) — Java/Kotlin

## Repository Structure

```
src/
  core/           — Shared sync engine logic (shell, portable)
  platforms/
    nextui/       — TrimUI Brick platform client + PAK
    onion/        — Onion OS platform client
    retrodeck/    — Steam Deck / RetroDeck client
    android/      — Android RetroArch client
  enrollment/     — Device setup and credential import
config/
  system_taxonomy.json      — Canonical system names and aliases
  platform_maps/            — Per-platform path mappings
    nextui.json
    onion.json
    retrodeck.json
    retroarch_android.json
docs/
  design/         — Architecture and design specs
  platform/       — Per-platform integration notes
  sprints/        — Sprint specs and summaries
  archive/        — Archived Ideal OS work (historical reference)
tests/
  unit/           — Unit tests by module
  integration/    — Cross-module integration tests
  fixtures/       — Test data
scripts/          — Build, test, and automation scripts
tools/            — Developer utilities (not shipped)
upstream/         — Upstream references (NextUI source, platform docs)
```

### Strict Rules

1. **No new top-level folders** without updating this document first.
2. **Platform-specific code** goes under `src/platforms/<platform>/`, never in `src/core/`.
3. **Shared logic** goes in `src/core/`. If two platforms need the same function, it belongs in core.
4. **Config is data, not code.** `config/` contains JSON mappings. No executable logic.
5. **No generated files** in `src/` or `config/`.

## Architecture Summary

### How It Works

```
┌─────────────┐     ┌──────────┐     ┌─────────────────┐
│ Save file    │     │ Continuity│     │ User's private   │
│ changes on   │────►│ daemon    │────►│ GitHub repo      │
│ device       │     │          │◄────│                  │
└─────────────┘     └──────────┘     └─────────────────┘
                    poll / detect       git push / pull
```

1. **Change detection:** Daemon polls save directories for modified `.srm` files (via `find -newer` on constrained devices, `inotifywait` on full Linux)
2. **Stage and commit:** Changed saves are staged and committed to a local git clone
3. **Push:** If WiFi is available, push to the user's private GitHub repo
4. **Pull on boot:** On device startup, pull latest saves from the repo
5. **Conflict preservation:** If two devices modify the same save, both versions are kept — never silently overwrite

### What We Sync

**SRAM saves only (`.srm` files).** Not save states, not screenshots, not configuration. SRAM saves are:
- Tiny (8 KB – 128 KB each)
- Portable across emulator cores (same SRAM format regardless of core)
- The user's actual progress (not a snapshot of emulator memory)

### What We Don't Do

- No OAuth to cloud providers (OneDrive, Google Drive, Dropbox)
- No token storage or management for third-party services
- No server-side infrastructure we operate (the user's GitHub repo is the "server")
- No save state sync (too large, core-specific, not portable)

### Security Model

- **User's repo, user's token.** We never see or store credentials.
- **Fine-grained PAT** scoped to a single repo via GitHub App installation
- **Token on device** is a GitHub PAT with minimal scope (one repo, contents read/write)
- **Worst case if device is stolen:** Attacker can read/write save files in one private repo. That's it.
- **Revocation:** User uninstalls the GitHub App or deletes the PAT. Instant.

### System Taxonomy

Canonical system names are defined in `config/system_taxonomy.json`. This file is the single source of truth for mapping between platform-specific directory names and repo paths.

The repo structure for saves:
```
user-saves-repo/
├── gb/
│   └── links_awakening.srm
├── gba/
│   └── minish_cap.srm
├── snes/
│   └── super_metroid.srm
└── .continuity/
    ├── config.json
    └── devices/
        └── my-brick.json
```

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
- Architectural decisions not covered by existing specs
- Pushing to any branch other than the designated development branch

### When Coding Agents Must Stop and Escalate

1. **Spec ambiguity requiring an architectural decision.**
2. **Missing file or dependency** referenced by the spec.
3. **Out-of-table file creation** — implementation requires files not listed in the sprint spec.
4. **Hardware-dependent test** — cannot be tested without physical device access.
5. **Failing unrelated tests** — pre-existing tests broke.

### Agent Handoff Artifacts

When a coding agent finishes implementation, it must create:

**File:** `docs/sprints/sprint-X.Y-summary.md`

Required sections: Files Created, Files Modified, Tests Written, Deviations from Spec, Open Items.

## Coding Standards

### Shell Scripts

- Use `#!/bin/sh` (POSIX sh). Primary targets run BusyBox ash.
- Always use `set -e` at the top of scripts.
- Quote all variable expansions: `"$var"`, not `$var`.
- Use `snake_case` for function and variable names.
- Prefer `printf` over `echo` for portability.
- Error handling: check return codes, provide meaningful error messages to stderr.
- Use `readonly` for constants.

### BusyBox Ash Compatibility

The TrimUI Brick and Onion OS devices run BusyBox ash. Avoid:

| Construct | Use Instead |
|-----------|-------------|
| `local var=$(cmd)` | `local var; var=$(cmd)` |
| `[[ ... ]]` | `[ ... ]` with proper quoting |
| `${var//pat/rep}` | `printf '%s' "$var" \| sed 's/pat/rep/g'` |
| `${var:offset:len}` | `printf '%s' "$var" \| cut -c offset-end` |
| Arrays (`arr=(a b)`) | Positional params or newline-delimited strings |
| `echo -e` | `printf 'text\n'` |
| `function name()` | `name() { ... }` |
| `<<<` here-strings | `printf '%s' "$var" \| cmd` |
| Process substitution `<()` | Temp files or pipes |
| `trap ... ERR` | Check return codes explicitly |
| `set -o pipefail` | Check each pipeline stage or use temp files |

**Testing:** Validate shell scripts with `busybox ash -n script.sh` and ShellCheck.

### Platform-Specific Code

Each platform client in `src/platforms/<name>/` can use platform-native constructs:
- **nextui, onion:** Must be BusyBox ash compatible
- **retrodeck:** May use bash, systemd, inotifywait
- **android:** Java/Kotlin, standard Android APIs

`src/core/` must be BusyBox ash compatible — it's the lowest common denominator for shell platforms.

### JSON

- 2-space indentation, no trailing commas, all keys in `snake_case`.
- Include `_schema_version` in evolving data files.

### File Naming

- `snake_case` for all source files and scripts
- `.sh` extension for shell scripts, `.json` for JSON

### Commit Messages

Format: `<type>(<scope>): <short description>`

Types: `feat`, `fix`, `test`, `docs`, `refactor`, `build`, `chore`
Scopes: `core`, `nextui`, `onion`, `retrodeck`, `android`, `enrollment`, `config`, `tests`, `scripts`, `docs`

### Testing Requirements

- **Every code change must include tests.**
- Unit tests: `tests/unit/<module>/`
- Integration tests: `tests/integration/`
- Fixtures: `tests/fixtures/`
- Tests must run under `busybox ash` for core and constrained-platform code.
- Tests must be self-contained — create temp dirs, clean up after.

## NextUI Build, Validation & Delivery Protocol

Hardware-validated on the TrimUI Brick 2026-07-07. Details and the full
trap list: `docs/platform/nextui-field-notes.md` — **read it before any
NextUI platform work.**

1. **Build:** `scripts/build_git.sh` (cross-compiles git + https helpers,
   once per toolchain change) → `scripts/build_pak.sh` (assembles
   `build/Continuity.pak` with version stamp, OTA channel, checksums).
2. **Validate before shipping any binary:** run the SHIPPED artifact under
   `qemu-aarch64-static` against live GitHub **with the host git hidden**
   (`mv /usr/bin/git` during the test) and every ARM→ARM exec edge
   shimmed. Never use binfmt_misc in the build container.
3. **Deliver as a versioned zip** (`Continuity.pak-<version>.zip`) built
   from the verified tree. Never instruct anyone to copy from a git
   working tree (line-ending smudge history; see field notes).
4. **After first enrollment, prefer OTA** (`scripts/update.sh`, tap-driven
   on-device): push to the channel branch, the device pulls it. Card
   swaps are for binaries and a broken launch/update bootstrap only.
5. **Observability is a requirement:** every failure must name itself
   on-screen with the build stamp; the preflight report goes to
   `CONTINUITY_DIAGNOSTIC.txt` at the SD root. Never gate the breadcrumb
   or diagnostics behind env vars nothing on-device sets.

## Model Regimen

Default development model: **Opus**, following the sprint methodology
(spec → implement → QA → summary) with the protocols in this file.
Escalate to **Fable** (sparingly) when a problem matches these classes:

- Cross-compilation / toolchain bring-up (new binaries, new platforms)
- Binary/system internals (git transport plumbing, exec semantics,
  kernel-adjacent debugging, emulation)
- A device failure that survives TWO Opus fix attempts with the
  diagnostic file in hand
- Architecture decisions that change the PAL contract or security model

Before ending any session, update the active sprint summary with defects
found/fixed and open items — the next session's context depends on it.

## Session Startup Protocol

### Step 1 — Read CLAUDE.md
Read this file.

### Step 2 — Verify environment
```sh
busybox ash -c 'echo ok' 2>/dev/null || apt-get install -y busybox-static
command -v shellcheck >/dev/null 2>&1 || apt-get install -y shellcheck
command -v git >/dev/null 2>&1 || apt-get install -y git
```

### Step 3 — Read the roadmap
Read `docs/roadmap.md`. Identify the active sprint.

### Step 4 — Read the active sprint spec
Read the sprint `.md` for the sprint you're working on. Confirm it's approved.

### Step 5 — Read referenced design docs (sprint-specific only)
Read only docs listed in the sprint's "Reference Specs" section.

### Step 6 — Read the sprint summary (if resuming)
If a summary exists, read it to avoid duplicate work.

## Pre-Flight Check Protocol

Before writing code for any sprint:

1. **Inventory existing state.** What exists vs what the sprint creates.
2. **Verify the sprint's file table.** Parent dirs exist, no naming conflicts.
3. **Check for spec ambiguities.** Flag anything that can be read two ways.
4. **Validate tools.** Required tools installed, prior sprint outputs exist.
5. **Report findings.** Confirm ready or list blockers.

Do not begin implementation until all blockers are resolved.
