# Sprint 0.9 — On-Device Conflict Resolution UI

**Status:** Draft
**Date:** 2026-03-15
**Dependencies:** Sprint 0.8 (conflict handler — `ch_list_conflicts`, `ch_list_local_files`, `ch_resolve` available)

---

## Goal

Give users a way to resolve save conflicts directly on the handheld, using the device's own screen and buttons. When a conflict exists (two versions of the same `.srm` file from different devices), the user opens the Continuity resolver from the Tools menu, sees both versions with device names and timestamps, can swap either version into the active save slot to try it in-game, then come back and mark the winner as authoritative.

No phone. No second device. No IP address to hunt for. The user is already holding the device.

This sprint builds a minimal compiled C binary using NextUI's SDL2 infrastructure, following the same pattern as existing Tool PAKs (`settings.elf`, `battery.elf`, etc.). The UI is deliberately minimal — a scrollable list with d-pad navigation and A/B button actions. Sprint 1.2 (full Tool PAK) will add sync status, manual sync trigger, and device management around this conflict resolution core.

---

## Reference Specs

- `docs/design/pal.md` — PAL interface, `CONTINUITY_REPO_DIR`, `CONTINUITY_SAVES_ROOT`, `CONTINUITY_DEVICE_NAME`
- `docs/design/architecture.md` — Conflict Resolution Strategy section
- `src/core/conflict_handler.sh` — `ch_list_conflicts`, `ch_list_local_files`, `ch_resolve` (Sprint 0.8 output)
- `src/core/path_mapper.sh` — `pm_repo_to_local` (Sprint 0.2 output)
- `upstream/nextui/src/workspace/all/common/api.h` — NextUI GFX/PAD API surface
- `upstream/nextui/src/workspace/all/common/defines.h` — Constants, font sizes, button IDs
- `upstream/nextui/src/workspace/all/settings/menu.hpp` — NextUI menu framework (reference, not dependency)
- `upstream/nextui/src/workspace/tg5040/platform/platform.h` — TrimUI Brick platform constants

---

## Scope

### Architecture Overview

```
┌──────────────────────────────────────────┐
│ Continuity.pak/                           │
│   launch.sh          ← entry point        │
│   resolve.elf        ← compiled C binary  │
│   resolve.sh         ← shell helper       │
│   bin/git            ← bundled git        │
│   config/            ← platform maps etc  │
│   src/core/          ← bundled core shell │
└──────────────────────────────────────────┘
```

The conflict resolver is a compiled C program (`resolve.elf`) that handles display and input via SDL2. It delegates all conflict logic (listing, trying, resolving) to shell helper functions via `system()` or `popen()` calls. This keeps the binary thin — it's a UI shell around the existing conflict handler.

**Why C, not C++?** The NextUI settings app uses C++ with `<functional>`, `<vector>`, `<any>`, `<shared_mutex>` — heavy STL. Our binary is simpler (a scrollable list with actions) and doesn't need that machinery. C with the NextUI C API (`api.h`) keeps the binary small and the build simple. If linking against NextUI's shared libs requires C++ linkage, C++ is acceptable, but the implementation should stay procedural — no classes, no templates, no STL containers.

---

### Conflict Resolver Binary (`src/platforms/nextui/resolve.c`)

A single-file C program (~400–600 lines) that:

1. Scans the repo for `.conflict` files (reads the filesystem directly, no shell call needed)
2. Parses `.conflict` JSON to extract metadata (simple hand-rolled parser — the format is fixed and tiny)
3. Renders a scrollable list of conflicts
4. Handles d-pad/button input for navigation and actions
5. Delegates try/resolve operations to shell scripts via `system()`

**Data structures:**

```c
#define MAX_CONFLICTS 32
#define MAX_PATH_LEN 256
#define MAX_DEVICE_NAME 64

typedef struct {
    char file[MAX_PATH_LEN];           // canonical repo-relative .srm path
    char remote_device[MAX_DEVICE_NAME];
    char remote_timestamp[32];         // ISO-8601
    char local_device[MAX_DEVICE_NAME];
    char local_timestamp[32];          // ISO-8601
    char system_name[32];              // derived from path (e.g., "snes")
    char game_name[64];                // derived from path (e.g., "super_metroid")
    int active_version;                // 0 = remote, 1 = local
} ConflictEntry;

typedef struct {
    ConflictEntry entries[MAX_CONFLICTS];
    int count;
    int selected;                      // cursor position
} ConflictList;
```

