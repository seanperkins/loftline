#!/bin/bash
# LoftLine update helper (macOS). The app copies it out of its bundle to a temp folder and starts it once quit is
# committed, because the bundle it came from is about to be replaced. The app has already verified the archive
# (SHA-256 and RSA-4096 signature) and hands over the digest it verified. This binds the install to those bytes, then
# swaps the bundle and optionally relaunches it.
#
#   macos.sh --archive <zip> --sha256 <64 lowercase hex> --version <X.Y.Z> --target <folder holding LoftLine.app> --pid <app pid>
#            [--relaunch 1|0] [--state <state file>]
#   macos.sh --recover <folder holding LoftLine.app>
#   macos.sh --print-requirement      (prints the code requirement an update must satisfy; CI checks it against the real build)
#
# What is installed is exactly what the app approved, and only if our team signed it:
#   1. The archive is copied into a private folder this script owns, and that copy is hashed. A cache file replaced after the
#      app's own check no longer matches --sha256, and one replaced after the copy is not the file that is used.
#   2. That same copy is unpacked, so the bytes hashed are the bytes extracted.
#   3. The unpacked app must satisfy DEFAULT_REQUIREMENT: our bundle identifier, signed by a Developer ID Application
#      certificate of our team. `codesign --verify` alone says only that SOME signature is intact; another app signed by
#      the same team, renamed LoftLine.app, would pass it without the identifier.
#   4. Its version, read from the signed bundle, must be the --version the app offered AND newer than the installed app's. A
#      feed can claim any version; an older validly signed release replayed as an "update", or a download that has waited
#      while a newer version was installed by hand, is refused.
#
# Archives are built with `ditto -c -k --sequesterRsrc --keepParent`, so `ditto -x -k` is the only safe unpacker: it
# restores the mode bits and metadata that the signature covers. The whole bundle is swapped, never its contents.
#
# The swap is TWO renames, not an atomic exchange: the current app moves to LoftLine.old-<pid>, then the staged app
# moves into place. A crash between them leaves no app at the target; `--recover` puts the old one back.
#
# Environment: LOFTLINE_UPDATER_WAIT_SECONDS (default 120) is how long to wait for the app to exit;
# LOFTLINE_UPDATER_SKIP_CODESIGN=1, LOFTLINE_UPDATER_REQUIREMENT (replaces DEFAULT_REQUIREMENT) and
# LOFTLINE_UPDATER_FAULT=between-renames are for tests only: the app starts this script with a clean environment.
set -u
# Character classes such as [a-f] and [A-Za-z] mean different things in different locales (in some, a-f includes A-E), and
# awk reads a decimal comma as the end of a number. Everything below is about bytes and plain ASCII digits.
export LC_ALL=C

ME="$(basename "$0")"
die() { echo "$ME: $*" >&2; exit 1; }

# The copy the app starts is named loftline-updater-<uuid>.sh in the temp folder and removes itself when it ends. The
# repository's macos.sh, and anything else run by hand, is never deleted.
SELF_DELETE=0
case "$ME" in loftline-updater-*.sh) SELF_DELETE=1 ;; esac
WORK=""
cleanup() {
  [ -z "$WORK" ] || rm -rf "$WORK"
  [ "$SELF_DELETE" != 1 ] || rm -f "$0"
}
trap cleanup EXIT

# Our Apple Developer Team ID, public in every signature we make.
TEAM_ID="HH3SJBAS42"
DEFAULT_REQUIREMENT="identifier \"com.seanperkins.loftline\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM_ID\""

ARCHIVE="" SHA256="" VERSION="" TARGET="" PID="" RELAUNCH=0 STATE="" RECOVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --print-requirement) echo "$DEFAULT_REQUIREMENT"; exit 0 ;;
    --archive|--sha256|--version|--target|--pid|--relaunch|--state|--recover)
      [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --archive) ARCHIVE="$2" ;;
        --sha256) SHA256="$2" ;;
        --version) VERSION="$2" ;;
        --target) TARGET="$2" ;;
        --pid) PID="$2" ;;
        --relaunch) RELAUNCH="$2" ;;
        --state) STATE="$2" ;;
        --recover) RECOVER="$2" ;;
      esac
      shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [ -n "$RECOVER" ]; then
  [ -d "$RECOVER" ] || die "not a folder: $RECOVER"
  if [ -e "$RECOVER/LoftLine.app" ]; then
    echo "$ME: LoftLine.app is in place; nothing to restore"
    exit 0
  fi
  olds=()
  for f in "$RECOVER"/LoftLine.old-*; do
    [ -e "$f" ] && olds+=("$f")
  done
  [ ${#olds[@]} -eq 1 ] || die "expected exactly one LoftLine.old-* in $RECOVER, found ${#olds[@]}"
  mv "${olds[0]}" "$RECOVER/LoftLine.app" || die "could not restore ${olds[0]}"
  # What the interrupted update left behind.
  for f in "$RECOVER"/.LoftLine-update-*; do
    [ -e "$f" ] && rm -rf "$f"
  done
  echo "$ME: restored the previous LoftLine.app"
  exit 0
fi

[ -n "$ARCHIVE" ] && [ -n "$SHA256" ] && [ -n "$VERSION" ] && [ -n "$TARGET" ] && [ -n "$PID" ] || die "--archive, --sha256, --version, --target and --pid are required"
case "$SHA256" in *[!0123456789abcdef]*) die "--sha256 must be 64 lowercase hex characters" ;; esac
[ "${#SHA256}" -eq 64 ] || die "--sha256 must be 64 lowercase hex characters"
case "$VERSION" in [0-9]*) ;; *) die "--version must be a version number such as 0.2.1" ;; esac
case "$VERSION" in *[!0-9A-Za-z.+-]*) die "--version must be a version number such as 0.2.1" ;; esac
case "$PID" in ''|*[!0-9]*) die "--pid must be a number" ;; esac
[ "$PID" -ge 1 ] || die "--pid must be a process id"
case "$RELAUNCH" in 0|1) ;; *) die "--relaunch must be 0 or 1" ;; esac
WAIT="${LOFTLINE_UPDATER_WAIT_SECONDS:-120}"
case "$WAIT" in ''|*[!0-9]*) die "LOFTLINE_UPDATER_WAIT_SECONDS must be a number" ;; esac
[ -f "$ARCHIVE" ] || die "archive not found: $ARCHIVE"
[ -d "$TARGET" ] || die "target folder not found: $TARGET"

