# Sprint 0.10 — Sync Status

**Status:** Draft
**Date:** 2026-03-15
**Dependencies:** Sprint 0.9 (conflict ops — `ch_count_conflicts`, `ch_is_trying_modified`, `ch_list_conflicts_detailed`), Sprint 0.6 (runtime poll), Sprint 0.4 (cold start), Sprint 0.3 (enrollment — device JSON with `last_sync`/`last_push` fields)

---

## Goal

Give every layer of the system — platform daemons, UI overlays, conflict resolution tools, and the user themselves — a single authoritative answer to the question: **"What is the state of my saves right now?"**

The answer is a colored dot:

- **Green:** Saves are synced with the repo. Everything is good.
- **Yellow:** Sync ran but couldn't push (offline), or a push is pending. Nothing is lost — commits are local — but the remote repo is behind.
- **Red:** Action required. Unresolved conflicts, a save modified during a try (Pokémon scenario), or a sync failure that needs investigation.

This is the last Phase 0 sprint. After this, every core concept is in place: enrollment, sync, conflict detection, conflict resolution, and status reporting. Phase 1 starts building platform-specific clients on top of this complete core.

### What This Sprint Is

A `src/core/sync_status.sh` module that:
1. **Records** sync events (timestamps, outcomes) as they happen
2. **Computes** the current status by combining event history with live state (conflicts, trying, connectivity)
3. **Outputs** structured status in the same key-value format established in Sprint 0.9

### What This Sprint Is Not

- No display logic. No colored dots on screen. No overlays.
- No platform-specific code. The NextUI overlay, RetroDeck notification, and Android status bar are Phase 1/2/3.
- The core computes the status. Platforms decide how to show it.

---

## Reference Specs

- `docs/design/pal.md` — PAL interface, `pal_is_online()`, `pal_on_sync_complete()` hook
- `src/core/conflict_handler.sh` — `ch_count_conflicts()`, `ch_is_trying_modified()`, `ch_list_conflicts_detailed()` (Sprint 0.9)
- `src/core/runtime_poll.sh` — `rp_run()` (Sprint 0.6)
- `src/core/cold_start.sh` — `cs_run()` (Sprint 0.4)
- `src/core/boot_pull.sh` — `bp_run()` (Sprint 0.5)
- `src/core/enrollment.sh` — device JSON schema with `last_sync`/`last_push` (Sprint 0.3)

---

## Design

### Status Model

The status is computed from two inputs:

**1. Event log** — a small file recording the outcome of the most recent sync operations. Written by the sync pipeline after each operation completes.

**2. Live state** — queried at status-computation time from existing modules (conflict count, trying-modified state, connectivity).

The event log is necessary because some information is only available at sync time (did the push succeed? did it fail? when?). Live state is necessary because some information changes independently of the sync pipeline (user resolves a conflict through the UI, network comes back up).

### Event Log

**Location:** `$repo_dir/.continuity/sync_events`

**Format:** Key-value, consistent with Sprint 0.9. Overwritten (not appended) after each sync operation — we only care about the most recent state, not history.

```
last_sync_time=2026-03-15T14:30:00Z
last_sync_result=ok
last_push_time=2026-03-15T14:30:00Z
last_push_result=ok
last_pull_time=2026-03-15T14:29:55Z
last_pull_result=ok
pending_commits=0
```

| Key | Values | Description |
|-----|--------|-------------|
| `last_sync_time` | ISO-8601 or `never` | When the last `rp_run` completed |
| `last_sync_result` | `ok`, `error`, `nothing` | Outcome of last poll cycle. `nothing` = no changes detected. |
| `last_push_time` | ISO-8601 or `never` | When the last successful push completed |
| `last_push_result` | `ok`, `error`, `offline`, `never` | Outcome of last push attempt |
| `last_pull_time` | ISO-8601 or `never` | When the last successful pull completed |
| `last_pull_result` | `ok`, `error`, `diverged`, `never` | Outcome of last pull. `diverged` = conflict handler invoked. |
| `pending_commits` | integer | Commits ahead of remote (0 = fully pushed) |

**Why a file and not just return codes?** Return codes are transient — they exist only in the process that ran the sync. A file persists across daemon restarts, device reboots, and can be read by any process (the overlay binary, a PAK script, a cron job, the user with `cat`).