**Program flow:**

```
main():
  1. Parse command-line args:
       --repo-dir <path>    (required: CONTINUITY_REPO_DIR)
       --saves-dir <path>   (required: CONTINUITY_SAVES_ROOT)
       --device-name <name> (required: CONTINUITY_DEVICE_NAME)
       --core-dir <path>    (required: path to src/core/)
       --pal-path <path>    (required: path to pal_nextui.sh)

  2. Scan repo for conflicts → populate ConflictList
       Walk repo_dir recursively, find *.conflict files
       For each: parse JSON, derive system/game from path
       If count == 0: show "No conflicts" message, exit after 2s

  3. Initialize SDL2 (GFX_init if linking NextUI, or direct SDL_Init)
       SDL_Init(SDL_INIT_VIDEO | SDL_INIT_JOYSTICK)
       Open window/surface at device resolution
       Load embedded font via SDL_ttf

  4. Enter main loop:
       while (running):
         PAD_poll()  — or SDL_PollEvent for joystick/button
         Handle input:
           UP/DOWN  → move cursor
           A        → open action submenu for selected conflict
           B        → exit (back to Tools menu)
         Render:
           Header: "Save Conflicts (N)"
           For each visible conflict:
             "[system] game_name"
             "  mine (device_name) — timestamp"
             "  theirs (remote_device) — timestamp"
             If active: "  ► testing: mine/theirs"
           Footer: "A: Actions  B: Exit"
         GFX_flip() / SDL_UpdateWindowSurface()

  5. Cleanup and exit
```

**Action submenu (shown when A is pressed on a conflict):**

```
┌──────────────────────────┐
│  Super Metroid            │
│                           │
│  ► Try Mine               │
│    Try Theirs             │
│    ──────                 │
│    Keep Mine              │
│    Keep Theirs            │
│    Keep Newest            │
│    ──────                 │
│    Cancel                 │
│                           │
│  A: Select  B: Back       │
└──────────────────────────┘
```

- **Try Mine / Try Theirs:** Copies the selected version to the device save path. Does NOT resolve the conflict. The user can exit the resolver, launch the game to test the save, then come back and resolve.
- **Keep Mine / Keep Theirs / Keep Newest:** Calls `ch_resolve` via `system()`, then rescans the conflict list. Shows a brief "Resolved!" confirmation.
- **Cancel:** Dismisses the submenu, returns to the conflict list.

---

### Shell Helper Script (`src/platforms/nextui/resolve.sh`)

The binary calls this script via `system()` to perform conflict operations. This keeps all git/PAL logic in shell where it belongs, and the binary stays a pure UI layer.

```sh
#!/bin/sh
# resolve.sh — shell helper for resolve.elf
# Usage:
#   resolve.sh try <repo_dir> <file> <version> <saves_root> <core_dir> <pal_path>
#   resolve.sh resolve <repo_dir> <file> <resolution> <saves_root> <core_dir> <pal_path>
```

**`resolve.sh try`:**
1. Source PAL and core modules (conflict_handler.sh, path_mapper.sh)
2. Determine device save path via `pm_repo_to_local "$file"`
3. If `version` is `"local"`:
   - Find the `.local` file in `$repo_dir/` matching `$file.*.local`
   - Copy it to the device save path
4. If `version` is `"remote"`:
   - Copy `$repo_dir/$file` to the device save path
5. Exit 0 on success, 1 on error

**`resolve.sh resolve`:**
1. Source PAL and core modules
2. Call `ch_resolve "$repo_dir" "$file" "$resolution"`
3. If successful, copy the resolved canonical file to the device save path
4. Exit with `ch_resolve`'s return code

The binary reads the exit code to determine success/failure and displays appropriate feedback.

---

### SDL2 Rendering Details

**Display strategy:** The resolver does NOT link against NextUI's `api.o` / `libminui`. It uses SDL2 directly (`SDL_Init`, `SDL_CreateWindow`, `SDL_GetWindowSurface`, `SDL_ttf`). Reasons:

