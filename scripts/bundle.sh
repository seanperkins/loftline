#!/bin/zsh
# Builds LoftLine in release mode and wraps it into dist/LoftLine.app (ad-hoc signed by default).
# Usage: scripts/bundle.sh [--debug]
# Environment (the release workflow sets all three; a local build sets none):
#   LOFTLINE_VERSION        X.Y.Z, no "v": the version in Info.plist. Required for the release channel. Default 0.0.0.
#   LOFTLINE_CHANNEL        dev (default), rehearsal or release. Written to Info.plist as LoftLineChannel; only
#                           release builds are offered updates.
#   LOFTLINE_SIGN_IDENTITY  a codesign identity; the default "-" signs ad hoc. A real identity adds the hardened runtime
#                           and a secure timestamp, which notarisation requires.
set -euo pipefail
cd "${0:A:h}/.."
CONFIG=release
[[ "${1:-}" == "--debug" ]] && CONFIG=debug

# Checked before anything is built, so a bad release setting fails in a second, not after the build.
CHANNEL="${LOFTLINE_CHANNEL:-dev}"
IDENTITY="${LOFTLINE_SIGN_IDENTITY:--}"
case "$CHANNEL" in
  dev|rehearsal|release) ;;
  *) echo "bundle.sh: LOFTLINE_CHANNEL must be dev, rehearsal or release, not '$CHANNEL'" >&2; exit 2 ;;
esac
if [[ -n "${LOFTLINE_VERSION:-}" && ! "$LOFTLINE_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "bundle.sh: LOFTLINE_VERSION must look like 1.2.3 (no leading v), not '$LOFTLINE_VERSION'" >&2; exit 2
fi
if [[ "$CHANNEL" == release && -z "${LOFTLINE_VERSION:-}" ]]; then
  echo "bundle.sh: LOFTLINE_CHANNEL=release needs LOFTLINE_VERSION" >&2; exit 2
fi
SHORT_VERSION="${LOFTLINE_VERSION:-0.0.0}"
BUILD_VERSION="${LOFTLINE_VERSION:-dev-$(git describe --always 2>/dev/null || echo unknown)}"

source scripts/swiftpm-env.sh
swift build "${SWIFTPM_FLAGS[@]}" -c $CONFIG --product LoftLine
BIN="$(swift build "${SWIFTPM_FLAGS[@]}" -c $CONFIG --show-bin-path)/LoftLine"
APP=dist/LoftLine.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp "$BIN" $APP/Contents/MacOS/LoftLine
cp Resources/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
# The update helper rides inside the bundle, and before any codesign: the signature and notarisation cover the whole
# bundle, so a helper copied in afterwards would break both.
cp packaging/updater/macos.sh $APP/Contents/Resources/updater.sh
chmod 755 $APP/Contents/Resources/updater.sh
# Sample files opened from the Welcome window.
mkdir -p $APP/Contents/Resources/samples
cp samples/*.loftline samples/*.svg samples/*.dxf samples/*.stl $APP/Contents/Resources/samples/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LoftLine</string>
  <key>CFBundleDisplayName</key><string>LoftLine</string>
  <key>CFBundleIdentifier</key><string>com.seanperkins.loftline</string>
  <key>CFBundleExecutable</key><string>LoftLine</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
  <key>LoftLineChannel</key><string>${CHANNEL}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>LoftLine Project</string>
      <key>CFBundleTypeExtensions</key><array><string>loftline</string></array>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>com.seanperkins.loftline.project</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.seanperkins.loftline.project</string>
      <key>UTTypeDescription</key><string>LoftLine Project</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>loftline</string></array>
        <key>public.mime-type</key><string>application/x-loftline+json</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST
# Signs one bundle: sign <bundle> [codesign args]. Ad hoc keeps the local-build commands. A real identity adds the hardened
# runtime and a secure timestamp. Never --deep: it re-signs nested code without its own entitlements, which would strip
# the Quick Look extension's sandbox. Callers sign inside-out (the extension first, the app last).
sign() {
  local target=$1; shift
  if [[ "$IDENTITY" == "-" ]]; then
    codesign -s - --force "$@" "$target"
  else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@" "$target"
  fi
}
# Quick Look thumbnail extension (io-file-thumbnails): built with swiftc, since SwiftPM cannot
# make an .appex. It must be sandboxed, so it is signed with its own entitlements before the app.
# LOFTLINE_NO_QL_EXTENSION=1 skips it.
if [[ -z "${LOFTLINE_NO_QL_EXTENSION:-}" ]]; then
  APPEX=$APP/Contents/PlugIns/LoftLineThumbnail.appex
  mkdir -p $APPEX/Contents/MacOS
  OPT=-O; [[ $CONFIG == debug ]] && OPT=-Onone
  swiftc $OPT -module-name LoftLineThumbnail -parse-as-library -application-extension \
    -target "$(uname -m)-apple-macos14.0" -Xlinker -e -Xlinker _NSExtensionMain \
    -framework QuickLookThumbnailing \
    Extensions/QuickLookThumbnail/ThumbnailProvider.swift Sources/LoftLineApp/Model/QuickLookThumbnailData.swift \
    -o $APPEX/Contents/MacOS/LoftLineThumbnail
  sed -e "s/__SHORT_VERSION__/${SHORT_VERSION}/" -e "s/__VERSION__/${BUILD_VERSION}/" \
    Extensions/QuickLookThumbnail/Info.plist > $APPEX/Contents/Info.plist
  sign $APPEX --entitlements Extensions/QuickLookThumbnail/LoftLineThumbnail.entitlements
fi
app_entitlements=()
# Only a real identity gets the app's own entitlements (the hardened runtime is what makes them necessary), and only once
# a build has proven one is needed.
if [[ "$IDENTITY" != "-" && -f Resources/LoftLine.entitlements ]]; then
  app_entitlements=(--entitlements Resources/LoftLine.entitlements)
fi
sign $APP "${app_entitlements[@]}"
echo "Built $APP ($SHORT_VERSION, $CHANNEL channel)"
