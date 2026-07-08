# Sprint 1.9 — Repo Migration (ideal_os → continuity) + OTA Repoint

**Status:** Approved (owner-directed, 2026-07-08). Executed by a
dedicated migration session.
**Date:** 2026-07-08
**Dependencies:** Sprint 1.8 (channel-manifest OTA — the machinery this
migration rides). PR #4 merged (this spec and the current docs must be
on main before work starts).

## Goal

Move the project home from `jreinach-alt/ideal_os` to
`jreinach-alt/continuity` with full history, and repoint the deployed
fleet (one TrimUI Brick) via a normal OTA update — no card swap, no
stranded devices, and a permanent self-healing path for any device that
misses the handoff window.

## The trap this spec exists for

The deployed updater keeps a persistent clone at `$OTA_HOME/ota-repo`
and every fetch goes through its stored `origin` remote
(`src/platforms/nextui/update.sh` @ a814bd9: `fetch origin main` :203,
`fetch origin "$head"` :156, `fetch origin "$channel"` :222).
`ota_ensure_repo` returns early when the clone exists (:95–97) and
never touches the remote URL. Changing the `OTA_URL` default alone
repoints only FRESH installs; the deployed Brick would keep fetching
ideal_os forever. The handoff build must reconcile the cached clone's
remote, and the reconcile must ride an update served from the OLD repo.

## Design

### 1. The handoff build (the only product-code change)

- `src/platforms/nextui/update.sh:44` — default `OTA_URL` →
  `https://github.com/jreinach-alt/continuity`.
- `src/platforms/nextui/preflight.sh:22` — default `PF_LSREMOTE_URL` →
  the same URL (the reachability probe should test what the updater
  will actually hit).
- **Origin reconcile** in `ota_ensure_repo`'s reuse branch (:95–97) —
  the single entry point both check modes pass through (`ota_check`
  :196 calls it at :200): when the existing clone's
  `remote get-url origin` differs from `$OTA_URL`, run
  `git remote set-url origin "$OTA_URL"` and log
  `"OTA remote repointed to <url>"`. Idempotent, observable (protocol:
  every action names itself in the log), and it turns ALL future
  repoints into ordinary builds.
- Rebuild the PAK (`scripts/build_pak.sh`) so the shipped copies under
  `build/Continuity.pak/scripts/` pick up both files; version stamp and
  checksums update with it.

Considered and rejected: a device-side `ota_url` state file (analogous
to `ota_channel`). The URL is infrastructure, not device identity — a
stale device file overriding the shipped default is exactly the
stranding class this sprint removes.

### 2. Mirror mechanics

`git clone --bare` from ideal_os, then `git push --mirror` to
continuity. **NOT `clone --mirror`**: GitHub exposes `refs/pull/*` to
mirror clones but rejects pushes to them ("deny updating a hidden
ref"), which poisons the push exit code. A bare clone fetches
heads + tags only, so `push --mirror` from it is clean. Commit SHAs are
preserved, so the channel manifest's pinned commits stay valid on both
repos.

### 3. Sequence (each step gated on the previous)

0. **Preconditions — verify or stop:** PR #4 merged;
   `jreinach-alt/continuity` exists, is PUBLIC (OTA fetches are
   anonymous), and is EMPTY (no README/license/.gitignore — an initial
   commit breaks the mirror push). No branch-protection rules yet
   (they would block the mirror pushes to main).
1. **Mirror** ideal_os → continuity (bare clone + `push --mirror`).
   Verify: default branch is `main` (fix in repo settings if GitHub
   guessed differently), `release/channels.json` readable at main,
   both pinned SHAs fetchable anonymously.
2. **Handoff build** on the session's designated branch: URL defaults +
   origin reconcile + tests + PAK rebuild. PR to ideal_os main (the
   PAK-bearing push auto-escalates the pre-push gate to full — expected,
   not a hang). Owner merges.
3. **Publish** from post-merge main, on a fresh branch:
   `publish_channel.sh nightly <handoff-sha>` then
   `publish_channel.sh stable <handoff-sha>` where `<handoff-sha>` is
   the main merge commit of the handoff PR. The stable guard reads the
   locally-updated manifest, so both release commits stack on one
   branch → one PR. Owner merges. (Publishes take effect only when the
   manifest commit is reachable from origin/main — the PR merge IS the
   publish.)
4. **Re-mirror** so continuity main == ideal_os main byte-for-byte
   (same handoff pins in both manifests). This is the last push
   ideal_os ever receives... and the last one continuity receives from
   a mirror — after this step, continuity is the only home.
5. **On-device (owner):** run the update (tap Continuity → update, or
   reboot). Expected `update.log`: install of the handoff version;
   then on the NEXT check, `OTA remote repointed to .../continuity`
   followed by `Up to date at <handoff-sha>`.
6. **Archive ideal_os (owner; NEVER delete):** an archived repo still
   serves fetches read-only, so its frozen manifest — permanently
   pinning the handoff build — self-repoints any straggler device
   forever. Deleting it would break that safety net.
7. **Housekeeping** (on continuity, ordinary docs PR):
   `release/README.md` notes ideal_os is frozen at the handoff pins;
   README/roadmap record the move; future sessions are created on
   continuity.

Rename variant: if the owner renames ideal_os → continuity in place
instead of creating a new repo, steps 0–1 and 4 vanish (GitHub
redirects old git URLs, so stragglers are covered by the redirect
rather than the frozen manifest) — steps 2–3 and 5 ship unchanged for
URL hygiene.

### 4. What does NOT change

- `Continuity.pak` name, `CONTINUITY_*` variable names, `$OTA_HOME`
  paths, channel identities, the device PAT (scoped to the SAVES repo —
  enrollment and sync never touch the project repo).
- The user's saves repo is completely untouched by this migration.

## Tests

- `tests/unit/nextui/test_ota.sh` — new cases against the existing
  file:// fixture machinery:
  1. Existing clone whose `origin` points at a stale path; run
     `ota_check` with `CONTINUITY_OTA_URL` at the real fixture: check
     succeeds, `remote get-url origin` now matches, repoint line
     logged.
  2. Second check: no repoint line (idempotence).
  3. Matching origin: no repoint line (quiet when nothing to do).
- Existing suite stays green under both privilege passes (full gate).

## Acceptance criteria

1. Fresh anonymous clone of continuity: `git rev-parse main` matches
   ideal_os; manifest and both pinned SHAs fetchable.
2. Handoff build validated under `qemu-aarch64-static` against live
   GitHub with the host git hidden (field-notes protocol): check →
   repoint → up-to-date against the continuity repo.
3. New test_ota.sh cases pass under busybox ash, both privilege passes;
   full gate green at the PAK push (automatic) and at PR creation.
4. On-device, owner-confirmed: `update.log` shows the repoint line and
   `Up to date at <handoff-sha>`; `CONTINUITY_DIAGNOSTIC.txt` preflight
   green with the new ls-remote URL.
5. ideal_os archived only after criterion 4 is confirmed.

## Out of scope

- Renaming code identifiers, the PAK, or on-device paths (the product
  is already named Continuity).
- OnionOS / RetroDeck / Android (no deployed devices to migrate).
- Deleting ideal_os (forbidden — it is the permanent straggler shim).
- Any change to the user's saves repo.