1. NextUI's GFX API is tightly coupled to the launcher's lifecycle (it assumes it owns the display)
2. Tool PAKs like `battery.elf` and `clock.elf` each have their own SDL2 init — there's no shared library
3. Direct SDL2 is simpler to build and test on desktop Linux during development

**Font:** Use an embedded TTF font compiled into the binary as a C array (same pattern as `show2.elf` which embeds `RoundedMplus1c_Bold_reduced_ttf`). The font file can be copied from NextUI's assets or a permissively-licensed alternative.

**Screen layout at 1024x768 (TrimUI Brick):**

```
┌─────────────────────────────────────────┐  y=0
│                                         │
│   Save Conflicts (2)                    │  y=30  — header, FONT_LARGE (16pt scaled)
│                                         │
├─────────────────────────────────────────┤  y=80  — list starts
│                                         │
│   ► SNES · Super Metroid                │  row 0, selected (highlight pill)
│     mine (my-brick) · Mar 12, 2:30 PM   │
│     theirs (my-deck) · Mar 12, 1:00 PM  │
│     testing: mine                       │
│                                         │
│     GB · Links Awakening                │  row 1
│     mine (my-brick) · Mar 12, 3:00 PM   │
│     theirs (my-deck) · Mar 12, 2:00 PM  │
│                                         │
├─────────────────────────────────────────┤  y=700 — footer
│   Ⓐ Actions   Ⓑ Exit                  │
└─────────────────────────────────────────┘  y=768
```

**Colors (matching NextUI dark theme):**
- Background: black (`0x000000`)
- Text: light gray (`0xCCCCCC`)
- Selected row highlight: dark gray pill (`0x262626`)
- Header text: white (`0xFFFFFF`)
- "mine" label: slightly brighter to distinguish from "theirs"
- Footer hint text: mid-gray (`0x999999`)

**Scrolling:** If more conflicts than fit on screen (~5 rows at this layout density), the list scrolls. Cursor wraps at top/bottom.

**Input polling:** Use `SDL_PollEvent` directly to read joystick button events. Button mappings from `platform.h`:
- D-pad Up/Down: `JOY_AXIS` or button events for `BTN_UP` / `BTN_DOWN`
- A button: `JOY_A = 1` (confirm)
- B button: `JOY_B = 0` (cancel/back)

The input system reads from `/dev/input/event*` via SDL2's joystick subsystem. On desktop Linux (for testing), keyboard arrows + Enter/Escape are mapped as fallbacks.

---

### PAK Structure

The PAK is delivered at `/mnt/SDCARD/Tools/tg5040/Continuity.pak/`:

```
Continuity.pak/
├── launch.sh              ← invokes resolve.elf with correct paths
├── resolve.elf            ← compiled conflict resolver (ARM)
├── resolve.sh             ← shell helper for try/resolve operations
├── bin/
│   └── git                ← statically-linked git binary (from Sprint 0.3)
├── config/
│   └── platform_maps/
│       └── nextui.json    ← platform map (from Sprint 0.2)
└── src/
    └── core/              ← bundled core shell modules
        ├── conflict_handler.sh
        ├── sync_engine.sh
        ├── cold_start.sh
        └── path_mapper.sh
```

**`launch.sh`:**

```sh
#!/bin/sh
cd "$(dirname "$0")"

REPO_DIR="/mnt/SDCARD/Saves/.continuity_repo"
SAVES_ROOT="/mnt/SDCARD/Saves"
DEVICE_NAME=$(cat "$REPO_DIR/.continuity/device_name" 2>/dev/null || printf "unknown")

./resolve.elf \
    --repo-dir "$REPO_DIR" \
    --saves-dir "$SAVES_ROOT" \
    --device-name "$DEVICE_NAME" \
    --core-dir "$(pwd)/src/core" \
    --pal-path "$(pwd)/pal_nextui.sh"
```

**Note:** This sprint focuses on the resolver binary and shell helper. The full PAK packaging (bundling git, core modules, platform PAL) is Sprint 1.2's concern. For Sprint 0.9, the binary and shell helper are built and tested in the repo; the PAK structure above is the target layout, not something this sprint assembles.

---

### Build System

**Makefile:** `src/platforms/nextui/Makefile`

