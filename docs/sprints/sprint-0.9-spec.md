# Sprint 0.9 — Local Conflict Resolution UI

**Status:** Draft
**Date:** 2026-03-15
**Dependencies:** Sprint 0.8 (conflict handler — `ch_list_conflicts`, `ch_list_local_files`, `ch_resolve` available)

---

## Goal

Give users a way to resolve save conflicts from the device itself, using their phone as the interaction surface. When a conflict exists (two versions of the same `.srm` file from different devices), the user can view both versions, swap one into the active save slot to try it in-game, and then mark their preferred version as authoritative — all without needing a second device or a PC.

This is a rudimentary first-pass UI. Sprint 1.2 (NextUI Tool PAK) will build a richer on-device experience. This sprint provides the minimum viable mechanism: a BusyBox `httpd` server with shell CGI scripts and a single-page HTML interface served to the user's phone over the local network.

**Why the phone?** Constrained handhelds (TrimUI Brick, Anbernic) have no web browser. But they're on WiFi (required for sync), and the user's phone is always within reach. The phone provides a natural "second screen" for conflict management while the user tests saves on the handheld.

---

## Reference Specs

- `docs/design/pal.md` — PAL interface, `pal_is_online()`, `CONTINUITY_REPO_DIR`, `CONTINUITY_SAVES_ROOT`, `CONTINUITY_DEVICE_NAME`
- `docs/design/architecture.md` — Conflict Resolution Strategy, BusyBox httpd reference (enrollment section uses port 8080)
- `docs/design/security.md` — BusyBox httpd attack surface assessment
- `src/core/conflict_handler.sh` — `ch_list_conflicts`, `ch_list_local_files`, `ch_resolve` (Sprint 0.8 output)
- `src/core/path_mapper.sh` — `pm_repo_to_local` (Sprint 0.2 output)

---

## Scope

### Conflict Resolution Server (`src/core/conflict_ui/server.sh`)

Manages the lifecycle of a BusyBox `httpd` instance that serves the conflict resolution UI. Designed to be called by platform daemons (Sprint 1.1) or manually by the user via a PAK (Sprint 1.2). The server is ephemeral — it starts when conflicts exist and stops when the user dismisses it or all conflicts are resolved.

**Functions:**

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `cui_start` | `(repo_dir, port)` | 0 on success, 1 on error | Generate httpd config, start BusyBox `httpd` in foreground mode (backgrounded by caller), write PID to `$repo_dir/.continuity/conflict_ui.pid`. Serves static files from the `www/` directory and routes `/cgi-bin/*` to CGI scripts. If `port` is empty, defaults to `8085`. |
| `cui_stop` | `(repo_dir)` | 0 on success, 1 on error | Read PID from `$repo_dir/.continuity/conflict_ui.pid`, kill the process, remove the PID file. Idempotent — returns 0 if no server is running. |
| `cui_is_running` | `(repo_dir)` | 0 if running, 1 if not | Check whether the PID file exists and the process is alive. |
| `cui_get_url` | `(port)` | prints URL to stdout | Determine the device's LAN IP address and print `http://<ip>:<port>`. Uses `ip route` or `ifconfig` (BusyBox-compatible). Returns 1 if no LAN IP can be determined. |

**Port selection:** Port `8085` (default) avoids conflict with enrollment httpd on port `8080` (architecture.md). The port is a parameter so platform entry points can override it if needed.

**PID management:** The conflict UI PID file (`conflict_ui.pid`) is separate from the daemon's PID file (`continuity.pid`). They are independent processes.

---

### CGI Scripts

All CGI scripts are POSIX sh, BusyBox ash compatible. They read environment variables set by BusyBox httpd (`REQUEST_METHOD`, `QUERY_STRING`, `CONTENT_LENGTH`). They source the PAL and core modules to access conflict handler functions. Output is `Content-Type: application/json` for API endpoints.

**CGI environment bootstrap:**

Each CGI script sources a shared bootstrap file (`cgi-bin/_bootstrap.sh`) that:
1. Sets `CONTINUITY_REPO_DIR` from a config file written by `cui_start`
2. Sources the PAL (test PAL or platform PAL, path written to the config file)
3. Sources required core modules (`pal.sh`, `path_mapper.sh`, `sync_engine.sh`, `cold_start.sh`, `conflict_handler.sh`)
4. Calls `pal_init` and `pal_validate`