# The app quits right after starting us. Wait until it has, and swap nothing if it has not: replacing the bundle of a
# running document app would pull it out from under unsaved work.
waited=0
while kill -0 "$PID" 2>/dev/null; do
  [ "$waited" -lt "$WAIT" ] || die "LoftLine (pid $PID) is still running after ${WAIT}s; not replacing it"
  sleep 1
  waited=$((waited + 1))
done

APP="$TARGET/LoftLine.app"
OLD="$TARGET/LoftLine.old-$PID"
STAGE="$TARGET/.LoftLine-update-$PID"
[ ! -e "$OLD" ] || die "$OLD already exists; run '$ME --recover \"$TARGET\"' first"

# A private copy of the archive, hashed and then unpacked, so the bytes that were checked are the bytes that are installed.
# Nothing is staged beside the app until the digest matches.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/loftline-update.XXXXXX")" || die "could not create a private working folder"
cp -- "$ARCHIVE" "$WORK/archive.zip" || die "could not copy $ARCHIVE"
ACTUAL="$(shasum -a 256 "$WORK/archive.zip" | cut -d' ' -f1)"
[ "$ACTUAL" = "$SHA256" ] || die "the archive is not the one the app verified (digest mismatch); not installing"

rm -rf "$STAGE"
mkdir -p "$STAGE" || die "could not create $STAGE"
ditto -x -k "$WORK/archive.zip" "$STAGE" || { rm -rf "$STAGE"; die "could not unpack $ARCHIVE"; }
[ -d "$STAGE/LoftLine.app" ] || { rm -rf "$STAGE"; die "no LoftLine.app in the archive"; }
if [ "${LOFTLINE_UPDATER_SKIP_CODESIGN:-}" != "1" ]; then
  REQUIREMENT="${LOFTLINE_UPDATER_REQUIREMENT:-$DEFAULT_REQUIREMENT}"
  if ! problem="$(codesign --verify --deep --strict "-R=$REQUIREMENT" "$STAGE/LoftLine.app" 2>&1)"; then
    rm -rf "$STAGE"
    die "the new LoftLine.app failed its signature check or is not signed by our team ($problem); keeping the current version"
  fi
fi

# The version comes from the unpacked bundle, which is what the signature covers; the feed's own version is only a claim.
plist_version() {
  local value
  # PlistBuddy reports an unreadable file on stdout, so its exit status decides, not its output.
  value="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null)" || return 1
  printf '%s' "$value"
}
# True when $1 is a newer version than $2: dot-separated numbers, compared as numbers, a suffix after - or + ignored.
newer() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    sub(/[-+].*/, "", a); sub(/[-+].*/, "", b)
    na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb ? na : nb)
    for (i = 1; i <= n; i++) {
      xi = (i <= na ? x[i] + 0 : 0); yi = (i <= nb ? y[i] + 0 : 0)
      if (xi > yi) exit 0
      if (xi < yi) exit 1
    }
    exit 1 }'
}
NEW_VERSION="$(plist_version "$STAGE/LoftLine.app")" || NEW_VERSION=""
[ -n "$NEW_VERSION" ] || { rm -rf "$STAGE"; die "the new LoftLine.app has no readable version; not installing"; }
[ "$NEW_VERSION" = "$VERSION" ] || { rm -rf "$STAGE"; die "the new LoftLine.app is version $NEW_VERSION, not the $VERSION the app offered; not installing"; }
if [ -e "$APP" ] && CURRENT_VERSION="$(plist_version "$APP")" && [ -n "$CURRENT_VERSION" ]; then
  newer "$NEW_VERSION" "$CURRENT_VERSION" || { rm -rf "$STAGE"; die "the new LoftLine.app ($NEW_VERSION) is not newer than the installed one ($CURRENT_VERSION); not installing"; }
fi

if [ -e "$APP" ]; then
  mv "$APP" "$OLD" || { rm -rf "$STAGE"; die "could not move the current LoftLine.app aside"; }
fi
if [ "${LOFTLINE_UPDATER_FAULT:-}" = "between-renames" ]; then
  echo "$ME: injected fault between the two renames" >&2
  exit 42
fi
if ! mv "$STAGE/LoftLine.app" "$APP"; then
  if [ -e "$OLD" ] && ! mv "$OLD" "$APP"; then
    rm -rf "$STAGE"
    die "swap failed and the old app could not be put back; run '$ME --recover \"$TARGET\"'"
  fi
  rm -rf "$STAGE"
  die "swap failed; rolled back to the previous LoftLine.app"
fi

rm -rf "$OLD" "$STAGE"
[ -z "$STATE" ] || rm -f "$STATE"
rm -f "$ARCHIVE"
if [ "$RELAUNCH" = "1" ]; then
  open "$APP" || echo "$ME: updated, but could not relaunch $APP" >&2
fi
exit 0