**Why overwrite instead of append?** We're not building an audit log. We need "current state" answers, not history. One small file, atomically written (write to temp, `mv` over), always consistent.

### Status Computation

**`ss_get_status`** reads the event log and queries live state to produce a single status with a level and detail fields.

#### Status Levels

```
level=green
```

**Green** — all of these are true:
- `last_push_result` is `ok` (or `never` if device just enrolled and has nothing to push)
- `ch_count_conflicts` returns 0
- No trying-modified files
- `pending_commits` is 0

```
level=yellow
```

**Yellow** — any of these are true (and none of the red conditions):
- `last_push_result` is `offline` — commits exist locally but haven't reached the remote
- `pending_commits` > 0 — same thing, phrased differently (safety net in case push result wasn't recorded)
- `pal_is_online` returns 1 (currently offline) — even if last push was ok, we can't push right now
- A trying state is active but unmodified — user is in the middle of conflict resolution, workflow is expected

```
level=red
```

**Red** — any of these are true:
- `ch_count_conflicts` > 0 and no active trying state — conflicts exist and user hasn't started resolving them
- `ch_is_trying_modified` returns 0 for any conflict — Pokémon scenario, user played during a try
- `last_sync_result` is `error` — something broke
- `last_push_result` is `error` — push failed for reasons other than being offline (auth error, repo deleted, etc.)

#### Priority

If multiple conditions are true, the highest severity wins: red > yellow > green.

### Status Output

**`ss_get_status`** prints:

```
level=green
summary=Synced
last_sync=2026-03-15T14:30:00Z
last_push=2026-03-15T14:30:00Z
conflicts=0
trying_modified=0
pending_commits=0
online=yes
```

Or:

```
level=yellow
summary=Offline — 2 commits pending
last_sync=2026-03-15T14:30:00Z
last_push=2026-03-15T14:20:00Z
conflicts=0
trying_modified=0
pending_commits=2
online=no
```

Or:

```
level=red
summary=1 conflict needs attention
last_sync=2026-03-15T14:30:00Z
last_push=2026-03-15T14:30:00Z
conflicts=1
trying_modified=1
pending_commits=0
online=yes
```

| Key | Type | Description |
|-----|------|-------------|
| `level` | enum | `green`, `yellow`, `red` |
| `summary` | string | Human-readable one-line description. Platform UIs can display this directly. |
| `last_sync` | ISO-8601 or `never` | When last sync cycle completed |
| `last_push` | ISO-8601 or `never` | When last successful push completed |
| `conflicts` | integer | Unresolved conflict count |
| `trying_modified` | integer | Count of conflicts in trying-modified state |
| `pending_commits` | integer | Local commits not yet pushed |
| `online` | `yes` or `no` | Current connectivity |

**Summary strings** (exhaustive list — UIs can rely on these patterns):

| Level | Condition | Summary |
|-------|-----------|---------|
| green | Synced, no conflicts | `Synced` |
| green | Just enrolled, nothing to sync | `Ready` |
| yellow | Offline, no pending | `Offline` |
| yellow | Offline, N pending | `Offline — N commit(s) pending` |
| yellow | Trying (unmodified) | `Trying save — N conflict(s) in progress` |
| red | Conflicts, no trying | `N conflict(s) need attention` |
| red | Trying-modified | `Save modified during try — action required` |
| red | Sync error | `Sync error — check logs` |
| red | Push error | `Push failed — check credentials` |

---

## Scope

### New Module: `src/core/sync_status.sh`

All functions follow `ss_*` naming convention.

---

#### `ss_record_event` — Record a sync event

**Signature:** `ss_record_event <repo_dir> <event_type> <result>`

**Parameters:**
- `repo_dir` — absolute path to the repo working copy
- `event_type` — `sync`, `push`, or `pull`
- `result` — event-specific result string (see table above)

**Behavior:**
1. Read the existing event log (or initialize defaults if it doesn't exist).
2. Update the relevant fields based on `event_type`:
   - `sync`: updates `last_sync_time` and `last_sync_result`
   - `push`: updates `last_push_time` and `last_push_result`
   - `pull`: updates `last_pull_time` and `last_pull_result`
3. Compute `pending_commits` by counting commits ahead of `origin/main`: `git rev-list --count origin/main..HEAD` (returns 0 if up to date, N if commits are queued). If remote tracking isn't set up or fetch fails, defaults to 0.
4. Write the event log atomically (write to temp file, `mv` into place).

**Returns:** 0 on success, 1 on error.

**Timestamp:** Uses `date -u '+%Y-%m-%dT%H:%M:%SZ'` (same as all other Continuity timestamps).

---

#### `ss_get_status` — Compute and output current status

**Signature:** `ss_get_status <repo_dir>`

**Output:** Key-value pairs to stdout (see Status Output section above).

**Implementation:**
1. Read the event log. If it doesn't exist, use defaults (`never` for all timestamps, `ok` for results, `0` for pending).
2. Query live state:
   - `ch_count_conflicts "$repo_dir"` for conflict count.
   - Check all conflicts for trying-modified state (iterate `ch_list_conflicts`, call `ch_is_trying_modified` for each, count).
   - `pal_is_online` for connectivity.
   - Recount `pending_commits` live (in case a push happened outside the normal flow).
3. Apply the status level rules (red > yellow > green).
4. Generate the summary string.
5. Print all fields.

**Returns:** 0 always.

---

#### `ss_get_level` — Quick status level check

**Signature:** `ss_get_level <repo_dir>`

**Output:** Prints a single word to stdout: `green`, `yellow`, or `red`.

**Implementation:** Same logic as `ss_get_status` but only outputs the level. This is the fast path for scripts and daemons that just need to know the color.

**Returns:** 0 always.

---

#### `ss_init_events` — Initialize the event log

**Signature:** `ss_init_events <repo_dir>`

**Behavior:** Creates the event log file with default values (`never` for all timestamps, `0` for pending commits). Called during enrollment or cold start to ensure the file exists.

**Returns:** 0 on success, 1 on error.

---

### Integration Points — Changes to Existing Modules

#### `src/core/runtime_poll.sh` — `rp_run()`

Add `ss_record_event` calls at existing decision points:

**After Step 2 (no candidates):**
```sh
ss_record_event "$repo_dir" "sync" "nothing"
return 0
```

**After Step 9 (sync complete, push succeeded):**
```sh
ss_record_event "$repo_dir" "sync" "ok"
ss_record_event "$repo_dir" "push" "ok"
```

**After push offline (Step 7, `push_rc` = 2 or `pal_is_online` returns 1):**
```sh
ss_record_event "$repo_dir" "sync" "ok"
ss_record_event "$repo_dir" "push" "offline"
```

**On error (any return 1 path):**
```sh
ss_record_event "$repo_dir" "sync" "error"
```

#### `src/core/boot_pull.sh` — `bp_run()`

**After successful pull:**
```sh
ss_record_event "$repo_dir" "pull" "ok"
```

**After diverged pull (conflict detected):**
```sh
ss_record_event "$repo_dir" "pull" "diverged"
```

#### `src/core/cold_start.sh` — `cs_run()`

**After successful cold start sync:**
```sh
ss_record_event "$repo_dir" "sync" "ok"
ss_record_event "$repo_dir" "push" "ok"
```

**After cold start offline:**
```sh
ss_record_event "$repo_dir" "sync" "ok"
ss_record_event "$repo_dir" "push" "offline"
```

#### `src/core/enrollment.sh` — `enroll_run()`

**After successful enrollment:**
```sh
ss_init_events "$CONTINUITY_REPO_DIR"
```

#### Module dependency headers

Add `sync_status: ss_record_event()` to the "Required modules" comment in `runtime_poll.sh`, `boot_pull.sh`, `cold_start.sh`.

---

### Device JSON Updates

The existing `last_sync` and `last_push` fields in `.continuity/devices/<name>.json` are currently `null`. Rather than duplicating state between the device JSON and the event log, these fields are **updated by `ss_record_event`** when the event type is `sync` or `push` with result `ok`.

This means:
- The event log (`sync_events`) is the operational state file, read by `ss_get_status`.
- The device JSON is the durable record visible across devices (it's committed to the repo).
- `ss_record_event` writes to both: event log (local) and device JSON (committed).

The device JSON update is best-effort — if the JSON doesn't exist or can't be parsed, the event log is still written.

---

### `.gitignore` Update

Add to `.continuity/.gitignore` (or via the self-contained pattern from Sprint 0.9):

```
sync_events
```

The event log is local device state. Different devices have different sync histories. Committing it would cause constant conflicts.

---

## Out of Scope

| Item | Sprint |
|------|--------|
| NextUI overlay display (colored dot on screen) | 1.1 or 1.2 |
| RetroDeck desktop notification | 2.1 |
| Android notification bar integration | 3.1 |
| Historical sync log / audit trail | post-1.0 |
| Sync health dashboard / web UI | post-1.0 |
| Automatic retry on push failure | 1.1 (daemon) |
| Notification sound / haptic on status change | post-1.0 |
| Status change webhook / callback | future |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/core/sync_status.sh` | Sync status module — `ss_record_event`, `ss_get_status`, `ss_get_level`, `ss_init_events` |
| `tests/unit/core/test_sync_status.sh` | Unit tests for all `ss_*` functions |
| `tests/integration/test_status_lifecycle.sh` | Integration test: enrollment → sync → offline → conflict → resolution → green |

### Files Modified

| File | Change |
|------|--------|
| `src/core/runtime_poll.sh` | Add `ss_record_event` calls at sync completion points. Add module dependency comment. |
| `src/core/boot_pull.sh` | Add `ss_record_event` calls after pull outcomes. |
| `src/core/cold_start.sh` | Add `ss_record_event` and `ss_init_events` calls. |
| `src/core/enrollment.sh` | Add `ss_init_events` call after successful enrollment. |
| `docs/design/architecture.md` | Add Sync Status section describing the status model and event log. |

### Directories Created

None — `$repo_dir/.continuity/` already exists.

---

## Acceptance Criteria

### `ss_record_event`

1. After `ss_record_event ... sync ok`, the event log contains `last_sync_result=ok` and a valid `last_sync_time`.
2. After `ss_record_event ... push offline`, the event log contains `last_push_result=offline`.
3. After `ss_record_event ... pull diverged`, the event log contains `last_pull_result=diverged`.
4. Recording a new event preserves fields from previous events (e.g., recording a push doesn't erase the last sync time).
5. Event log is written atomically (write to temp, `mv` into place).
6. If event log doesn't exist, it's initialized with defaults before recording.
7. `pending_commits` is updated from `git rev-list --count origin/main..HEAD`.
8. Device JSON `last_sync` field is updated when `sync ok` is recorded.
9. Device JSON `last_push` field is updated when `push ok` is recorded.

### `ss_get_status` — Green

10. After successful sync + push: `level=green`, `summary=Synced`.
11. Fresh enrollment with nothing to sync: `level=green`, `summary=Ready`.
12. All numeric fields are correct (`conflicts=0`, `trying_modified=0`, `pending_commits=0`).
13. `online=yes` when `pal_is_online` returns 0.

### `ss_get_status` — Yellow

14. After sync + push offline: `level=yellow`, `summary` contains "Offline".
15. With pending commits: `summary` includes the count (e.g., "2 commit(s) pending").
16. When trying state is active but unmodified: `level=yellow`.
17. `online=no` when `pal_is_online` returns 1.

### `ss_get_status` — Red

18. With unresolved conflicts (no trying): `level=red`, `summary` includes conflict count.
19. With trying-modified file: `level=red`, `summary` contains "action required".
20. After sync error: `level=red`, `summary` contains "error".
21. After push error: `level=red`, `summary` contains "credentials".

### `ss_get_status` — Priority

22. Red + yellow conditions simultaneously: `level=red` wins.
23. Yellow + green conditions simultaneously: `level=yellow` wins.

### `ss_get_level`

24. Returns `green`, `yellow`, or `red` — single word, no other output.
25. Matches `level` field from `ss_get_status` under identical conditions.

### `ss_init_events`

26. Creates event log with all fields set to defaults (`never`/`0`).
27. Idempotent — calling twice doesn't corrupt the file.

### Integration — `rp_run`

28. After a complete sync cycle with push: event log shows `last_sync_result=ok`, `last_push_result=ok`.
29. After a sync cycle that commits but can't push: `last_sync_result=ok`, `last_push_result=offline`.
30. After a sync cycle that errors: `last_sync_result=error`.
31. After a no-op poll (no changes): `last_sync_result=nothing`.

### Integration — `bp_run`

32. After successful boot pull: `last_pull_result=ok`.
33. After diverged pull (conflict): `last_pull_result=diverged`.

### Integration — `cs_run`

34. After successful cold start: event log exists with `last_sync_result=ok`.
35. After cold start offline: `last_push_result=offline`.

### Integration — `enroll_run`

36. After enrollment: event log exists with all defaults.

### `.gitignore`

37. Event log (`sync_events`) is not committed to git.

### Code Quality

38. All new code passes `shellcheck` with no errors.
39. All new code passes `busybox ash -n` syntax check.
40. No banned BusyBox ash constructs (see CLAUDE.md table).
41. All variable expansions are quoted.
42. All new functions use `printf` for output, not `echo`.
43. All tests pass under `busybox ash`.

---

## Testing Strategy

### Unit Tests (`tests/unit/core/test_sync_status.sh`)

Each test creates a fresh `TEST_TMPDIR` with a minimal repo and `.continuity/` directory.

**`ss_record_event` tests:**

- Record sync ok → verify event log fields.
- Record push offline → verify push fields, sync fields unchanged.
- Record pull diverged → verify pull fields.
- Record multiple events sequentially → verify all fields present (no data loss).
- Atomic write: verify event log is always complete (no partial writes via interrupted test).
- No existing event log → file created with defaults, then event recorded.
- Pending commits count matches actual git state.

**`ss_get_status` green tests:**

- Fresh enrollment → `level=green`, `summary=Ready`.
- After sync + push ok → `level=green`, `summary=Synced`.
- Verify all output fields present and well-formed.

**`ss_get_status` yellow tests:**

- After push offline → `level=yellow`.
- With pending commits → `summary` includes count.
- Offline (mock `pal_is_online` to return 1) → `level=yellow`.
- Trying active but unmodified → `level=yellow`.

**`ss_get_status` red tests:**

- Unresolved conflicts (create `.conflict` files) → `level=red`.
- Trying-modified (set up trying state, modify device file) → `level=red`.
- Sync error → `level=red`.
- Push error → `level=red`.

**Priority tests:**

- Red + yellow → `level=red`.
- Yellow + green → `level=yellow`.

**`ss_get_level` tests:**

- Returns single word matching `ss_get_status` level.
- No extra output (no trailing newline issues).

**`ss_init_events` tests:**

- Creates file with all defaults.
- Idempotent.

### Integration Test (`tests/integration/test_status_lifecycle.sh`)

Full lifecycle simulating a device's sync history and status progression.

**Setup:**
- Create bare remote, local clone, device saves directory, platform map.
- Run enrollment → `ss_init_events`.

**Phase 1: Fresh start**
1. `ss_get_level` → `green` (just enrolled, nothing to sync).
2. `ss_get_status` → `summary=Ready`.

**Phase 2: First sync**
1. Create a save file on "device."
2. Run `rp_run` → sync cycle completes, push succeeds.
3. `ss_get_level` → `green`.
4. `ss_get_status` → `summary=Synced`, `last_sync` is a valid timestamp.

**Phase 3: Offline**
1. Mock `pal_is_online` to return 1.
2. Create another save change, run `rp_run`.
3. `ss_get_level` → `yellow`.
4. `ss_get_status` → `summary` contains "Offline", `pending_commits=1`.

**Phase 4: Back online**
1. Restore `pal_is_online` to return 0.
2. Run `rp_run` → push succeeds.
3. `ss_get_level` → `green`.
4. `pending_commits=0`.

**Phase 5: Conflict**
1. Create a conflict via diverged history (second clone pushes, first clone pulls).
2. `ch_handle_pull_conflict`.
3. `ss_get_level` → `red`.
4. `ss_get_status` → `summary` contains "conflict", `conflicts=1`.

**Phase 6: Trying**
1. `ch_try_version ... local`.
2. `ss_get_level` → `yellow` (trying, unmodified — expected workflow).

**Phase 7: Pokémon scenario**
1. Modify the device save file.
2. `ss_get_level` → `red`.
3. `ss_get_status` → `trying_modified=1`, `summary` contains "action required".

**Phase 8: Resolution**
1. `ch_promote_trying` (or `ch_resolve`).
2. `ss_get_level` → `green` (after push).
3. `conflicts=0`, `trying_modified=0`.

---

## Relationship to Platform Overlays

This sprint provides the data. Future sprints provide the display:

```
┌─────────────────────────────────────────────────────┐
│ src/core/sync_status.sh                              │
│                                                      │
│  ss_get_status() → level=green/yellow/red            │
│                    summary=...                       │
│                    last_sync=...                     │
│                    conflicts=...                     │
│                    trying_modified=...               │
│                    pending_commits=...               │
│                    online=...                        │
└──────┬──────────────┬──────────────┬────────────────┘
       │              │              │
  Sprint 1.1/1.2  Sprint 2.1    Sprint 3.1
       │              │              │
  ┌────▼────┐   ┌────▼────┐   ┌────▼────┐
  │ NextUI  │   │RetroD.  │   │ Android │
  │ colored │   │ desktop │   │ notif.  │
  │ dot via │   │ notif.  │   │ bar     │
  │show2.elf│   │via D-Bus│   │ icon    │
  └─────────┘   └─────────┘   └─────────┘
```

**NextUI specifically:** The daemon (Sprint 1.1) calls `ss_get_level` after each poll cycle. If the level changed, it invokes `show2.elf` (a tiny SDL2 binary that NextUI already uses for notifications) with a colored dot in the status bar area. The dot persists until the level changes. This is a ~20 line shell wrapper around an existing NextUI primitive — minimal effort once the core status module exists.

---

## Definition of Done

- [ ] `ss_record_event` implemented and tested — records sync/push/pull events atomically.
- [ ] `ss_get_status` implemented and tested — computes level + all output fields.
- [ ] `ss_get_level` implemented and tested — fast path for level-only queries.
- [ ] `ss_init_events` implemented and tested — creates event log with defaults.
- [ ] `rp_run` modified — records events at all outcome points.
- [ ] `bp_run` modified — records pull events.
- [ ] `cs_run` modified — records sync events and calls `ss_init_events`.
- [ ] `enroll_run` modified — calls `ss_init_events`.
- [ ] Device JSON `last_sync`/`last_push` fields updated by `ss_record_event`.
- [ ] Event log (`sync_events`) excluded from git via `.gitignore`.
- [ ] Summary strings documented and exhaustive.
- [ ] All shell code passes `shellcheck` and `busybox ash -n`.
- [ ] No banned BusyBox ash constructs.
- [ ] All unit tests pass under `busybox ash`.
- [ ] Integration test passes — full lifecycle green → yellow → red → green.
- [ ] Sprint summary written to `docs/sprints/sprint-0.10-summary.md` on completion.

---

## Open Questions

1. **Should `ss_get_status` call `pal_is_online`?** This adds a network probe (typically `ping -c 1 github.com`) to every status query. On constrained devices, this could take 3 seconds if offline. Alternative: only use the last-known push result to infer connectivity, and let the daemon update connectivity status during its poll cycle. Recommend: make it optional — `ss_get_status` reads an `online` field from the event log (written by the daemon), and only probes live if the caller passes a flag or if the event log field is stale (>60 seconds old).

2. **Pending commits count via `git rev-list`.** This requires the remote tracking branch (`origin/main`) to exist. On a fresh enrollment before the first push, `origin/main` might not exist locally. Fallback: if `git rev-list` fails, report `pending_commits=0` and rely on `last_push_result=never` to indicate the state.

3. **Device JSON update atomicity.** `ss_record_event` updates the device JSON, which is committed to git. But `ss_record_event` is called *during* the sync pipeline (after commit, before/after push). Updating a committed file during the pipeline risks creating a new dirty state that triggers the *next* poll cycle to commit the device JSON change. Two options: (a) batch the device JSON update into the same commit as the save files, or (b) only update the device JSON during `ss_init_events` and on explicit "finalize" calls, not on every event. Recommend (b) — update timestamps only when a full sync cycle completes cleanly, not on every intermediate event.

4. **Summary string localization.** The summary strings are English. For now, this is fine — all target platforms (NextUI, RetroDeck, Android) use English UIs. If localization is ever needed, the summary becomes a key that platform UIs look up in a string table. The `level` field (green/yellow/red) is the language-independent signal; `summary` is a convenience.
