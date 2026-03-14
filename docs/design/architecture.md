# Continuity — Architecture Spec

**Status:** Draft
**Date:** 2026-03-12
**Last updated:** 2026-03-14 (Sprint 0.6 complete)

## Overview

Continuity is a cross-platform SRAM save sync tool for retro gaming devices. It uses git as its transport and versioning layer, syncing `.srm` save files through the user's own private GitHub repository.

### Design Principles

1. **User owns their data.** No accounts we control. No tokens we hold. The user's GitHub repo is the source of truth.
2. **Git is the protocol.** Versioning, conflict detection, and history come free from git. We don't reinvent them.
3. **SRAM only.** Small, portable, core-agnostic. Not save states.
4. **Platform-native clients, shared core logic.** The sync engine is portable shell. Platform integration is per-device.
5. **Never silently overwrite.** If two devices modify the same save, keep both. Let the user decide.

---

## System Architecture

### Component Overview

```
┌──────────────────────────────────────────────────┐
│                  User's Device                    │
│                                                   │
│  ┌─────────────┐   ┌──────────────────────────┐  │
│  │ Emulator     │   │ Continuity Daemon         │  │
│  │ writes .srm  │──►│                          │  │
│  └─────────────┘   │  ┌────────────────────┐  │  │
│                     │  │ Change Detector     │  │  │
│                     │  │ (poll or inotify)   │  │  │
│                     │  └────────┬───────────┘  │  │
│                     │           ▼              │  │
│                     │  ┌────────────────────┐  │  │
│                     │  │ Sync Engine        │  │  │
│                     │  │ (git add/commit/   │  │  │
│                     │  │  push/pull)        │  │  │
│                     │  └────────┬───────────┘  │  │
│                     │           ▼              │  │
│                     │  ┌────────────────────┐  │  │
│                     │  │ Conflict Handler   │  │  │
│                     │  │ (preserve both)    │  │  │
│                     │  └────────────────────┘  │  │
│                     └──────────────────────────┘  │
└──────────────────────────┬───────────────────────┘
                           │ git push / pull
                           ▼
                ┌─────────────────────┐
                │ GitHub Private Repo  │
                │ (user-owned)         │
                │                     │
                │  gb/                │
                │  gba/               │
                │  snes/              │
                │  .continuity/       │
                └─────────────────────┘
```

### Core Components

#### 1. Change Detector (`src/core/change_detector.sh`)

Detects when `.srm` files are written or modified. Provides three functions:

- **`cd_detect_changes(repo_dir)`** — Returns repo-relative paths of `.srm` files with uncommitted changes (new, modified, or deleted). Uses `git status --porcelain -uall`, filtered to `\.srm$`. Returns 0 always; empty output means no changes.
- **`cd_list_repo_saves(repo_dir)`** — Lists all `.srm` files currently tracked in the repo (excludes `.git/` and `.continuity/`). Used by cold start to enumerate existing saves.
- **`cd_list_device_saves()`** — Lists all `.srm` files on the device by iterating `pm_list_watched_dirs()`. Used by stale boot recovery to enumerate saves that may need syncing.

All three functions output one repo-relative path per line and always return 0.

**Runtime change detection strategies** (used by the daemon poll loop, not by `cd_detect_changes`):

- **Constrained devices (BusyBox ash):** `find -newer` against the sentinel file
- **Full Linux (RetroDeck):** `inotifywait` event-driven
- **Android:** `FileObserver` API (Java)

Default poll interval: 30 seconds (configurable).

#### 2. Path Mapper (`src/core/path_mapper.sh`)

Translates between platform-specific save paths and canonical repo paths.

Uses platform map JSON files from `config/platform_maps/`.

Example: On NextUI, `/mnt/SDCARD/Saves/SFC/super_metroid.srm` maps to repo path `snes/super_metroid.srm`.

The mapper:
1. Reads the platform map JSON for the current device
2. Reverses the `system_paths` mapping (local dir name → canonical name)
3. Constructs the repo-relative path: `<canonical>/<filename>`

#### 3. Sync Engine (`src/core/sync_engine.sh`)

The git operations layer. Responsibilities:

- **Pull on boot:** `git pull --ff-only origin main` (fast-forward only; if diverged, trigger conflict handler)
- **Stage changes:** `git add <changed files>` using repo-relative paths from path mapper
- **Commit:** `git commit -m "<system>/<filename> updated"` with timestamp
- **Push:** `git push origin main` (if WiFi available; queue locally if not)
- **Retry with backoff:** If push fails due to network, retry with exponential backoff (2s, 4s, 8s, 16s)

Commit messages are automatic and descriptive:
```
snes/super_metroid.srm updated

device: my-brick
timestamp: 2026-03-12T14:30:00Z
```

#### 4. Cold Start (`src/core/cold_start.sh`)

Handles first-time sync when a device has never synced before (no sentinel file exists). Provides four functions:

- **`cs_is_cold_start(repo_dir)`** — Returns 0 if `$repo_dir/.continuity/sentinel` does not exist (cold start needed), 1 if it does (not a cold start).
- **`cs_store_commit(repo_dir, commit_hash)`** — Writes the 40-char SHA-1 to `$repo_dir/.continuity/last_known_commit`. Used after every successful sync to track the baseline for future diffs.
- **`cs_read_commit(repo_dir)`** — Reads the stored commit hash, stripping whitespace. Returns empty string if no file exists.
- **`cs_create_sentinel(repo_dir)`** — Creates `$repo_dir/.continuity/sentinel` with an ISO-8601 timestamp. The sentinel's mtime is used by the runtime poll (`find -newer`) as the baseline for detecting changes.

**`cs_run` flow:**
1. If repo has existing saves and device also has saves for the same game, a conflict exists — preserve both (local copy renamed to `<path>.<device_name>.local`)
2. Copy all repo saves to device (via path mapper)
3. Copy all device-only saves to repo (via path mapper)
4. If online: commit, push, store commit hash, create sentinel
5. If offline: commit locally, defer push (no sentinel or commit hash stored — cold start will re-run on next boot)

Conflict notification uses the optional PAL hook `pal_on_conflict()` if the platform defines it.

#### 5. Boot Pull (`src/core/boot_pull.sh`)

Handles normal boot when a sentinel exists and the device had a clean prior session. Provides two functions:

- **`bp_run(repo_dir)`** — Pulls latest from remote, diffs `HEAD` against `last_known_commit` to identify changed saves, copies only changed remote saves to the device, updates `last_known_commit`. Returns 0 on success, 1 on error.
- **`bp_has_remote_changes(repo_dir)`** — Checks whether remote HEAD differs from stored `last_known_commit`. Returns 0 if changes exist, 1 if up to date.

Boot pull is a read-from-remote operation only — it does not scan for local changes. That's the runtime poll's job.

#### 6. Runtime Poll (`src/core/runtime_poll.sh`)

Implements one complete poll cycle for detecting and syncing device save changes during active play. Designed to be called repeatedly by a daemon loop (Sprint 1.1). Has no internal state between calls — all state is on the filesystem (sentinel mtime, repo working tree).

Provides four functions:

- **`rp_find_candidates(repo_dir)`** — Uses `find -newer` against the sentinel file to enumerate `.srm` files under `$CONTINUITY_SAVES_ROOT` with newer mtime. Returns absolute device paths.
- **`rp_confirm_changes(repo_dir, candidates)`** — Filters candidates via `cmp -s` against the repo working tree copy. Only files that actually differ byte-for-byte are confirmed. This eliminates FAT32 false positives (files whose mtime changed but content is identical).
- **`rp_update_sentinel(repo_dir)`** — `touch`es the sentinel to advance its mtime, establishing the baseline for the next `find -newer` scan.
- **`rp_run(repo_dir)`** — Orchestrates one complete cycle: find candidates → confirm changes → copy to repo → stage → commit → push (if online) → update `last_known_commit` → update sentinel. Returns 0 on success or nothing-to-do, 1 on error.

**Two-stage detection** (`find -newer` + `cmp -s`) is intentional: `find -newer` is fast but imprecise on FAT32 (2-second mtime granularity can produce false positives). `cmp -s` is precise but slower. The two-stage approach gives us the speed of mtime scanning with the correctness of byte comparison.

**Sentinel update rules:** The sentinel is updated after any scan that did work (even if all candidates were false positives), but NOT when no candidates were found (step 2 early return). This prevents the sentinel from advancing past changes that arrived at the mtime boundary.

#### 7. Conflict Handler *(Sprint 0.8 — not yet implemented)*