```makefile
# Cross-compilation for TrimUI Brick (ARM)
CROSS_COMPILE ?= arm-linux-gnueabihf-
CC = $(CROSS_COMPILE)gcc
CFLAGS = -Wall -Wextra -O2 $(shell sdl2-config --cflags)
LDFLAGS = $(shell sdl2-config --libs) -lSDL2_ttf

# Native build for desktop testing
.PHONY: native
native: CC = gcc
native: resolve.elf

resolve.elf: resolve.c embedded_font.h
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

# Generate embedded font header from TTF file
embedded_font.h: font.ttf
	xxd -i $< > $@
```

**Desktop testing:** `make native` builds for the host architecture using the system's SDL2. Developers can run `./resolve.elf --repo-dir /tmp/test-repo ...` on desktop Linux to test the UI with keyboard input before cross-compiling for ARM.

**CI:** The native build runs in CI. The ARM cross-build requires a cross-compilation toolchain (deferred to Sprint 1.2's packaging work). Sprint 0.9's CI validates that the C code compiles and the desktop binary works with the test fixtures.

---

## Integration with Sprint 1.2

Sprint 1.2 (NextUI Tool PAK) will wrap this resolver into a larger tool with:
- Status display (last sync, pending changes, linked devices)
- Manual sync trigger
- Conflict resolution (this sprint's binary, possibly integrated into a larger `continuity.elf`)
- Device unlinking

This sprint's `resolve.elf` may become a standalone binary invoked by Sprint 1.2's `launch.sh`, or its code may be folded into a larger `continuity.elf`. Either path works — the conflict resolution logic is self-contained.

---

## Out of Scope

| Item | Sprint |
|------|--------|
| Full Tool PAK packaging (bundling git, core modules, PAL) | 1.2 |
| Sync status display | 1.2 |
| Manual sync trigger | 1.2 |
| Device unlinking UI | 1.2 |
| ARM cross-compilation toolchain setup | 1.2 |
| Daemon auto-launch of resolver on conflict | 1.1 |
| show2.elf notification for conflicts (if daemon doesn't launch resolver) | 1.1 |
| RetroDeck conflict resolution UI | 2.2 |
| Android conflict resolution UI | 3.2 |
| Multi-device `.local` selection (pick which device's save in 3+ device conflict) | 1.2 |
| Save file preview / hex dump | post-1.0 |
| Animated transitions between screens | never |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/platforms/nextui/resolve.c` | Conflict resolver SDL2 binary — display, input, delegates to shell |
| `src/platforms/nextui/resolve.sh` | Shell helper: `try` and `resolve` commands, sources PAL + core modules |
| `src/platforms/nextui/Makefile` | Build system for native and cross-compiled `resolve.elf` |
| `src/platforms/nextui/embedded_font.h` | Auto-generated embedded font data (from TTF via `xxd`) |
| `tests/unit/platforms/nextui/test_resolve_shell.sh` | Unit tests for `resolve.sh` try/resolve commands |
| `tests/integration/test_resolve_flow.sh` | Integration test: set up conflicts, invoke resolver operations, verify results |

### Files Modified

| File | Change |
|------|--------|
| `docs/design/architecture.md` | Add Conflict Resolution UI section describing the on-device binary approach |

### Directories Created

| Directory | Purpose |
|-----------|---------|
| `tests/unit/platforms/` | Platform-specific unit tests (new directory tree) |
| `tests/unit/platforms/nextui/` | NextUI platform unit tests |

---

## Acceptance Criteria

### Conflict Scanning and Parsing

1. `resolve.elf` scans the repo directory and finds all `.conflict` files (excluding `.git/`).
2. For each `.conflict` file, parses `file`, `remote_device`, `remote_timestamp`, `local_device`, `local_timestamp` from the JSON.
3. Derives `system_name` and `game_name` from the `file` path (e.g., `snes/super_metroid.srm` → `snes`, `super_metroid`).
4. Handles repos with 0 conflicts gracefully (shows "No conflicts" message, exits after brief delay).
5. Handles repos with up to `MAX_CONFLICTS` (32) conflicts.

### Display

6. Renders a header showing the conflict count.
7. Renders each conflict as a multi-line row showing system, game, both device names, and both timestamps.
8. Highlights the currently selected row with a distinct background color.
9. Shows a footer with button hints ("A: Actions  B: Exit").
10. Scrolls the list when there are more conflicts than fit on screen.
11. When a version is being tested (after "Try"), the row shows which version is active.

### Input Handling

12. D-pad Up/Down moves the cursor through the conflict list.
13. A button opens the action submenu for the selected conflict.
14. B button exits the program (returns to NextUI Tools menu).
15. In the action submenu: D-pad Up/Down navigates options, A selects, B cancels back to list.
16. On desktop Linux (native build), keyboard arrow keys + Enter/Escape work as equivalents.

### Action Submenu

17. "Try Mine" copies the `.local` file to the device save path via `resolve.sh try`.
18. "Try Theirs" copies the canonical (remote) `.srm` to the device save path via `resolve.sh try`.
19. After a try operation, the conflict row updates to show which version is active.
20. "Keep Mine" calls `resolve.sh resolve` with `keep_local`, removes the conflict from the list on success.
21. "Keep Theirs" calls `resolve.sh resolve` with `keep_remote`, removes the conflict from the list on success.
22. "Keep Newest" calls `resolve.sh resolve` with `keep_newest`, removes the conflict from the list on success.
23. If `resolve.sh resolve` returns non-zero, the UI shows a brief error message and does not remove the conflict.
24. After all conflicts are resolved, shows "All conflicts resolved!" and exits after a brief delay.

### `resolve.sh try`

25. Sources PAL and core modules correctly.
26. Determines the device save path via `pm_repo_to_local`.
27. When `version=local`: finds the `.local` file and copies it to the device save path.
28. When `version=remote`: copies the canonical `.srm` from the repo to the device save path.
29. Does not modify the repo (no commits, no git operations).
30. Returns 0 on success, 1 on error.

### `resolve.sh resolve`

31. Sources PAL and core modules correctly.
32. Calls `ch_resolve` with the given resolution (`keep_local`, `keep_remote`, or `keep_newest`).
33. After successful resolution, copies the resolved canonical `.srm` to the device save path.
34. Returns `ch_resolve`'s exit code.

### Build

35. `make native` produces a working `resolve.elf` on desktop Linux (x86_64).
36. The native binary runs correctly with a test repo and keyboard input.
37. `resolve.c` compiles with `-Wall -Wextra` and no warnings.
38. The Makefile supports `CROSS_COMPILE` variable for ARM cross-compilation (structure only — actual cross-compile is Sprint 1.2).

### Shell Code Quality

39. `resolve.sh` passes `shellcheck` with no errors.
40. `resolve.sh` passes `busybox ash -n` syntax check.
41. No banned BusyBox ash constructs used.
42. All variable expansions are quoted.
43. All tests pass under `busybox ash`.

### C Code Quality

44. No compiler warnings with `-Wall -Wextra`.
45. No buffer overflows — all string operations use bounded copies (`snprintf`, `strncpy`).
46. All `system()` calls construct the command string safely (no user-controlled input injected without validation).
47. SDL2 resources are properly cleaned up on exit.
48. Program handles missing repo directory gracefully (error message, exit 1).

---

## Testing Strategy

### Unit Tests (`tests/unit/platforms/nextui/test_resolve_shell.sh`)

Tests for `resolve.sh` — the shell helper that the binary calls. Each test creates a fresh `TEST_TMPDIR`, sets up a repo with conflict artifacts, and verifies try/resolve behavior.

**`resolve.sh try` tests:**

- Set up a conflict for `snes/super_metroid.srm`. Call `resolve.sh try ... local`. Assert device save path contains the `.local` file's bytes.
- Call `resolve.sh try ... remote`. Assert device save path contains the canonical `.srm` bytes.
- Call `resolve.sh try` with a nonexistent file. Assert returns 1.
- Verify no git commits are made after a try operation.
- Swap to local, then swap to remote, then swap to local again. Assert each swap puts the correct bytes in place.

**`resolve.sh resolve` tests:**

- Set up a committed conflict state. Call `resolve.sh resolve ... keep_remote`. Assert returns 0. Assert canonical `.srm` has remote bytes. Assert `.local` and `.conflict` files are gone. Assert device save path has remote bytes.
- Same for `keep_local` — assert canonical now has local bytes.
- Same for `keep_newest` — assert resolution matches the newer timestamp.
- Call with invalid resolution string. Assert returns 1.
- Call with nonexistent conflict. Assert returns 1.

### Integration Test (`tests/integration/test_resolve_flow.sh`)

End-to-end test that simulates the full conflict lifecycle without the SDL2 UI (tests the data layer only). Uses the same two-device simulation pattern as Sprint 0.8's integration test.

**Setup:**
1. Create bare remote, two working clones (device-a, device-b).
2. Create diverged state, run `ch_handle_pull_conflict` to produce conflict artifacts.
3. Create a mock saves directory structure.

**Scenario 1: Try and resolve flow**

1. Verify conflict artifacts exist in the repo.
2. Call `resolve.sh try ... local`. Verify device save has local bytes.
3. Call `resolve.sh try ... remote`. Verify device save has remote bytes.
4. Call `resolve.sh resolve ... keep_local`. Verify conflict resolved, device save has local bytes, artifacts cleaned up.

**Scenario 2: Multiple conflicts**

1. Set up two conflicts (`snes/zelda.srm` and `gb/links_awakening.srm`).
2. Resolve each via `resolve.sh resolve ... keep_newest`.
3. Verify both resolved, both device saves updated.

**Scenario 3: Conflict scanning (binary data layer)**

1. Create 3 `.conflict` files in the repo with valid JSON.
2. The binary's scanning logic is tested via a small C test harness (`test_scan.c`) that calls the same scanning function and prints the parsed results.
3. Verify all 3 conflicts are found with correct metadata.

### Native Binary Smoke Test

A shell script that:
1. Builds `resolve.elf` natively (`make native`)
2. Sets up a test repo with conflicts
3. Launches `resolve.elf` with `--headless` flag (renders one frame to verify no crash, then exits)
4. Verifies exit code 0

The `--headless` flag is a test-only mode: initializes SDL2 with `SDL_VIDEODRIVER=dummy`, renders one frame, dumps the conflict count to stdout, and exits. This allows CI to verify the binary works without a display.

---

## Resolved Questions

1. **Platform-specific or core?** **Resolved — platform-specific.** The compiled binary is NextUI-specific (SDL2, ARM, PAK structure). It goes under `src/platforms/nextui/`, not `src/core/`. The shell helper `resolve.sh` is also platform-specific because it sources the platform PAL. The core conflict handler logic remains in `src/core/conflict_handler.sh` where it belongs — this sprint only builds a UI layer on top of it.

2. **Link against NextUI's api.o or use SDL2 directly?** **Resolved — SDL2 directly.** NextUI's GFX/PAD API is internal to the launcher and not exposed as a shared library. All existing Tool PAKs (settings.elf, battery.elf, etc.) statically compile their own copy of the needed API source files. For this sprint, using SDL2 directly is simpler and avoids coupling to NextUI's internal build system. If Sprint 1.2 builds a larger `continuity.elf` that needs deeper NextUI integration, it can pull in the API sources at that point.

3. **C or C++?** **Resolved — C, with C++ acceptable if needed.** The resolver is a simple scrollable list with actions — no need for STL containers, templates, or RAII. Plain C with SDL2 keeps it minimal. If linking against system libraries on the device requires C++ linkage (some ARM toolchains bundle SDL2 with C++ deps), C++ compilation is fine, but the code stays procedural.

---

## Open Questions

1. **Font source.** NextUI's `show2.elf` embeds `RoundedMplus1c_Bold_reduced_ttf` (the same font used across the system). Should we extract and reuse this font (it's SIL Open Font License), or bundle a different permissively-licensed font? Using the same font ensures visual consistency with the rest of NextUI.

2. **SDL2 `dummy` video driver in CI.** The `--headless` smoke test relies on `SDL_VIDEODRIVER=dummy` to run without a display. Verify this works in the CI environment (needs `libsdl2-dev` installed). If not, the smoke test can be skipped in CI and only run manually.

3. **`system()` latency.** Each try/resolve operation calls `system("./resolve.sh ...")`, which forks a shell, sources the PAL and core modules, runs the operation, and exits. On the TrimUI Brick's ARM CPU, this may take 0.5–2 seconds. The UI should show a "Working..." indicator during the operation. Confirm this latency is acceptable or consider pre-loading the shell environment.
