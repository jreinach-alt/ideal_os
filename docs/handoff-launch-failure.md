# Continuity PAK Launch Failure — Handoff Document

## What We're Building

Continuity is a save-sync daemon for the TrimUI Brick handheld (running NextUI firmware). It syncs .srm save files across devices via a private GitHub repo using git.

The deliverable right now is **Continuity.pak** — a Tool PAK that appears in NextUI's Tools menu. The PAK lives at `Tools/tg5040/Continuity.pak/` on the SD card.

## What Works

- The PAK shows up in the NextUI Tools menu (directory structure is correct)
- All core sync logic is complete (462 tests passing)
- The daemon, enrollment, and sync engine code exist and are tested
- The static aarch64 git binary cross-compiles and is included in the PAK
- The PAK is tracked in the repo at `build/Continuity.pak/`

## What's Broken

When the user taps "Continuity" in the Tools menu, they see a **black screen that immediately returns to the menu**. No visible feedback, no files created on the SD card.

## What We've Tried (All Failed)

1. **show2.elf daemon mode without --image** — show2.elf requires --image, exits with code 1 without it
2. **show2.elf daemon mode with --image** — Added --image, FIFO-based messaging. Still black screen.
3. **Debug log to /mnt/SDCARD/.continuity/** — User reports no .continuity folder exists (might be hidden or never created)
4. **Debug log to /mnt/SDCARD/continuity_debug.log** — User didn't report finding this file
5. **Matching PAK pattern with `cd $(dirname "$0")`** — Matched other PAKs' launch pattern. Still black screen.
6. **show2.elf simple mode** — Simplified to blocking show2 call. Still black screen.
7. **Debug log to ./launch_debug.log inside PAK dir** — Latest attempt, not yet tested by user

## The Fundamental Unknown

**We don't know if launch.sh is even executing.** Every version has included debug output (file writes, logs), and none have appeared on the SD card. This means either:
- The script never runs at all
- The script runs but can't write files
- The debug files exist but the user can't see them (hidden files on macOS?)
- Something about how the script is invoked prevents it from working

## How NextUI Launches PAKs

From upstream source analysis (`upstream/nextui/src/workspace/all/nextui/nextui.c`):

1. `nextui.elf` writes a command to `/tmp/next`: `'/mnt/SDCARD/Tools/tg5040/Continuity.pak/launch.sh'`
2. The MinUI.pak launcher loop reads `/tmp/next` and runs: `eval $CMD`
3. This effectively does: `eval '/mnt/SDCARD/Tools/tg5040/Continuity.pak/launch.sh'`
4. The script must be executable (FAT32 mount options should handle this)
5. When the script exits, the launcher loop runs `nextui.elf` again (back to menu)

## How Other Tool PAKs Work

Every other Tool PAK has this exact pattern in launch.sh:
```sh
#!/bin/sh
cd $(dirname "$0")
./toolname.elf
```

They cd into the PAK directory and run a **compiled binary** that handles everything (display, logic). Our PAK is different — we don't have a compiled binary. We're a shell script that:
1. Does setup work (installs boot hook, runs enrollment)
2. Tries to use the system's `show2.elf` utility for display feedback

## Key System Details

- **Device:** TrimUI Brick with NextUI firmware
- **Shell:** BusyBox ash (not bash)
- **Filesystem:** FAT32 on SD card (no Unix permissions, 2-second mtime granularity)
- **No SSH access** — fresh NextUI install, no connectivity. Debugging is SD-card-only.
- **show2.elf location:** `/mnt/SDCARD/.system/tg5040/bin/show2.elf`
- **show2.elf requires:** `--mode` and `--image` parameters (exits with error without --image)
- **Logo image:** `/mnt/SDCARD/.system/res/logo.png`

## Current launch.sh (latest version)

Located at: `src/platforms/nextui/launch.sh` and `build/Continuity.pak/launch.sh`

```sh
#!/bin/sh
cd $(dirname "$0")
date >> ./launch_debug.log
exec 2>>./launch_debug.log
set -x
# ... setup work, then show2.elf --mode=simple for display
```

## PAK Directory Structure

```
Continuity.pak/
├── bin/git                    ← Static aarch64 binary (5MB)
├── config/
│   ├── platform_maps/nextui.json
│   └── system_taxonomy.json
├── launch.sh                  ← THE PROBLEM FILE
├── version.txt
└── scripts/
    ├── continuity_daemon.sh
    ├── enroll_sd_card.sh
    ├── pal_nextui.sh
    ├── update.sh
    └── core/ (11 modules)
```

## Hypotheses to Investigate

1. **Line endings (CRLF vs LF):** If launch.sh has Windows line endings, the shebang becomes `#!/bin/sh\r` which fails silently on the device. Check git's autocrlf settings and the actual file bytes.

2. **File not actually executable:** FAT32 doesn't store permissions. NextUI's SD card mount options need to make .sh files executable. Verify how the SD card is mounted (`/proc/mounts` or similar).

3. **eval behavior:** The MinUI launcher does `eval $CMD` where CMD is the single-quoted path. If there's something wrong with quoting or the path, eval might fail silently.

4. **PAK naming:** Verify that `Continuity.pak` is the exact directory name (case-sensitive, no extra characters, no trailing spaces).

5. **Script sourcing vs execution:** The `eval` might be sourcing the script in the current shell context rather than executing it as a subprocess. In that case, `set -e` in the parent shell could kill execution on any error in our script.

6. **Empty/corrupt file:** The launch.sh in the PAK might be empty or corrupted during copy.

7. **Missing newline at end of file:** Some shells have issues with scripts that don't end with a newline.

## Recommended Next Steps

1. **Absolute minimal test:** Replace launch.sh with the smallest possible script:
   ```sh
   #!/bin/sh
   echo test > /mnt/SDCARD/CONTINUITY_WAS_HERE.txt
   sleep 3
   ```
   If `CONTINUITY_WAS_HERE.txt` appears, the script runs. If not, it's a PAK execution issue.

2. **Check line endings:** Run `file launch.sh` or `xxd launch.sh | head` on the file that's actually on the SD card (if possible from the computer).

3. **Check what the user copies:** Clarify whether the user is copying from the git checkout or downloading from GitHub. Git might transform line endings.

4. **Research other shell-based PAKs:** Are there ANY NextUI Tool PAKs that are pure shell scripts without a compiled binary? If so, study their structure.

## Branch

All work is on branch `claude/review-continuity-docs-uXVPt` in repo `jreinach-alt/ideal_os`.

## Key File Locations

- Source launch.sh: `src/platforms/nextui/launch.sh`
- PAK copy: `build/Continuity.pak/launch.sh`
- Daemon: `src/platforms/nextui/continuity_daemon.sh`
- PAL: `src/platforms/nextui/pal_nextui.sh`
- show2 docs: `upstream/nextui/src/workspace/all/show2/README.md`
- show2 source: `upstream/nextui/src/workspace/all/show2/show2.cpp`
- NextUI launcher: `upstream/nextui/src/workspace/all/nextui/nextui.c`
- MinUI boot loop: `upstream/nextui/src/skeleton/SYSTEM/tg5050/paks/MinUI.pak/launch.sh`
- Boot flow analysis: `upstream/nextui/notes/boot-flow-analysis.md`