The config file (`$repo_dir/.continuity/conflict_ui.conf`) is written by `cui_start` and contains:
```sh
CONTINUITY_REPO_DIR="/path/to/repo"
PAL_PATH="/path/to/pal_<platform>.sh"
CORE_DIR="/path/to/src/core"
```

#### `cgi-bin/conflicts.cgi` — List Conflicts

**Method:** GET

**Response:** JSON array of conflict objects.

```json
{
  "conflicts": [
    {
      "file": "snes/super_metroid.srm",
      "remote_device": "my-deck",
      "remote_timestamp": "2026-03-12T13:00:00Z",
      "local_device": "my-brick",
      "local_timestamp": "2026-03-12T14:30:00Z",
      "active_version": "remote",
      "system": "snes",
      "game": "super_metroid"
    }
  ],
  "device_name": "my-brick",
  "device_ip": "192.168.1.42",
  "conflict_count": 1
}
```

**Implementation:**
1. Call `ch_list_conflicts "$CONTINUITY_REPO_DIR"` to get `.conflict` file paths.
2. For each `.conflict` file, read the JSON metadata (using `grep` and `sed` — no `jq`).
3. Determine `active_version`: compare the canonical `.srm` file in the repo against the `.local` file. If canonical matches the file currently on the device (at the path from `pm_repo_to_local`), `active_version` is `"remote"` (the default after conflict detection). If the `.local` file has been swapped in (via `try.cgi`), `active_version` is `"local"`.
4. Derive `system` and `game` from the repo path (e.g., `snes/super_metroid.srm` → system `snes`, game `super_metroid`).
5. Output JSON via `printf`.

**Determining `active_version`:** After conflict detection, the canonical path always holds the remote version. When the user clicks "Try" on the local version, `try.cgi` swaps the `.local` file into the device's save directory. To track which version is active, `try.cgi` writes a marker file at `$repo_dir/.continuity/trying_<file_hash>` containing `"remote"` or `"local"`. `conflicts.cgi` reads this marker. If no marker exists, the default is `"remote"` (the post-conflict-detection state).

#### `cgi-bin/try.cgi` — Swap a Save Version for Testing

**Method:** POST

**Query parameters:**
- `file` — the canonical repo-relative `.srm` path (URL-encoded)
- `version` — `"remote"` or `"local"`

**Response:** JSON with status.

```json
{
  "status": "ok",
  "file": "snes/super_metroid.srm",
  "active_version": "local",
  "message": "Swapped to local version (my-brick). Launch the game to test."
}
```

**Implementation:**
1. Parse `file` and `version` from `QUERY_STRING`.
2. Validate `file` exists as a conflict (`.conflict` metadata exists).
3. Determine the device save path via `pm_repo_to_local "$file"`.
4. If `version` is `"local"`:
   - Find the `.local` file: `$CONTINUITY_REPO_DIR/$file.$device_name.local` (where `$device_name` is parsed from the `.local` filename via `ch_list_local_files`).
   - Copy the `.local` file to the device save path: `cp "$local_file" "$device_save_path"`.
5. If `version` is `"remote"`:
   - Copy the canonical repo file to the device save path: `cp "$CONTINUITY_REPO_DIR/$file" "$device_save_path"`.
6. Write the `trying_<file_hash>` marker file with the active version.
7. Return success JSON.

**Safety:** This only copies files to the device save directory — it does not modify the repo, commit, or push. The user can swap back and forth freely. The canonical `.srm` and `.local` file in the repo remain untouched.

**File hash for marker:** Use a simple path-to-hash derivation: `printf '%s' "$file" | md5sum | cut -d' ' -f1` (BusyBox md5sum is available). This prevents filename collision for markers across different conflicted saves.

#### `cgi-bin/resolve.cgi` — Commit a Resolution

**Method:** POST

**Query parameters:**
- `file` — the canonical repo-relative `.srm` path (URL-encoded)
- `resolution` — `"keep_remote"`, `"keep_local"`, or `"keep_newest"`

**Response:** JSON with status.

