# NextUI / TrimUI Brick — Field Notes

Hardware-validated facts from the Phase 1 bring-up (2026-07-06/07).
Every item here cost real debugging time; read this before touching the
NextUI platform code. Companion docs:
`docs/design/nextui-tool-pak-research.md` (PAK mechanics, upstream-cited),
`docs/design/pak-launch-failure-findings.md` (launch-chain forensics),
`docs/sprints/sprint-1.1-1.3-summary.md` (defect history).

## Delivery pipeline (how bits reach the card)

- **Never distribute from a git working tree.** The user's clone predated
  `.gitattributes` with `autocrlf=true`: files untouched by later commits
  kept CRLF forever while changed files were re-smudged to LF — a mixed
  tree that `git status` calls clean. Cost three device round-trips.
- **Ship zips built here**: `scripts/build_pak.sh` → verify → zip named
  `Continuity.pak-<version>.zip`. Browser download → Windows Extract-All
  → Explorer copy → exFAT preserves bytes end-to-end.
- **Version stamps are minute-granular** (`0.1.0-YYYYMMDD-HHMM`) and shown
  on-screen + in `launch.log`. Two same-day builds once got confused;
  never again.
- **The card must be ejected properly** — exFAT + Windows lazy writes can
  leave large binaries truncated. Preflight's checksum verification
  catches this and says so on screen.
- The user's working copy lives in **OneDrive on Windows** — a known
  source of stale reads and git index weirdness. Not our problem anymore
  (zip delivery), but never ask them to copy from the tree.

## Filesystem: exFAT (not FAT32 as older docs said)

Behaviorally identical for us: no permission bits (the device mounts
everything executable — proven by every stock pak), **no symlinks**
(ship real file copies; git's `git-remote-https → git-remote-http`
symlink must be materialized), coarse mtimes, no atomic rename
guarantees worth trusting. `sync` after every important write.

## The bundled git (the hard-won part)

- Layout must mirror a real install: `bin/git` AND
  `libexec/git-core/{git, git-remote-http, git-remote-https}` AND
  `share/ca-bundle.crt` AND `share/templates/`.
- **git spawns transport helpers as `git remote-https <remote> <url>`**
  (`transport-helper.c`, `git_cmd=1`) — the exec path must contain **git
  itself**, or every https operation fails with the misleading
  `unable to find remote helper for 'https'` (`silent_exec_failure`).
  Both helper names are required (transport re-invokes the canonical
  `http` name).
- Env wiring (exported by `pal_nextui.sh`, re-defaulted as belts in
  `esd_import` and the preflight probe): `GIT_EXEC_PATH`,
  `GIT_SSL_CAINFO`, `GIT_TEMPLATE_DIR`, plus PAK `bin/` on `PATH`.
- Hang-proofing for headless git: `GIT_TERMINAL_PROMPT=0` (a failed
  credential helper otherwise prompts /dev/tty forever — no keyboard
  exists) and `GIT_HTTP_LOW_SPEED_LIMIT/TIME` (abort stalled transfers).
- CA bundle is the **pristine Mozilla bundle from curl.se** — never the
  build host's system bundle (it contains the CI proxy's CA).
- Build: `scripts/build_git.sh` — plain `gcc-aarch64-linux-gnu`, static
  zlib/openssl(3.0 LTS)/curl/git, canonical non-GitHub mirrors
  (github.com release downloads are blocked from the build container).

## Validation protocol (before ANY binary ships)

1. `scripts/build_pak.sh` (writes version, channel, checksums manifest).
2. qemu smoke: the shipped `bin/git` under `qemu-aarch64-static` runs
   `--version`, `init`, and a **live GitHub clone**.
3. **Hide the host git** (`mv /usr/bin/git`) during validation — the
   `git remote-https` re-invocation silently falls through to the system
   git otherwise, which once produced a false "validated" stamp.
4. Shim every ARM→ARM exec edge explicitly (host shell scripts named
   `git`, `git-remote-http(s)` that qemu-wrap the PAK binaries).
   **Do not use binfmt_misc**: a one-byte mask mistake made every
   process spawn in the container loop through qemu (recovered only via
   direct procfs writes).
