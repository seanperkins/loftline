# One update helper per folder (#117)

Status: revision 2, after the round 1 panel (two GPT-6 seats, an Opus skeptic, a Sonnet simplifier). Changes: fail closed
without `lockf`, keep the original arguments, synchronous tests instead of a pause hook, refuse to install beside a
leftover `LoftLine.old-*`.

## Question

`packaging/updater/macos.sh` takes no lock, so two helpers for the same folder can interleave (#117):

1. **Same `--pid`.** Both stage in `$TARGET/.LoftLine-update-<pid>`. The second one's `rm -rf "$STAGE"` and re-extract can
   overlap the first one's install, which can then move a half-extracted bundle into place.
2. **Different `--pid`.** While the first is between its two renames, the second finds no `LoftLine.app`, moves nothing
   aside and installs. The first then moves its staged app into the installed one (`LoftLine.app/LoftLine.app`) and exits 0.

`--recover` has the same gap. Run while a helper is between its renames, it finds no app and one `LoftLine.old-<pid>`, and
moves it back under the running install.

One more case needs no second helper. A helper that stopped between its renames (killed, or the Mac lost power) leaves no
app and a `LoftLine.old-<pid>`. The next helper, started from a reinstalled app with another pid, finds no app, so it skips
the version check and installs, and the old bundle is left beside it.

It is unlikely: the app starts one helper per quit. But this is the one program that replaces the app.

## Decision

**The helper locks the folder that holds the app with `/usr/bin/lockf` for its whole run, and so does `--recover`.**

- **`lockf`, not the issue's `mkdir` lock.** The issue assumed macOS ships no `flock`. It ships `/usr/bin/lockf`, which holds
  a `flock(2)` lock while a command runs. The kernel drops the lock when the holder exits, however it exits, so there is no
  stale lock to reclaim. A `mkdir` lock needs a pid file and a reclaim step, and two helpers reclaiming one stale lock can
  both win.
- **The folder itself is the lock:** `lockf -n -k -t 0 "$TARGET"`. `lockf` can lock a directory. With `-n` it never creates
  anything and with `-k` it never removes anything, so nothing is added beside the app. A lock file would either stay in the
  folder, often `/Applications`, or be unlinked after use. Unlinking lets a helper waiting on the old file and a third on a
  new one both hold "the lock".
- **The helper runs itself again under `lockf`.** A shell cannot hold a lock across its own commands with the
  `lockf file command` form. This Mac's `lockf` also has an fd form (`lockf -s fd`) that can, but its man page is dated
  November 2023, after macOS 14 shipped. The app supports macOS 14, and the helper that ships performs the next update, so
  the helper uses only the long-standing form.
  - The original arguments are saved before the parse loop shifts them away. Every update passes them, so the array is
    never empty: bash 3.2 under `set -u` stops on an empty one.
  - The outer run executes `LOFTLINE_UPDATER_LOCKED=1 /usr/bin/lockf -n -k -t 0 <folder> /bin/bash "$0" <saved arguments>`.
  - The inner run sees `LOFTLINE_UPDATER_LOCKED=1` and goes on. The variable is an internal re-entry marker, like the other
    `LOFTLINE_UPDATER_*` switches. The app starts the helper with a fixed environment, so it cannot arrive from the app.
  - The outer run is a child, not an `exec`, so it can print its own refusal. Its existing EXIT trap then removes the temp
    copy (`loftline-updater-*.sh`) whether or not the inner run started. Removing it twice is harmless, because bash keeps
    reading a deleted script.
  - The outer run exits with `lockf`'s status: the inner run's status, `lockf`'s own failure status, or 70 if the inner run
    was killed. Status 75 (already locked) becomes exit 1 with `another LoftLine update or recovery is running in <folder>;
    not starting a second`.
- **Taken after the arguments are checked and before the wait for the app to quit.** The lock covers the whole run: wait,
  copy, hash, unpack, check, swap, clean up. With `--recover` it is taken after the folder is checked.
- **A second helper refuses at once** (`-t 0`) and touches nothing. Waiting would gain nothing. The first helper deletes the
  shared archive, and the second would then find its version no newer than the one just installed.
- **Fail closed.** If `/usr/bin/lockf` is not executable, the helper refuses (`cannot lock <folder>: /usr/bin/lockf is
  missing; not updating`). `lockf` is on the sealed system volume, so this only guards against the impossible. If `lockf`
  cannot open the folder (exit 73: a folder the user can write but not read), the update is refused with `lockf`'s message.
  An unlocked fallback would bring back the race this closes.
- **A leftover old bundle blocks the install.** If there is no `LoftLine.app` and a `LoftLine.old-*` exists, the helper
  refuses with `an earlier update stopped halfway; run '<helper> --recover "<folder>"' first`. This check sits under the lock,
  next to the existing check for `LoftLine.old-<pid>`.

Known limit: the lock lives in the `lockf` process. If that process alone is killed, its helper runs on unlocked. A logout
or restart signals both.

## Tests (`UpdaterHelperTests`)

The tests are synchronous. Where the first helper pauses tells the second nothing, because the lock covers the whole run.

- **A held folder refuses every entry.** The test holds the folder (`/usr/bin/lockf -n -k -t 0 <target> <helper …>`) and runs
  the helper as that command. Cases:
  - an update with another `--pid`;
  - an update with the same `--pid` and its staging folder already present;
  - `--recover` on a hand-built mid-swap folder (no app, one `LoftLine.old-<pid>`).

  Each must exit 1 with the refusal, and the folder's entries and markers must not change. Before the fix, each one runs and
  changes the folder.
- **The helper holds the lock while it works.** A stub `open` (the existing `stubOpen`) runs
  `/usr/bin/lockf -n -k -t 0 <target> /usr/bin/true` during a `--relaunch 1` update and records its status. It must be 75.
  Before the fix it is 0.
- **The lock ends with its holder.** The existing `faultBetweenRenamesLeavesNoAppAndRecoverRestoresTheOldOne` (exit 42,
  then `--recover`) already proves that a helper that stopped halfway leaves no lock.
- **The temp copy, run the app's way.** The script is copied to `loftline-updater-<uuid>.sh` and run once to a successful
  install and once against a held folder. Both runs must give the expected status and leave the copy deleted.
- **Leftover old bundle.** With no app and a `LoftLine.old-123`, an update with pid 456 exits 1 with the recover message, and
  the folder is unchanged.

## Docs

- The `macos.sh` header describes the lock.
- `docs/DECISIONS.md` gains a new `updater-lock` entry, and the `updater-binding` entry's "Not done: a lock…" sentence is
  edited to point to it.

## Not covered

v0.2.0 is out, and an installed app's helper performs the next install. So the lock protects only updates done by releases
after the one that ships it.