`src/core/conflict_handler.sh` will handle runtime merge conflicts (when `git pull` detects diverged `.srm` files). Planned behavior:

When `git pull` detects a merge conflict on an `.srm` file:

1. **Keep both versions:**
   - `snes/zelda_lttp.srm` ← incoming (remote) version
   - `snes/zelda_lttp.srm.local` ← our (local) version
2. **Write conflict metadata:**
   ```json
   {
     "_schema_version": "1.0",
     "file": "snes/zelda_lttp.srm",
     "local_device": "my-brick",
     "local_timestamp": "2026-03-12T14:30:00Z",
     "remote_device": "my-deck",
     "remote_timestamp": "2026-03-12T13:00:00Z",
     "status": "unresolved"
   }
   ```
   Written to `snes/zelda_lttp.srm.conflict`
3. **Commit the conflict state** — both versions are preserved in the repo
4. **Signal the platform client** — the client decides how to notify the user (PAK UI, notification, etc.)

Resolution: User picks one (or the platform client auto-resolves by "keep newest" if configured). The `.local` and `.conflict` files are removed after resolution.

#### 8. Connectivity Checking

Network connectivity is checked via the PAL function `pal_is_online()`. Each platform implements this according to its capabilities:

- **Constrained devices (BusyBox):** `ping -c 1 -W 3 github.com` or `wget --spider`
- **Full Linux:** Standard network checks
- **Android:** `ConnectivityManager` API

If offline:
- Commits queue locally (git works offline natively)
- Push attempts resume when connectivity returns
- Pull happens on next boot or next connectivity event

#### 9. Enrollment (`src/core/enrollment.sh`)

Device setup and credential management. Two paths:

**SD Card Import (`src/platforms/nextui/enroll_sd_card.sh`):**
1. User places `setup.json` on SD card root from PC
2. On boot, daemon detects setup file at `$CONTINUITY_SD_ROOT/setup.json`
3. Imports repo URL, PAT, and device name
4. Clones repo
5. Deletes plaintext setup file
6. Writes credential to `$CONTINUITY_REPO_DIR/.continuity/credentials`

**Local Web Setup (Sprint 1.2 — deferred):**
1. Device starts BusyBox `httpd` on port 8080
2. Serves a simple HTML form (paste repo URL + PAT + device name)
3. User opens `http://<device-ip>:8080` on phone
4. Form submits credentials to device
5. Device clones repo, stops httpd

---

## Repository Structure (User's Save Repo)

```
my-saves/
├── gb/
│   └── links_awakening.srm
├── gba/
│   └── minish_cap.srm
├── gbc/
│   └── pokemon_crystal.srm
├── snes/
│   ├── super_metroid.srm
│   └── zelda_lttp.srm
├── genesis/
│   └── sonic2.srm
├── ps1/
│   └── ff7.srm
└── .continuity/
    ├── config.json
    ├── sentinel              ← created after first successful sync (mtime = poll baseline)
    ├── last_known_commit     ← 40-char SHA-1 of last synced commit (diff baseline)
    └── devices/
        ├── my-brick.json
        ├── my-rp5.json
        └── my-deck.json
```

### `.continuity/config.json`

```json
{
  "_schema_version": "1.0",
  "conflict_resolution": "prompt",
  "sync_enabled": true
}
```

### `.continuity/devices/<name>.json`

```json
{
  "_schema_version": "1.0",
  "device_name": "my-brick",
  "platform": "nextui",
  "enrolled_at": "2026-03-12T14:30:00Z",
  "last_sync": "2026-03-12T14:30:00Z",
  "last_push": "2026-03-12T14:30:05Z"
}
```

---

## Enrollment Flow

### GitHub App vs PAT

Continuity uses a **GitHub App** for enrollment UX combined with a **fine-grained PAT** for git transport.

**Why both:**
- GitHub App provides a trusted, familiar "Install" flow — user clicks "Install Continuity" on their repo
- The App surfaces clearly in repo settings with one-click uninstall
- The PAT (scoped to single repo, contents read/write only) is what the device actually uses for `git push`/`git pull`
- No server-side token refresh infrastructure needed

**Enrollment sequence:**

