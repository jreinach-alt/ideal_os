# Sprint 0.9 — Conflict Resolution Operations

**Status:** Draft
**Date:** 2026-03-15
**Dependencies:** Sprint 0.8 (conflict handler — `ch_handle_pull_conflict`, `ch_list_conflicts`, `ch_list_local_files`, `ch_resolve` available)

---

## Goal

Build the platform-agnostic operations layer that any conflict resolution UI calls into. Sprint 0.8 gave us the conflict *infrastructure* — detection, preservation, and resolution. But between "here are some `.conflict` files" and "resolve this one," there's a gap: the interactive resolution workflow.

A user resolving a conflict needs to:
1. **Browse** — see all conflicts with meaningful context (system, game, device names, timestamps), not raw file paths
2. **Try** — non-destructively swap a version into the device's active save slot so they can test it in-game
3. **Track** — know which version is currently active (what did I last try?)
4. **Resolve** — commit a decision (Sprint 0.8's `ch_resolve` handles this, but the UI needs structured feedback)

This sprint adds these operations to `src/core/conflict_handler.sh` as new `ch_*` functions. They output structured, parseable data that any consumer — shell scripts, compiled C binaries (NextUI), desktop apps (RetroDeck), Android Java — can read trivially.

No platform-specific code. No display logic. Just the operations layer.

---

## Reference Specs

- `docs/design/pal.md` — PAL interface, `CONTINUITY_SAVES_ROOT`, `CONTINUITY_DEVICE_NAME`, `pm_repo_to_local()`
- `docs/design/architecture.md` — Conflict Resolution Strategy section
- `src/core/conflict_handler.sh` — Existing Sprint 0.8 API
- `src/core/path_mapper.sh` — `pm_repo_to_local` (Sprint 0.2 output)

---

## Scope

### New Functions in `src/core/conflict_handler.sh`

All new functions follow the existing `ch_*` naming convention and BusyBox ash conventions established in Sprint 0.8.

---

#### `ch_get_conflict_info` — Parse one conflict's metadata

**Signature:** `ch_get_conflict_info <repo_dir> <repo_path>`

**Parameters:**
- `repo_dir` — absolute path to the repo working copy
- `repo_path` — canonical repo-relative `.srm` path (e.g., `snes/super_metroid.srm`)

**Output:** Key-value pairs to stdout, one per line:

```
file=snes/super_metroid.srm
system=snes
game=super_metroid
remote_device=my-deck
remote_timestamp=2026-03-12T13:00:00Z
local_device=my-brick
local_timestamp=2026-03-12T14:30:00Z
status=unresolved
active_version=remote
```

**Implementation:**
1. Read `$repo_dir/$repo_path.conflict` — parse each JSON field with `grep` + `sed` (same pattern used by `ch_resolve`'s `keep_newest` branch).
2. Derive `system` from path: everything before the first `/`.
3. Derive `game` from path: filename without `.srm` extension.
4. Determine `active_version` by checking the marker file `$repo_dir/.continuity/trying/$marker_name` (see `ch_try_version`). If no marker exists, default is `remote` (the canonical file holds the remote version after conflict detection).
5. Output `status` from the `.conflict` JSON (currently always `unresolved` for active conflicts).

**Returns:** 0 on success, 1 if `.conflict` file doesn't exist or is unparseable.

**Output format rationale:** Key-value lines are trivially parseable in any language:
- Shell: `value=$(echo "$output" | grep '^key=' | sed 's/^key=//')`
- C: `sscanf(line, "key=%s", value)` or `strtok`
- Java/Kotlin: `line.split("=", 2)`
- No JSON production needed (avoids fragile shell JSON generation without `jq`)

---

#### `ch_list_conflicts_detailed` — List all conflicts with full metadata

**Signature:** `ch_list_conflicts_detailed <repo_dir>`

**Output:** Multiple `ch_get_conflict_info` blocks separated by blank lines:

```
file=snes/super_metroid.srm
system=snes
game=super_metroid
remote_device=my-deck
remote_timestamp=2026-03-12T13:00:00Z
local_device=my-brick
local_timestamp=2026-03-12T14:30:00Z
status=unresolved
active_version=remote

file=gb/links_awakening.srm
system=gb
game=links_awakening
remote_device=my-deck
remote_timestamp=2026-03-12T11:00:00Z
local_device=my-brick
local_timestamp=2026-03-12T12:00:00Z
status=unresolved
active_version=local
```

**Implementation:**
1. Call `ch_list_conflicts "$repo_dir"` to get `.conflict` file paths.
2. For each, strip `.conflict` suffix to get `repo_path`.
3. Call `ch_get_conflict_info "$repo_dir" "$repo_path"`.
4. Print a blank line between entries.

**Returns:** 0 always. Empty output if no conflicts.

---

#### `ch_count_conflicts` — Count unresolved conflicts

**Signature:** `ch_count_conflicts <repo_dir>`

**Output:** A single integer to stdout (e.g., `3`). Prints `0` if no conflicts.

**Implementation:** Count lines from `ch_list_conflicts`.

**Returns:** 0 always.

---

#### `ch_try_version` — Swap a save version into the device's active slot

**Signature:** `ch_try_version <repo_dir> <repo_path> <version>`

**Parameters:**
- `repo_dir` — absolute path to the repo working copy
- `repo_path` — canonical repo-relative `.srm` path
- `version` — `remote` or `local`

**Behavior:**
1. Validate that a `.conflict` file exists for `repo_path`. Return 1 if not.
2. Validate that `version` is `remote` or `local`. Return 1 if not.
3. Determine the device save path via `pm_repo_to_local "$repo_path"`. Return 1 if path mapping fails.
4. If `version` is `remote`:
   - Source file: `$repo_dir/$repo_path` (the canonical `.srm`)
   - Copy to device save path.
5. If `version` is `local`:
   - Find the `.local` file: `$repo_dir/$repo_path.$device_name.local` where `$device_name` is extracted from `ch_list_local_files` output for this `repo_path`. If multiple `.local` files exist (future multi-device scenario), use the first match.
   - Copy to device save path.
6. Write a marker file at `$repo_dir/.continuity/trying/$marker_name` containing the `version` string. The marker name is derived from the repo path: replace `/` with `_` (e.g., `snes/super_metroid.srm` → `snes_super_metroid.srm`).
7. Log via `pal_log "info"`.

**Output:** Prints the device save path to stdout (useful for UI feedback: "Swapped save at /mnt/SDCARD/Saves/SFC/super_metroid.srm").

**Returns:** 0 on success, 1 on error.

**Safety:**
- Only copies files to the device save directory — no repo modifications, no commits, no git operations.
- The canonical `.srm` and `.local` file in the repo are never touched.
- The user can swap back and forth freely — each try just overwrites the device save file.

**Marker directory:** `$repo_dir/.continuity/trying/` is created on first use. It is NOT committed to git — it's local device state only (the `.continuity/` directory is already in the repo, but `trying/` is added to `.gitignore`). Different devices can independently try different versions without interfering.

---

#### `ch_get_active_version` — Check which version is in the device's active slot

**Signature:** `ch_get_active_version <repo_dir> <repo_path>`

**Output:** Prints `remote` or `local` to stdout.

**Implementation:**
1. Compute the marker name (same derivation as `ch_try_version`).
2. Read `$repo_dir/.continuity/trying/$marker_name`.
3. If marker exists and contains `local` or `remote`, print that value.
4. If no marker exists, print `remote` (the default state after conflict detection — the canonical file holds the remote version).

**Returns:** 0 always.

---

#### `ch_clear_try_markers` — Clean up all try markers

**Signature:** `ch_clear_try_markers <repo_dir>`

**Behavior:** Remove all files in `$repo_dir/.continuity/trying/`. Called after all conflicts are resolved, or when the UI exits.

**Returns:** 0 always.

---

### Changes to Existing Functions

#### `ch_resolve` — Add device save update

Currently, `ch_resolve` resolves the conflict in the repo (commits the winner) but does NOT update the device save file. The device might still have a stale "try" version in its save slot.

**Change:** After successful resolution, copy the winning canonical `.srm` to the device save path via `pm_repo_to_local`. Also remove the try marker for this save.

This is a small but important addition: after resolution, the device's active save matches the resolved winner, and the try marker is cleaned up.

**Modified behavior in `ch_resolve`:**
```
# After successful commit (in keep_remote and keep_local branches):
local device_path
device_path=$(pm_repo_to_local "$repo_path" 2>/dev/null) || true
if [ -n "$device_path" ] && [ -d "$(dirname "$device_path")" ]; then
    cp "$repo_dir/$repo_path" "$device_path"
fi

# Clean up try marker
local marker_name
marker_name=$(printf '%s' "$repo_path" | sed 's|/|_|g')
rm -f "$repo_dir/.continuity/trying/$marker_name"
```

**Why conditional:** `pm_repo_to_local` may fail if the platform map isn't loaded (e.g., in a test environment that only tests repo-level logic). The device save update is best-effort — the resolution itself (repo commit) is the critical path.

---

### `.gitignore` Update

Add `trying/` to the repo's `.continuity/.gitignore` (or the repo-level `.gitignore`) so try markers are never committed:

```
.continuity/trying/
```

This is written by `ch_try_version` on first use if not already present.

---

## Output Format Specification

The key-value output format is a contract that platform UIs depend on. It must be stable.

**Rules:**
1. One key-value pair per line, format `key=value`.
2. Keys are `snake_case`, ASCII only.
3. Values are UTF-8, may contain any character except newline.
4. No quoting of values (no `key="value"`) — the first `=` is the delimiter.
5. Blocks are separated by exactly one blank line.
6. Unknown keys should be ignored by consumers (forward compatibility).

**Defined keys for `ch_get_conflict_info`:**

| Key | Type | Description |
|-----|------|-------------|
| `file` | string | Canonical repo-relative `.srm` path |
| `system` | string | Canonical system name (derived from path) |
| `game` | string | Game name without extension (derived from path) |
| `remote_device` | string | Device name that pushed the remote version |
| `remote_timestamp` | ISO-8601 | When the remote version was saved |
| `local_device` | string | Device name that has the local version |
| `local_timestamp` | ISO-8601 | When the local version was saved |
| `status` | enum | `unresolved` (only value for active conflicts) |
| `active_version` | enum | `remote` or `local` — which is in the device save slot |

---

## Out of Scope

| Item | Sprint |
|------|--------|
| NextUI SDL2 conflict resolution binary | 1.2 |
| RetroDeck conflict resolution UI | 2.2 |
| Android conflict resolution UI | 3.2 |
| Daemon auto-launch of conflict UI on boot | 1.1 |
| `show2.elf` notification for conflicts | 1.1 |
| Multi-device `.local` selection (3+ device conflicts) | 1.2 |
| Save file preview / hex dump | post-1.0 |
| JSON output format (alternative to key-value) | future, if needed |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `tests/unit/core/test_conflict_ops.sh` | Unit tests for all new `ch_*` functions |
| `tests/integration/test_conflict_resolution_flow.sh` | Integration test: full try → test → resolve lifecycle |

### Files Modified

| File | Change |
|------|--------|
| `src/core/conflict_handler.sh` | Add `ch_get_conflict_info`, `ch_list_conflicts_detailed`, `ch_count_conflicts`, `ch_try_version`, `ch_get_active_version`, `ch_clear_try_markers`. Modify `ch_resolve` to update device save and clean try marker. |
| `docs/design/architecture.md` | Add Conflict Resolution Operations section describing the interactive workflow and output format |

### Directories Created

| Directory | Purpose |
|-----------|---------|
| (none — `$repo_dir/.continuity/trying/` is created at runtime) | |

---

## Acceptance Criteria

### `ch_get_conflict_info`

1. Given a valid `.conflict` file, prints all 9 key-value fields to stdout.
2. `system` is correctly derived from the path (e.g., `snes/super_metroid.srm` → `system=snes`).
3. `game` is correctly derived from the path (e.g., `snes/super_metroid.srm` → `game=super_metroid`).
4. `active_version` defaults to `remote` when no try marker exists.
5. `active_version` returns `local` after `ch_try_version` swaps to local.
6. Returns 1 if no `.conflict` file exists for the given `repo_path`.
7. Returns 1 if the `.conflict` file is missing required fields.

### `ch_list_conflicts_detailed`

8. Returns empty output (no lines) when no conflicts exist.
9. Returns one block per conflict, separated by blank lines.
10. Each block contains all 9 key-value fields.
11. Multiple conflicts are all present in the output.

### `ch_count_conflicts`

12. Prints `0` when no conflicts exist.
13. Prints the correct count when conflicts exist (tested with 1, 2, and 3 conflicts).

### `ch_try_version` — remote

14. Copies the canonical `.srm` (remote version) to the device save path.
15. After try, device save file byte-matches the repo's canonical `.srm` (verified via `cmp -s`).
16. Writes a try marker containing `remote`.
17. Prints the device save path to stdout.
18. Does NOT modify the repo — no new git commits after the operation.

### `ch_try_version` — local

19. Copies the `.local` file to the device save path.
20. After try, device save file byte-matches the `.local` file (verified via `cmp -s`).
21. Writes a try marker containing `local`.
22. Prints the device save path to stdout.
23. Does NOT modify the repo — no new git commits after the operation.

### `ch_try_version` — validation

24. Returns 1 if no `.conflict` file exists for the given `repo_path`.
25. Returns 1 if `version` is not `remote` or `local`.
26. Returns 1 if `pm_repo_to_local` fails (unknown system in platform map).

### `ch_try_version` — idempotency

27. Calling `ch_try_version` twice with `local` produces the same result — device save has local bytes.
28. Swapping from `local` to `remote` and back to `local` leaves device save with local bytes.

### `ch_get_active_version`

29. Returns `remote` when no try marker exists (default state).
30. Returns `local` after `ch_try_version ... local`.
31. Returns `remote` after `ch_try_version ... remote`.

### `ch_clear_try_markers`

32. Removes all files in `$repo_dir/.continuity/trying/`.
33. Returns 0 even if no markers exist (idempotent).
34. After clearing, `ch_get_active_version` returns `remote` for all conflicts.

### `ch_resolve` — device save update (modified behavior)

35. After `ch_resolve ... keep_remote`: device save file contains the remote version's bytes.
36. After `ch_resolve ... keep_local`: device save file contains the local version's bytes.
37. After `ch_resolve ... keep_newest`: device save file contains the winning version's bytes.
38. After resolution, the try marker for the resolved save is removed.
39. If `pm_repo_to_local` fails (e.g., platform map not loaded), resolution still succeeds — device save update is best-effort.

### `.gitignore`

40. `ch_try_version` creates `.continuity/trying/` directory if it doesn't exist.
41. Try markers are never committed to git (verified: `git status` doesn't show them as untracked after `.gitignore` update).

### Code Quality

42. All new code passes `shellcheck` with no errors.
43. All new code passes `busybox ash -n` syntax check.
44. No banned BusyBox ash constructs (see CLAUDE.md table).
45. All variable expansions are quoted.
46. All new functions use `printf` for output, not `echo`.
47. All tests pass under `busybox ash`.
48. Test files pass `shellcheck` and `busybox ash -n`.

---

## Testing Strategy

### Unit Tests (`tests/unit/core/test_conflict_ops.sh`)

Each test creates a fresh `TEST_TMPDIR` with a minimal repo containing conflict artifacts (`.conflict` JSON + `.local` file + canonical `.srm`) and a mock device saves directory.

**Test setup helper** (shared across tests):
```
create_test_conflict <repo_dir> <repo_path> <local_device> <remote_device>
```
Creates the canonical `.srm`, a `.local` file with different bytes, and a `.conflict` JSON.

**`ch_get_conflict_info` tests:**

- Parse valid `.conflict` file → verify all 9 fields present and correct.
- Verify `system` and `game` derivation for multi-segment paths (e.g., `snes/super_metroid.srm`).
- Missing `.conflict` file → returns 1.
- `active_version` is `remote` with no try marker.
- `active_version` is `local` after writing a try marker.

**`ch_list_conflicts_detailed` tests:**

- No conflicts → empty output.
- One conflict → one block with all fields.
- Two conflicts → two blocks separated by blank line.
- Verify field values match the underlying `.conflict` files.

**`ch_count_conflicts` tests:**

- No conflicts → prints `0`.
- One conflict → prints `1`.
- Three conflicts → prints `3`.

**`ch_try_version` tests:**

- Try `remote`: device save byte-matches canonical `.srm`.
- Try `local`: device save byte-matches `.local` file.
- Try with nonexistent conflict → returns 1.
- Try with invalid version → returns 1.
- Try with unmapped system → returns 1.
- No git commits after try (count commits before and after).
- Try marker written correctly.
- Swap local → remote → local: final device save matches `.local` bytes.

**`ch_get_active_version` tests:**

- No marker → prints `remote`.
- After try local → prints `local`.
- After try remote → prints `remote`.

**`ch_clear_try_markers` tests:**

- Clear with markers → directory empty.
- Clear with no markers → returns 0.
- After clear, `ch_get_active_version` returns `remote`.

**`ch_resolve` device save update tests:**

- Resolve `keep_remote` → device save has remote bytes, try marker removed.
- Resolve `keep_local` → device save has local bytes, try marker removed.
- Resolve with no platform map loaded → resolution still succeeds (device save update skipped).

### Integration Test (`tests/integration/test_conflict_resolution_flow.sh`)

Full lifecycle test simulating the user experience across the operations layer.

**Setup:**
1. Create bare remote, two working clones (device-a, device-b).
2. Both devices modify the same `.srm` file with different bytes.
3. Device-a pushes first. Device-b pulls → `se_pull` returns 1 (diverged).
4. `ch_handle_pull_conflict` preserves both versions.
5. Create mock device saves directory with platform map loaded.

**Scenario 1: Browse → Try → Resolve**

1. `ch_count_conflicts` → prints `1`.
2. `ch_list_conflicts_detailed` → one block with correct metadata.
3. `ch_get_active_version` → `remote` (default).
4. `ch_try_version ... local` → device save has device-b's bytes.
5. `ch_get_active_version` → `local`.
6. `ch_try_version ... remote` → device save has device-a's bytes.
7. `ch_get_active_version` → `remote`.
8. `ch_try_version ... local` → swap back.
9. `ch_resolve ... keep_local` → conflict resolved, device save has local bytes.
10. `ch_count_conflicts` → prints `0`.
11. `ch_get_active_version` → `remote` (marker cleared, default state).

**Scenario 2: Resolve without trying (keep_newest)**

1. Set up a new conflict where local timestamp is newer.
2. `ch_resolve ... keep_newest` → resolves to local version.
3. Device save has local bytes.
4. No try markers left behind.

**Scenario 3: Multiple conflicts**

1. Set up two conflicts (`snes/zelda.srm` and `gb/links_awakening.srm`).
2. `ch_count_conflicts` → `2`.
3. `ch_list_conflicts_detailed` → two blocks.
4. Try one conflict, resolve it. `ch_count_conflicts` → `1`.
5. Resolve the other. `ch_count_conflicts` → `0`.
6. `ch_clear_try_markers` → clean exit.

---

## Definition of Done

- [ ] `ch_get_conflict_info` implemented and tested — parses `.conflict` JSON, outputs key-value format.
- [ ] `ch_list_conflicts_detailed` implemented and tested — aggregates info for all conflicts.
- [ ] `ch_count_conflicts` implemented and tested.
- [ ] `ch_try_version` implemented and tested — swaps save version to device, writes marker, no repo changes.
- [ ] `ch_get_active_version` implemented and tested — reads try marker.
- [ ] `ch_clear_try_markers` implemented and tested.
- [ ] `ch_resolve` modified — updates device save and cleans try marker after resolution.
- [ ] `.continuity/trying/` added to `.gitignore` by `ch_try_version`.
- [ ] Key-value output format documented in architecture.md.
- [ ] All shell code passes `shellcheck` and `busybox ash -n`.
- [ ] No banned BusyBox ash constructs.
- [ ] All unit tests pass under `busybox ash`.
- [ ] Integration test passes under `busybox ash`.
- [ ] Sprint summary written to `docs/sprints/sprint-0.9-summary.md` on completion.

---

## Open Questions

1. **Marker filename derivation.** The spec uses `sed 's|/|_|g'` to convert `snes/super_metroid.srm` → `snes_super_metroid.srm`. This is simple and reversible, but could collide if someone had both `a/b.srm` and `a_b.srm` (astronomically unlikely for game saves). Alternative: use a hash. Recommend keeping the simple approach — it's readable for debugging and the collision risk is negligible.

2. **`pm_repo_to_local` dependency in `ch_try_version`.** This function requires the platform map to be loaded (`pm_load_platform_map` called). In test environments that don't set up a platform map, `ch_try_version` will fail at the path mapping step. The tests must either load a test platform map or mock `pm_repo_to_local`. The integration test should load a real platform map; unit tests can use a minimal test map.

3. **`.continuity/trying/` and `.gitignore` management.** Should `ch_try_version` append to the repo's `.gitignore`, or should we expect the enrollment/cold-start process to set up `.gitignore` with all needed patterns? Recommend: `ch_try_version` creates `.continuity/trying/.gitignore` containing `*` (ignore everything in the directory), which is self-contained and doesn't require modifying the repo-level `.gitignore`.
