# One update helper per folder (#117)

Status: revision 1.

## Question

`packaging/updater/macos.sh` takes no lock, so two helpers for the same folder can interleave (#117):

1. **Same `--pid`.** Both stage in `$TARGET/.LoftLine-update-<pid>`. The second one's `rm -rf "$STAGE"` and re-extract can
   overlap the first one's install, which can then move a half-extracted bundle into place. Its signature was checked, but
   the files under it are no longer the ones checked.
2. **Different `--pid`.** If the second helper finds no `LoftLine.app` while the first is between its two renames, it moves
   nothing aside. Then `mv "$STAGE/LoftLine.app" "$APP"` runs after the first one's final rename has put an app back, so it
   nests the staged app inside the installed one (`LoftLine.app/LoftLine.app`) and still exits 0.

`--recover` has the same gap. Run while a helper is between its renames, it finds no app and one `LoftLine.old-<pid>`, and
moves it back under the running install.

It is unlikely: the app starts one helper per quit. But this is the one program that replaces the app, and a broken bundle
is not something `--recover` fixes.

## Decision

**The helper locks the folder that holds the app, with `/usr/bin/lockf`, for its whole run, and so does `--recover`.**

- **`lockf`, not the `mkdir` lock the issue proposes.** The issue assumed macOS ships no `flock`. It ships `/usr/bin/lockf`
  (FreeBSD's), which holds a `flock(2)` lock while a command runs. The kernel drops the lock when its holder exits, however it
  exits, so nothing is left to reclaim. A `mkdir` lock needs a pid file and a stale-lock reclaim, and two helpers reclaiming
  one stale lock can both win.
- **The folder itself is the lock** (`lockf -n -k -t 0 "$TARGET"`). `lockf` can lock a directory. `-n` never creates
  anything and `-k` never removes anything, so nothing is added beside the app. A separate lock file would either stay in the
  folder (often `/Applications`), or be unlinked after use, and then a helper waiting on the unlinked file and a third on a
  new one could both hold "the lock".
- **Taken after the arguments are checked and before the wait for the app to quit.** The run is held whole: wait, copy,
  hash, unpack, check, swap, clean up. With `--recover`, it is taken after the folder is checked.
- **A second helper refuses at once** (`-t 0`). It exits 1 with `another LoftLine update or recovery is running in <folder>;
  not starting a second`, and touches nothing. Waiting would gain nothing: the first helper deletes the shared archive, and
  the second would then find its version no newer than the one just installed.
- **How a shell script holds it.** Bash cannot hold a `flock`, so the helper runs itself again under `lockf`:
  `LOFTLINE_UPDATER_LOCKED=<folder> /usr/bin/lockf -n -k -t 0 <folder> /bin/bash "$0" <its original arguments>`. The copy
  that runs under the lock sees the variable naming its own folder and goes on. It is a child, not an `exec`, so the outer
  run can print its own refusal and, when it never ran the inner one, remove its own temp copy (`loftline-updater-*.sh`). The
  outer run then exits with the inner run's status. `lockf`'s own failures (it cannot open the folder, for example) pass
  through with `lockf`'s message and status.
- **No `lockf`, no lock.** If `/usr/bin/lockf` is not executable, the helper says so and runs unlocked, as today. A missing
  lock tool must not stop every update.

## Test hook

`LOFTLINE_UPDATER_FAULT=pause-between-renames` with `LOFTLINE_UPDATER_FAULT_DIR=<dir>`, tests only like the other
`LOFTLINE_UPDATER_*` switches (the app starts the helper with a fixed environment). After the first rename the helper creates
`<dir>/paused`, then waits up to 30 seconds for `<dir>/resume` and goes on either way. It is never an unbounded wait.

## Tests (`UpdaterHelperTests`)

The first helper is started with `Process`, not `ScriptRunner`, which waits for the end. A `defer` always creates `resume`
and waits for the first helper. Each helper gets its own copy of the archive, because a helper deletes its archive when it
succeeds.

- **A second helper with another `--pid`**, run while the first is paused, exits 1 with the refusal and changes nothing in
  the folder. After `resume`, the first exits 0. There is exactly one `LoftLine.app`, holding the new marker, with no
  `LoftLine.app` inside it, and nothing else in the folder. Before the fix, this second helper nests the bundle.
- **A second helper with the same `--pid`** refuses the same way, and the first one's staging folder is still there.
- **`--recover` while the first is paused** refuses and leaves `LoftLine.old-<pid>` where it is.
- **The lock ends with its holder.** The existing `faultBetweenRenamesLeavesNoAppAndRecoverRestoresTheOldOne` (exit 42, then
  `--recover`) already shows a helper that stopped halfway leaves no lock.
- **No `lockf`.** Not tested by running: the path is checked by reading the script. Removing `/usr/bin/lockf` needs root.

## Docs

- The `macos.sh` header gains the lock and the new test switches.
- `docs/DECISIONS.md`: a new entry, `updater-lock`, and the `updater-binding` entry's "Not done: a lock…" sentence points to
  it.

## Not covered

v0.2.0 is out, and an installed app's helper does the next install. So the lock protects updates done by the release after
the one that ships it.