5. Full suite (`scripts/test.sh`) — all tests run under `busybox ash`.

## Boot & runtime environment

- Only boot hook: the single user script `$USERDATA_PATH/auto.sh`
  (tg5040 → `/mnt/SDCARD/.userdata/tg5040/auto.sh`). **No per-PAK
  auto.sh exists** — Sprint 1.1's draft was wrong about this.
- The daemon must be fully detached: `</dev/null >/dev/null 2>&1 &`.
- **WiFi races auto.sh at boot** — `wifi_init.sh start` is backgrounded
  seconds earlier. The daemon waits (bounded, 12×5s) for
  `pal_is_online` before boot enrollment.
- A wrong device clock breaks TLS certificate validation; preflight
  checks the year and says so on screen.
- MinUI env available to paks: `PLATFORM=tg5040`, `SDCARD_PATH`,
  `USERDATA_PATH`, `DEVICE=brick`, PATH includes `$SYSTEM_PATH/bin`
  (hence bare `show2.elf`). We default every one we use.

## Display (show2.elf) and input

- `show2.elf` renders ONE text line; args must be `--key=value` (a space
  after the key silently discards the value); `--timeout=N` or it blocks
  forever; daemon mode + FIFO `/tmp/show2.fifo` for live updates;
  1024px panel fits ~64 chars at fontsize 28.
- Buttons via `/dev/input/js0`, 8-byte js_event records; tg5040 numbers:
  **B=0, A=1, Y=2, X=3** (upstream `platform.h` JOY_* — includes the
  official "swapped in first release" comment). One persistent open
  (joydev replays init events per open; init flag 0x80 must be filtered).
  Unmapped numbers are logged so new devices self-document.

## Diagnostics contract (keep these working)

- `<PAK>/launch.log` — one build-stamped line per launch, unconditional.
- `CONTINUITY_DIAGNOSTIC.txt` at SD root — full preflight report
  (clock, CRLF, git, helper exec, checksums, network, live TLS probe,
  masked setup.json, buttons, space).
- `.continuity/enroll.log`, `.continuity/continuity.log`,
  `.continuity/update.log` — enrollment / daemon / OTA.
- On-screen: every failure names itself + build stamp; X/Y replays the
  log during enrollment; B cancels (setup.json is preserved for retry).

## OTA (Sprint 1.6)

- `scripts/update.sh`: persistent sparse clone (`--filter=blob:none`,
  fallback plain shallow) of the public project repo at
  `.continuity/ota-repo`, sparse path `build/Continuity.pak` — an update
  is "sync the tracked PAK folder". Channel = `ota_channel.txt` (written
  by build from the source branch). Verify fetched tree (CRLF +
  checksums) before staged copy; binaries only rewritten when size
  differs; commit recorded in `.continuity/.ota_commit`.
- UI: on pak tap when enrolled — "Update available: X installs, B skips".
  Changes take effect next boot. `CONTINUITY_OTA=0` kill switch.
- **Card swaps remain necessary only for**: a broken update.sh/launch.sh
  chain (bootstrap), and binary-toolchain changes too risky to trust to
  a partial copy.

## SRAM flush timing (why "save and keep playing" syncs nothing)

`minarch` writes the `.srm` file ONLY at: game exit (`Core_quit`,
minarch.c:6146), device sleep (`Menu_beforeSleep`, :6269), and MENU-button
press (:8492). **There is no periodic in-game SRAM flush** — an in-game
save updates emulated memory only. The sync story for users is therefore:
"your save reaches the cloud when you take a break" (open the menu, sleep
the device, or quit the game); the daemon's 30s poll picks the file up
from there. Any smoke test must include a MENU press or game exit between
saving and expecting a commit.

## Security notes

- PAT: fine-grained, ONE repo (the saves repo), Contents read/write
  only. Never logged — preflight masks it to a length. Stored on card:
  scope IS the security boundary.
- OTA fetches the PROJECT repo anonymously (it is public — verified from
  the device itself by the preflight ls-remote probe).
