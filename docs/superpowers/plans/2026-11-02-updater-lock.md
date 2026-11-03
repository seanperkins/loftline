# One Update Helper Per Folder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `macos.sh` locks the folder holding the app for its whole run (update and `--recover`), and refuses to install beside a leftover `LoftLine.old-*`.

**Architecture:** The helper re-runs itself as the command of `/usr/bin/lockf -n -k -t 0 <folder>`, marked by `LOFTLINE_UPDATER_LOCKED=1`; status 75 becomes a refusal.

**Tech Stack:** bash 3.2, `/usr/bin/lockf`, swift-testing.

**Spec:** `docs/specs/2026-11-02-updater-lock-design.md` (revision 2)

## Global Constraints

- Refusal text: `another LoftLine update or recovery is running in <folder>; not starting a second` (exit 1).
- Missing lockf: `cannot lock <folder>: /usr/bin/lockf is missing; not updating` (exit 1).
- Leftover old bundle: `an earlier update stopped halfway; run '$ME --recover "<folder>"' first` (exit 1).
- Nothing is created in the target folder by the lock (`-n -k`).
- Only the `lockf file command` form; never the fd form.

## Review Focus

- An app-named temp copy (`loftline-updater-*.sh`) refused by the lock: the copy must still be removed.
- `--state` absent (the app never passes it): saved arguments still re-run correctly.
- Paths with spaces through the re-run (existing `handlesSpacesInEveryPath` must stay green).
- A helper killed between renames releases the lock (existing fault test).
- `--recover` on a folder with the app in place still exits 0 under the lock.

---

### Task 1: Lock tests, then the lock

**Files:**
- Modify: `Tests/LoftLineAppTests/UpdaterHelperTests.swift`
- Modify: `packaging/updater/macos.sh`

- [ ] **Step 1: Write the failing tests**
  - `static func runHolding(_ target: URL, _ args: [String], env:) -> Output`: runs `/usr/bin/lockf -n -k -t 0 <target> <repo>/packaging/updater/macos.sh <args>` through `ScriptRunner.exec`.
  - `aHeldFolderRefusesAnUpdateWithAnotherPid`, `...WithTheSamePidAndItsStagingFolder`, `...RefusesRecoverMidSwap`: one parameterised or three tests; each asserts status 1, `err` contains `another LoftLine update or recovery is running in`, and `names(in:)` plus markers unchanged.
  - `theHelperHoldsTheFolderWhileItWorks`: a stub `open` that runs `/usr/bin/lockf -n -k -t 0 '<target>' /usr/bin/true; echo $? >> <log>`; after a `--relaunch 1` update the log reads `75`.
  - `theAppsTempCopyRemovesItselfAfterAnInstallAndAfterARefusal`: copies the script to `<dir>/loftline-updater-<uuid>.sh` (0700); runs it to a successful install (status 0) and, as a held folder's command, to a refusal (status 1); the copy is gone after each.
  - `refusesToInstallBesideALeftoverOldBundle`: no app, a `LoftLine.old-123`; update with `deadPID()` exits 1, `err` contains `an earlier update stopped halfway`, folder unchanged.

- [ ] **Step 2: Run them, expect RED**
  Run: `scripts/test.sh --filter UpdaterHelper`
  Expected: the new tests fail (held-folder runs exit 0 and change the folder; the probe logs 0; leftover install exits 0).

- [ ] **Step 3: Implement in `macos.sh`**
  - Save `ORIGINAL_ARGS=("$@")` before the parse loop.
  - `lock_folder <folder>`: if `LOFTLINE_UPDATER_LOCKED` is `1`, return. If `/usr/bin/lockf` is not executable, die with the missing text. Else run `LOFTLINE_UPDATER_LOCKED=1 /usr/bin/lockf -n -k -t 0 "$1" /bin/bash "$0" "${ORIGINAL_ARGS[@]}"`, capture `$?` at once, die with the refusal on 75, else `exit` with it.
  - Call it in `--recover` after `[ -d "$RECOVER" ]`, and in the update path after the argument checks, before the pid wait.
  - After the `$OLD` check: if `$APP` is absent and any `$TARGET/LoftLine.old-*` exists, die with the leftover text.
  - Header: describe the lock and the marker.

- [ ] **Step 4: Run, expect GREEN**
  Run: `scripts/test.sh --filter UpdaterHelper`
  Expected: all UpdaterHelper tests pass.

- [ ] **Step 5: Commit** `fix(updater): one helper per folder, locked with lockf (#117)`

### Task 2: Docs and full suite

**Files:** `docs/DECISIONS.md`

- [ ] **Step 1:** Add `updater-lock` entry; edit `updater-binding`'s "Not done: a lock…" sentence to point to it.
- [ ] **Step 2:** Run `scripts/build.sh` then `scripts/test.sh`. Expected: every "Test run with N tests" line passed.
- [ ] **Step 3: Commit** `docs: updater-lock decision (#117)`
