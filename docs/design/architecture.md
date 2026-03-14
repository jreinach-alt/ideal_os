# Continuity — Architecture Spec

**Status:** Draft
**Date:** 2026-03-12

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

Detects when `.srm` files are written or modified.

**Constrained devices (BusyBox ash):** Polling via `find -newer`
```sh
# Check for files modified since last check
find "$saves_dir" -name "*.srm" -newer "$marker_file"
touch "$marker_file"
```

**Full Linux (RetroDeck):** `inotifywait` event-driven
```sh
inotifywait -m -r -e close_write --include '\.srm$' "$saves_dir"
```

**Android:** `FileObserver` API (Java)

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

#### 4. Conflict Handler (`src/core/conflict_handler.sh`)

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

#### 5. Connectivity Checking

Network connectivity is checked via the PAL function `pal_is_online()`. Each platform implements this according to its capabilities:

- **Constrained devices (BusyBox):** `ping -c 1 -W 3 github.com` or `wget --spider`
- **Full Linux:** Standard network checks
- **Android:** `ConnectivityManager` API

If offline:
- Commits queue locally (git works offline natively)
- Push attempts resume when connectivity returns
- Pull happens on next boot or next connectivity event

#### 6. Enrollment (`src/core/enrollment.sh`)

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
  ├── Daemon: git pull (sync latest saves)
  ├── Daemon: enter poll loop (find -newer, every 30s)
  │     ├── On change: stage, commit
  │     ├── If WiFi: push
  │     └── If no WiFi: queue (commits are local)
  └── Daemon: on SIGTERM (shutdown) → final push attempt
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