```json
{
  "status": "ok",
  "file": "snes/super_metroid.srm",
  "resolution": "keep_local",
  "message": "Resolved: kept local version from my-brick."
}
```

**Implementation:**
1. Parse `file` and `resolution` from `QUERY_STRING`.
2. Validate `resolution` is one of the three accepted values (`keep_remote`, `keep_local`, `keep_newest`). Reject `prompt` — it makes no sense in a resolution UI.
3. Call `ch_resolve "$CONTINUITY_REPO_DIR" "$file" "$resolution"`.
4. If `ch_resolve` returns 0:
   - Copy the resolved canonical file to the device save path (ensure device has the winning version).
   - Remove the `trying_*` marker file for this save.
   - Return success JSON.
5. If `ch_resolve` returns 1:
   - Return error JSON with status `"error"` and a message.
6. After resolution, if `ch_list_conflicts` returns empty (all conflicts resolved), call `cui_stop` to shut down the server (or return a flag in the JSON so the UI can show "all resolved").

---

### Static Web UI (`src/core/conflict_ui/www/index.html`)

A single HTML file with inline CSS and inline JavaScript. No external dependencies, no build step, no framework. Must render correctly on mobile Safari and mobile Chrome (the user's phone).

**UI layout (mobile-first):**

```
┌─────────────────────────────────┐
│  Continuity — Resolve Conflicts │
│  Device: my-brick               │
├─────────────────────────────────┤
│                                 │
│  ┌─ snes / super_metroid ─────┐ │
│  │                            │ │
│  │  Version A: my-deck        │ │
│  │  Saved: Mar 12, 1:00 PM    │ │
│  │  [Try This Version]        │ │
│  │                            │ │
│  │  Version B: my-brick       │ │
│  │  Saved: Mar 12, 2:30 PM    │ │
│  │  [Try This Version]  ← active │
│  │                            │ │
│  │  ── or ──                  │ │
│  │  [Keep Newest Automatically]│ │
│  │                            │ │
│  │  Currently testing: my-brick│ │
│  │  [✓ Keep This Version]     │ │
│  └────────────────────────────┘ │
│                                 │
│  ┌─ gb / links_awakening ────┐  │
│  │  ... (same layout)        │  │
│  └────────────────────────────┘ │
│                                 │
│  ┌────────────────────────────┐ │
│  │  All conflicts resolved!   │ │
│  │  Server shutting down.     │ │
│  └────────────────────────────┘ │
│                                 │
└─────────────────────────────────┘
```

**Behavior:**

1. On load, fetch `GET /cgi-bin/conflicts.cgi`. Render the conflict list.
2. "Try This Version" button: `POST /cgi-bin/try.cgi?file=...&version=remote|local`. Update the card to show which version is active. Show prompt: "Launch the game on your device to test this save."
3. "Keep This Version" button: appears after the user has tried a version. `POST /cgi-bin/resolve.cgi?file=...&resolution=keep_remote|keep_local`. On success, remove the conflict card with a brief animation. If resolution is `keep_local` and the active version was `remote` (or vice versa), warn: "You're keeping a version you haven't tested. Are you sure?" (simple `confirm()` dialog).
4. "Keep Newest Automatically" button: `POST /cgi-bin/resolve.cgi?file=...&resolution=keep_newest`. Same removal behavior.
5. When all conflicts are resolved, show "All conflicts resolved!" message. The page stops polling.
6. Auto-refresh: poll `GET /cgi-bin/conflicts.cgi` every 10 seconds to detect new conflicts or external resolutions. Update the UI diff-style (don't re-render the whole page if nothing changed).

**Styling:**
- System font stack, no web fonts
- Dark background (#1a1a2e or similar), light text — matches gaming handheld aesthetic
- Large touch targets (min 48px) — the user is on a phone
- No animations except card removal fade
- Responsive: single column, fills viewport width

---

### Input Validation and Security

**Path traversal prevention:** All `file` parameters received from the client must be validated before use:
1. Must not contain `..` path components.
2. Must end in `.srm`.
3. Must correspond to an existing `.conflict` file in the repo (call `ch_list_conflicts` and check membership).
4. Reject any request that fails validation with HTTP 400.

**URL decoding:** BusyBox httpd does NOT automatically URL-decode `QUERY_STRING`. CGI scripts must decode `%XX` sequences. Use `busybox httpd -d "$string"` (the `-d` flag URL-decodes a string) or a `sed` pattern:
```sh
urldecode() {
    printf '%s' "$1" | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g' | xargs -0 printf '%b'
}
```

**Bind address:** `httpd` binds to `0.0.0.0` (all interfaces) so the phone can reach it over LAN. This is acceptable per the existing security assessment in `docs/design/security.md` — the server runs on a private LAN, serves no credentials, and the worst case is someone on the same WiFi can swap save files.

**No authentication:** The conflict UI does not require authentication. It serves no secrets — only save file metadata and binary `.srm` content. The security model accepts LAN-level trust (consistent with the enrollment httpd design in architecture.md).

---

## Integration with Daemon Lifecycle

This sprint does NOT implement daemon integration (that's Sprint 1.1). However, the API is designed for it:

**Planned daemon integration (Sprint 1.1):**
```sh
# After boot sync, if conflicts exist:
if [ -n "$(ch_list_conflicts "$CONTINUITY_REPO_DIR")" ]; then
    cui_start "$CONTINUITY_REPO_DIR" "8085" &
    pal_log "info" "Conflict UI available at $(cui_get_url 8085)"
fi
```

**Manual invocation (Sprint 1.2 Tool PAK):**
The NextUI Tool PAK can start/stop the conflict UI server as a menu option.

**For this sprint:** The server is tested by starting it manually via the test harness. The integration test starts `cui_start`, makes HTTP requests via `wget`, and verifies responses.

---

## Out of Scope

| Item | Sprint |
|------|--------|
| Daemon auto-start of conflict UI on boot | 1.1 |
| NextUI Tool PAK menu integration | 1.2 |
| RetroDeck desktop notification integration | 2.2 |
| Android conflict resolution UI (native) | 3.2 |
| HTTPS / TLS for the conflict UI server | never (LAN only, no secrets) |
| Authentication for the conflict UI | never (LAN trust model) |
| Save file preview / hex dump in the UI | post-1.0 |
| Multi-device `.local` selection (pick which device's save) | 1.2 |
| Automatic conflict UI shutdown after idle timeout | 1.1 |
| `pal_on_sync_complete` hook integration | 1.1 |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/core/conflict_ui/server.sh` | Server lifecycle: `cui_start`, `cui_stop`, `cui_is_running`, `cui_get_url` |
| `src/core/conflict_ui/cgi-bin/_bootstrap.sh` | Shared CGI bootstrap: source PAL, core modules, set variables |
| `src/core/conflict_ui/cgi-bin/conflicts.cgi` | GET: list conflicts as JSON |
| `src/core/conflict_ui/cgi-bin/try.cgi` | POST: swap a save version into the device's active save slot |
| `src/core/conflict_ui/cgi-bin/resolve.cgi` | POST: commit a resolution via `ch_resolve` |
| `src/core/conflict_ui/www/index.html` | Single-page conflict resolution UI (HTML + inline CSS + inline JS) |
| `tests/unit/core/test_conflict_ui_server.sh` | Unit tests for `cui_start`, `cui_stop`, `cui_is_running`, `cui_get_url` |
| `tests/unit/core/test_conflict_ui_cgi.sh` | Unit tests for CGI scripts (invoke directly, verify JSON output) |
| `tests/integration/test_conflict_ui_flow.sh` | Integration test: start server, make HTTP requests, verify conflict resolution end-to-end |

### Files Modified

| File | Change |
|------|--------|
| `docs/design/architecture.md` | Add Conflict Resolution UI section referencing this sprint |
| `docs/design/security.md` | Add conflict UI to httpd attack surface table (same risk level as enrollment httpd) |

### Directories Created

| Directory | Purpose |
|-----------|---------|
| `src/core/conflict_ui/` | Conflict resolution UI module root |
| `src/core/conflict_ui/cgi-bin/` | CGI scripts served by BusyBox httpd |
| `src/core/conflict_ui/www/` | Static web assets (index.html) |

---

## Acceptance Criteria

### `cui_start`

1. Starts a BusyBox `httpd` process listening on the specified port.
2. Writes the httpd PID to `$repo_dir/.continuity/conflict_ui.pid`.
3. Writes the CGI bootstrap config to `$repo_dir/.continuity/conflict_ui.conf`.
4. After `cui_start`, `GET /cgi-bin/conflicts.cgi` returns valid JSON (verified via `wget`).
5. After `cui_start`, `GET /index.html` returns the HTML UI.
6. Returns 1 if BusyBox httpd is not available.
7. Returns 1 if the port is already in use.

### `cui_stop`

8. Kills the httpd process identified by the PID file.
9. Removes the PID file after stopping.
10. Returns 0 if no server is running (idempotent).
11. Removes the `conflict_ui.conf` file.

### `cui_is_running`

12. Returns 0 when a conflict UI server is running (PID file exists and process alive).
13. Returns 1 when no server is running.
14. Returns 1 when PID file exists but process is dead (stale PID file).

### `cui_get_url`

15. Prints a URL in the format `http://<lan-ip>:<port>`.
16. Returns 1 if no LAN IP address can be determined.

### `conflicts.cgi`

17. Returns valid JSON with a `conflicts` array, `device_name`, and `conflict_count`.
18. Each conflict object contains `file`, `remote_device`, `remote_timestamp`, `local_device`, `local_timestamp`, `active_version`, `system`, and `game`.
19. Returns `{"conflicts": [], "conflict_count": 0, ...}` when no conflicts exist.
20. `active_version` defaults to `"remote"` when no try marker exists.
21. `active_version` reflects `"local"` after a `try.cgi` call swaps to the local version.

### `try.cgi`

22. Copies the requested version's `.srm` bytes to the device save path (via `pm_repo_to_local`).
23. Does not modify the repo (no commits, no git operations).
24. Returns JSON with `status: "ok"` and the new `active_version`.
25. Returns HTTP 400 with error JSON if `file` parameter fails path validation.
26. Returns HTTP 400 if `version` is not `"remote"` or `"local"`.
27. Returns HTTP 404 if no `.conflict` metadata exists for the requested file.
28. After swap, the device save file contains the correct bytes (verified by `cmp -s`).

### `resolve.cgi`

29. Calls `ch_resolve` with the specified resolution and returns JSON with `status: "ok"`.
30. After resolution, the device save path contains the winning version's bytes.
31. Returns HTTP 400 if `resolution` is not one of `keep_remote`, `keep_local`, `keep_newest`.
32. Returns HTTP 400 if `resolution` is `prompt` (not valid in UI context).
33. Returns HTTP 400 if `file` parameter fails path validation.
34. Returns HTTP 500 with error JSON if `ch_resolve` returns 1.
35. Removes the `trying_*` marker file for the resolved save.
36. Returns `remaining_conflicts` count in the JSON response.

### Input Validation

37. `file` parameter containing `..` is rejected with HTTP 400.
38. `file` parameter not ending in `.srm` is rejected with HTTP 400.
39. `file` parameter not matching any known conflict is rejected with HTTP 400 (for `try.cgi`) or HTTP 404 (for `resolve.cgi` if conflict already resolved).
40. URL-encoded `file` parameter is correctly decoded (e.g., `%20` for spaces).

### Web UI (`index.html`)

41. Loads and renders conflict list from `/cgi-bin/conflicts.cgi` on page load.
42. "Try This Version" button triggers POST to `/cgi-bin/try.cgi` and updates the card UI.
43. "Keep This Version" button triggers POST to `/cgi-bin/resolve.cgi` and removes the card.
44. "Keep Newest Automatically" button triggers POST to `/cgi-bin/resolve.cgi?resolution=keep_newest`.
45. Shows confirmation dialog when keeping a version the user hasn't tried.
46. Shows "All conflicts resolved!" message when conflict list is empty.
47. Auto-polls every 10 seconds and updates the UI.
48. Renders correctly on mobile Safari (iOS) and mobile Chrome (Android) at 375px width.
49. No external resource loads (fonts, CDNs, scripts) — fully self-contained.
50. Touch targets are at least 48px in height.

### Code Quality

51. All `.sh` and `.cgi` files pass `shellcheck` with no errors.
52. All `.sh` and `.cgi` files pass `busybox ash -n` syntax check.
53. No banned BusyBox ash constructs used (see CLAUDE.md table).
54. All variable expansions are quoted.
55. CGI scripts use `printf` for output, not `echo`.
56. All tests pass under `busybox ash`.
57. Test files pass `shellcheck` and `busybox ash -n`.

---

## Testing Strategy

### Unit Tests (`tests/unit/core/test_conflict_ui_server.sh`)

Server lifecycle tests. Each test creates a fresh `TEST_TMPDIR`, sets up a minimal repo with conflict artifacts, and verifies server start/stop behavior.

- `cui_start`: Start server, verify PID file exists, verify process is alive, verify port is listening (via `wget` to localhost).
- `cui_start` with port in use: Start two servers on the same port, verify second returns 1.
- `cui_stop`: Start server, stop it, verify PID file removed, verify process gone.
- `cui_stop` when not running: Verify returns 0 (idempotent).
- `cui_is_running`: Verify returns 0 when running, 1 when stopped, 1 when PID file is stale.
- `cui_get_url`: Verify output format matches `http://<ip>:<port>`.

### Unit Tests (`tests/unit/core/test_conflict_ui_cgi.sh`)

CGI script tests. Each test invokes the CGI script directly (setting `QUERY_STRING`, `REQUEST_METHOD`, etc. as environment variables) and captures stdout. Verifies JSON output structure and correctness.

**`conflicts.cgi` tests:**

- No conflicts: verify `{"conflicts": [], "conflict_count": 0, ...}`.
- One conflict: set up a `.conflict` file, verify JSON contains correct fields.
- Two conflicts: verify both appear in the array.
- `active_version` default: verify `"remote"` when no try marker exists.
- `active_version` after try: write a try marker, verify `"local"` is returned.

**`try.cgi` tests:**

- Swap to local: set up conflict, POST `version=local`, verify device save file contains local bytes.
- Swap to remote: POST `version=remote`, verify device save file contains remote bytes.
- Path traversal: POST `file=../../etc/passwd`, verify HTTP 400.
- Invalid file: POST `file=nonexistent.srm`, verify HTTP 400.
- Invalid version: POST `version=invalid`, verify HTTP 400.
- No repo modification: verify no new git commits after swap.

**`resolve.cgi` tests:**

- Resolve keep_remote: verify `ch_resolve` called correctly, device save updated, marker removed.
- Resolve keep_local: same flow with `keep_local`.
- Resolve keep_newest: same flow with `keep_newest`.
- Reject prompt: POST `resolution=prompt`, verify HTTP 400.
- Path traversal: verify HTTP 400.
- ch_resolve failure: stub `ch_resolve` to return 1, verify HTTP 500.

### Integration Test (`tests/integration/test_conflict_ui_flow.sh`)

Full end-to-end test using a real BusyBox httpd server. Simulates the complete user flow:

**Setup:**
1. Create `TEST_TMPDIR` with bare remote, two working clones (device-a, device-b).
2. Create a diverged state and run `ch_handle_pull_conflict` to create conflict artifacts.
3. Source test PAL and all core modules.

**Scenario 1: Full conflict resolution flow**

1. Call `cui_start "$CONTINUITY_REPO_DIR" "8185"` (test port to avoid collisions).
2. `wget -qO- http://127.0.0.1:8185/cgi-bin/conflicts.cgi` — verify JSON lists 1 conflict.
3. `wget -qO- --post-data='' "http://127.0.0.1:8185/cgi-bin/try.cgi?file=snes/super_metroid.srm&version=local"` — verify success, verify device save file has local bytes.
4. `wget -qO- --post-data='' "http://127.0.0.1:8185/cgi-bin/try.cgi?file=snes/super_metroid.srm&version=remote"` — verify success, verify device save file has remote bytes.
5. `wget -qO- --post-data='' "http://127.0.0.1:8185/cgi-bin/try.cgi?file=snes/super_metroid.srm&version=local"` — swap back to local.
6. `wget -qO- --post-data='' "http://127.0.0.1:8185/cgi-bin/resolve.cgi?file=snes/super_metroid.srm&resolution=keep_local"` — verify resolution committed.
7. `wget -qO- http://127.0.0.1:8185/cgi-bin/conflicts.cgi` — verify empty conflicts list.
8. Call `cui_stop "$CONTINUITY_REPO_DIR"` — verify clean shutdown.

**Scenario 2: Input validation**

1. Start server.
2. Send requests with `..` in file path — verify 400.
3. Send requests with non-`.srm` file — verify 400.
4. Send request for non-existent conflict — verify 400.
5. Stop server.

**Scenario 3: Static content**

1. Start server.
2. `wget -qO- http://127.0.0.1:8185/index.html` — verify contains `<html>`.
3. Stop server.

---

## BusyBox httpd Configuration

`cui_start` generates an `httpd.conf` file at `$repo_dir/.continuity/httpd.conf`:

```
# Continuity conflict resolution UI
# CGI scripts in /cgi-bin/ are executed
*.cgi:/bin/sh
```

BusyBox httpd CGI convention: files in the `cgi-bin/` directory with the `.cgi` extension are executed. The script's stdout becomes the HTTP response body. The script must output HTTP headers first (at minimum `Content-Type`), followed by a blank line, then the body.

**CGI response pattern:**

```sh
#!/bin/sh
printf 'Content-Type: application/json\r\n'
printf '\r\n'
printf '{"status": "ok"}\n'
```

**Error response pattern (HTTP 400):**

```sh
printf 'Status: 400 Bad Request\r\n'
printf 'Content-Type: application/json\r\n'
printf '\r\n'
printf '{"status": "error", "message": "Invalid file parameter"}\n'
```

BusyBox httpd supports the `Status:` header from CGI scripts for non-200 responses.

---

## Definition of Done

- [ ] `src/core/conflict_ui/server.sh` implemented with all four `cui_*` functions.
- [ ] `src/core/conflict_ui/cgi-bin/_bootstrap.sh` sources PAL and core modules correctly.
- [ ] `src/core/conflict_ui/cgi-bin/conflicts.cgi` returns correct JSON for 0, 1, and multiple conflicts.
- [ ] `src/core/conflict_ui/cgi-bin/try.cgi` swaps save versions without modifying the repo.
- [ ] `src/core/conflict_ui/cgi-bin/resolve.cgi` calls `ch_resolve` and updates device save.
- [ ] All CGI scripts validate input (path traversal, `.srm` suffix, conflict existence).
- [ ] `src/core/conflict_ui/www/index.html` renders correctly on mobile browsers.
- [ ] UI shows try/resolve workflow with confirmation for untested versions.
- [ ] All shell files pass `shellcheck` with no errors.
- [ ] All shell files pass `busybox ash -n` syntax check.
- [ ] No banned BusyBox ash constructs used (see CLAUDE.md table).
- [ ] All variable expansions quoted throughout.
- [ ] Unit tests pass under `busybox ash`.
- [ ] Integration test passes under `busybox ash` with real BusyBox httpd.
- [ ] `docs/design/architecture.md` updated with conflict UI section.
- [ ] `docs/design/security.md` updated with conflict UI attack surface.
- [ ] Sprint summary written to `docs/sprints/sprint-0.9-summary.md` on completion.

---

## Open Questions

1. **`conflict_ui/` under `src/core/` vs `src/platforms/`?** The UI server and CGI scripts are platform-agnostic (BusyBox httpd + POSIX sh), so they belong in `src/core/` per the project rules. However, the `www/index.html` file is static HTML, not shell code. This seems acceptable since it's served by the core module, not by platform-specific code. Confirm or redirect.

2. **CGI script executable bit on FAT32.** TrimUI Brick uses FAT32, which doesn't support Unix file permissions. BusyBox httpd may require CGI scripts to be executable (`chmod +x`). On FAT32, all files appear executable. Confirm this works on-device or identify a workaround (e.g., httpd `-c` config to map `.cgi` extension to `/bin/sh` interpreter).

3. **`md5sum` availability on all targets.** The `trying_*` marker uses `md5sum` to hash the file path. BusyBox includes `md5sum`, but confirm it's present on all target platforms. Alternative: use the repo path directly (with `/` replaced by `_`) as the marker filename — simpler, no hash dependency.