```
1. User creates private repo "my-saves" on GitHub (or clicks "Create" on idealos.dev/setup)
2. User installs "Continuity" GitHub App → selects only the my-saves repo
3. User generates a fine-grained PAT:
   - Resource: Only my-saves repo
   - Permission: Contents (read/write)
   - Expiry: 1 year
4. User transfers PAT to device (SD card file or local web form)
5. Device clones repo, first sync runs
```

### Per-Platform Enrollment

| Platform | Primary Method | Fallback |
|----------|---------------|----------|
| NextUI (Brick) | SD card file or local web form | — |
| Onion OS | SD card file or local web form | — |
| RetroDeck | CLI setup script | Manual git clone |
| Android | App UI (paste PAT) | — |

---

## Daemon Lifecycle

### Constrained Devices (NextUI, Onion OS)

The daemon runs as a background shell process, launched at boot.

**NextUI:** Launched via `auto.sh` hook in MinUI.pak boot sequence:
```sh
# In auto.sh (runs at boot, before launcher loop)
/mnt/SDCARD/.continuity/bin/continuity_daemon.sh &
```

**Lifecycle:**
```
Boot
  ├── auto.sh spawns continuity_daemon.sh &
  ├── Daemon: boot sync phase
  │     ├── No sentinel?        → Cold Start (cs_run)     [Sprint 0.4]
  │     ├── No clean_shutdown?  → Stale Boot (sb_run)     [Sprint 0.7]
  │     └── Normal boot         → Boot Pull (bp_run)      [Sprint 0.5]
  ├── Daemon: enter poll loop (find -newer sentinel, every 30s)  [Sprint 0.6]
  │     ├── On change: stage, commit
  │     ├── If WiFi: push, update last_known_commit
  │     └── If no WiFi: queue (commits are local)
  └── Daemon: on SIGTERM (shutdown) → final push attempt, write clean_shutdown marker
```

**PID tracking:** Daemon writes PID to `/tmp/continuity.pid`. Prevents duplicate instances.

### Full Linux (RetroDeck)

Runs as a systemd user service:
```ini
[Unit]
Description=Continuity Save Sync
After=network-online.target

[Service]
ExecStart=/path/to/continuity_daemon.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

Uses `inotifywait` instead of polling.

### Android

Runs as a foreground service with `FileObserver` for change detection.

---

## Conflict Resolution Strategy

### Principle: Never Lose Data

A conflict means two devices modified the same `.srm` file between syncs. Both versions represent real player progress. We keep both.

### Detection

Git detects conflicts natively during `git pull`. The conflict handler intercepts merge failures on `.srm` files.

### Preservation

1. Remote (incoming) version saved as the canonical path: `snes/zelda_lttp.srm`
2. Local version saved alongside: `snes/zelda_lttp.srm.local`
3. Metadata: `snes/zelda_lttp.srm.conflict` (JSON with device names, timestamps)
4. All three files committed and pushed

### Resolution

| Mode | Behavior |
|------|----------|
| `prompt` (default) | Platform client notifies user, offers choice |
| `keep_newest` | Auto-resolve by timestamp — most recent write wins |
| `keep_device` | Always prefer a specific device's saves *(deferred to post-1.0 — not implemented in Phase 0)* |

Resolution removes `.local` and `.conflict` files, commits the result.

---

## Security Considerations

### Threat Model

| Threat | Impact | Mitigation |
|--------|--------|-----------|
| SD card stolen | Attacker has PAT scoped to one repo of save files | Minimal blast radius — only saves exposed |
| Device sold without wiping | PAT persists on SD card | Document wipe procedure; PAT expires in 1 year |
| Malicious PAK reads filesystem | Could extract PAT | PAT scope limits damage to save repo only |
| GitHub App compromised | Our app key leaked | App can only access repos that installed it |

### Token Storage

On constrained devices, the PAT is stored in a config file on the SD card. This is inherently insecure (FAT32, no permissions). Mitigations:

1. **Minimal scope:** PAT grants contents read/write on one repo containing only `.srm` files
2. **Expiration:** 1-year expiry, daemon warns when approaching expiry
3. **Easy revocation:** Uninstall GitHub App or delete PAT from GitHub settings
4. **No sensitive data in repo:** Even full compromise yields only game save files

### What We Don't Do

- No OAuth to OneDrive, Google Drive, or any cloud provider
- No server-side token storage or refresh infrastructure
- No client secrets embedded in distributed code
- No broad-scope tokens (no access to user's email, profile, other repos)
