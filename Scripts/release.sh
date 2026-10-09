#!/usr/bin/env bash
# Build → sign (Developer ID + Hardened Runtime) → DMG → notarize → staple →
# EdDSA-sign for Sparkle and refresh appcast.xml.
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ SPARKLE SIGNING KEY — DO NOT REGENERATE                                  │
# │                                                                          │
# │ Updates are EdDSA-signed with the private key in the login keychain      │
# │ under the account "ClaudeCockpit". Its public half is embedded in the app   │
# │ as SUPublicEDKey in project.yml:                                         │
# │     qDOgZMTMhl2U8KFaFds14R7tSskZhU0zZPLQmF3WDgQ=                         │
# │                                                                          │
# │ NEVER run `generate_keys` again for this account and NEVER change        │
# │ SUPublicEDKey: every installed copy would reject all future updates.     │
# │ The private half is backed up at                                         │
# │     ~/Documents/SparkleKeys/ClaudeCockpit-sparkle-private-key.txt           │
# └──────────────────────────────────────────────────────────────────────────┘
#
# Usage:   ./Scripts/release.sh <version>
# Example: ./Scripts/release.sh 1.0.0
#
# Reuses Vincent's shared Apple credentials (same account for all Mac apps):
#   - Developer ID Application: Vincent LAURIAT (KFLACS69T9)
#   - notary keychain profile "AppliMacVincentGithub" (apple-id vincent@lauriat.fr)
# If you ever need to recreate the profile:
#   xcrun notarytool store-credentials "AppliMacVincentGithub" \
#     --apple-id "vincent@lauriat.fr" --team-id "KFLACS69T9"
#
# Overridable via env: APP_NAME, SCHEME, PROJECT, SIGNING_IDENTITY, NOTARY_PROFILE
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: $0 <version>   (e.g. $0 1.0.0)" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── Project identity (bootstrap.sh rewrites these when you clone the template) ──
APP_NAME="${APP_NAME:-ClaudeCockpit}"      # PRODUCT_NAME / .app bundle name
SCHEME="${SCHEME:-ClaudeCockpit}"           # macOS scheme (see project.yml)
PROJECT="${PROJECT:-ClaudeCockpit.xcodeproj}"

DMG_SLUG="$(echo "$APP_NAME" | tr -d ' ')"
DMG_VOLNAME="$APP_NAME $VERSION"
RELEASE_DIR="$ROOT/release"
mkdir -p "$RELEASE_DIR"
DMG="$RELEASE_DIR/$DMG_SLUG-$VERSION.dmg"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Vincent LAURIAT (KFLACS69T9)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AppliMacVincentGithub}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
# A squash merge collapses a feature branch into a single commit, so the commit
# count can go DOWN from one release to the next: 1.1.0 shipped as build 44 from
# a 44-commit branch, and main was back to 29 right after the merge. Sparkle
# compares sparkle:version numerically and silently refuses an update whose build
# is not higher, so never emit a number at or below the one already published.
# The committed appcast is the record of what shipped; the working copy may have
# just been overwritten by a previous run of this script.
# The `{ …; } || true` group keeps pipefail from failing the pipeline when HEAD
# has no appcast.xml yet: python already printed 0 in that case, and a trailing
# `|| echo 0` would append a second line ("0\n0") that breaks the -le test.
PUBLISHED="$({ git show HEAD:appcast.xml 2>/dev/null || true; } | python3 -c "
import sys, re
text = sys.stdin.read()
builds = [int(n) for n in re.findall(r'<sparkle:version>\s*(\d+)\s*</sparkle:version>', text)]
print(max(builds) if builds else 0)
")"
PUBLISHED="${PUBLISHED:-0}"
if [ "$BUILD_NUMBER" -le "$PUBLISHED" ]; then
  echo "▶︎ commit count $BUILD_NUMBER is not above published build $PUBLISHED (squash merge); using $((PUBLISHED + 1))"
  BUILD_NUMBER=$((PUBLISHED + 1))
fi

echo "▶︎ Releasing $APP_NAME $VERSION (build $BUILD_NUMBER)"

# 1. Regenerate the Xcode project from project.yml
echo "▶︎ xcodegen generate"
xcodegen generate >/dev/null

# 2. Build Release. CODE_SIGNING_ALLOWED=NO avoids the macOS Sequoia
#    com.apple.provenance xattr that breaks CLI codesign; we sign manually below.
echo "▶︎ xcodebuild Release"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath build \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null
APP="$ROOT/build/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "✗ App not found: $APP" >&2; exit 1; }

# 3. Stage to a clean dir, stripping extended attributes
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGING="$STAGING_DIR/$APP_NAME.app"
ditto --norsrc --noextattr --noacl "$APP" "$STAGING"

# 4. Codesign the app with Hardened Runtime + secure timestamp (retry: Apple TS is flaky)
codesign_ts() {
  local target="$1" i
  for i in 1 2 3 4 5; do
    if codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$target"; then
      return 0
    fi
    echo "  …codesign retry $i/5 (timestamp server) in 5s" >&2
    sleep 5
  done
  echo "✗ codesign failed for $target" >&2
  return 1
}
# Sparkle ships its own helper executables. They must be signed from the most
# deeply nested outwards, otherwise notarization fails late and slowly.
SPARKLE_FW="$STAGING/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  echo "▶︎ codesign Sparkle.framework nested binaries (deepest first)"
  SPARKLE_VER="$SPARKLE_FW/Versions/B"
  codesign_ts "$SPARKLE_VER/Autoupdate"
  codesign_ts "$SPARKLE_VER/XPCServices/Downloader.xpc"
  codesign_ts "$SPARKLE_VER/XPCServices/Installer.xpc"
  codesign_ts "$SPARKLE_VER/Updater.app"
  codesign_ts "$SPARKLE_FW"
fi

echo "▶︎ codesign (Developer ID, Hardened Runtime)"
codesign_ts "$STAGING"
codesign --verify --strict --deep --verbose=1 "$STAGING"

# 5. Build the DMG with a custom Finder layout.
#    dmgbuild writes the .DS_Store itself. The Finder AppleScript it replaces
#    needs Apple Events, which some shells cannot send (osascript is killed with
#    SIGTERM there), and 1.1.3 and 1.1.4 shipped without a layout because of it.
echo "▶︎ build DMG"
DMG_BG="$STAGING_DIR/background.png"
"$ROOT/Scripts/make-dmg-background.swift" "$DMG_BG" >/dev/null

# dmgbuild and its two dependencies, installed once per requirements file into a
# private venv, every wheel checked against its pinned hash.
DMGBUILD_REQS="$ROOT/Scripts/dmgbuild-requirements.txt"
DMGBUILD_VENV="$ROOT/.dmgbuild-venv/$(shasum -a 256 "$DMGBUILD_REQS" | cut -c1-12)"
if [ ! -x "$DMGBUILD_VENV/bin/dmgbuild" ]; then
  echo "▶︎ installing dmgbuild (one-time)"
  rm -rf "$DMGBUILD_VENV"
  python3 -m venv "$DMGBUILD_VENV"
  "$DMGBUILD_VENV/bin/pip" install --quiet --disable-pip-version-check \
    --only-binary=:all: --require-hashes -r "$DMGBUILD_REQS"
fi

# hdiutil detach can fail with "resource busy". Retry, then force.
detach_retry() {
  local mnt="$1" i
  for i in 1 2 3 4 5; do
    if hdiutil detach "$mnt" -quiet; then
      return 0
    fi
    echo "  …hdiutil detach retry $i/5 ($mnt busy) in 2s" >&2
    sleep 2
  done
  hdiutil detach "$mnt" -force -quiet
}
# Detach any volume left mounted by an aborted previous run of this version.
for STALE in "/Volumes/$DMG_VOLNAME" "/Volumes/$DMG_VOLNAME "[0-9]*; do
  if [ -d "$STALE" ]; then
    echo "  …detaching stale volume $STALE" >&2
    detach_retry "$STALE"
  fi
done

rm -f "$DMG"
"$DMGBUILD_VENV/bin/dmgbuild" -s "$ROOT/Scripts/dmg-settings.py" \
  -D app="$STAGING" -D background="$DMG_BG" \
  "$DMG_VOLNAME" "$DMG" 2> >(grep -v "is deprecated" >&2) >/dev/null

# The layout is deterministic now, so its absence is a bug, not a Finder mood.
CHECK_MOUNT="$(hdiutil attach -nobrowse -readonly -noverify -noautoopen "$DMG" | awk -F '\t' 'END {print $NF}')"
LAYOUT_OK=1
for ITEM in .DS_Store .background.png Applications "$APP_NAME.app"; do
  [ -e "$CHECK_MOUNT/$ITEM" ] || { echo "✗ DMG is missing $ITEM" >&2; LAYOUT_OK=0; }
done
codesign --verify --strict --deep "$CHECK_MOUNT/$APP_NAME.app" || LAYOUT_OK=0
detach_retry "$CHECK_MOUNT"
[ "$LAYOUT_OK" = 1 ] || exit 1

# 6. Notarize + staple
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
✗ Notary profile "$NOTARY_PROFILE" not found.
  Create it once (interactive):
    xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --apple-id "vincent@lauriat.fr" --team-id "KFLACS69T9"
  The DMG was built and signed at: $DMG (NOT yet notarized).
EOF
  exit 1
fi
echo "▶︎ notarize (this takes a few minutes)"
# `submit --wait` exits 0 even when Apple returns "Invalid": read the status.
NOTARY_JSON="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
# Any parse problem yields empty fields, so it reaches the "not accepted" path
# below (log + exit 1) instead of a python traceback.
NOTARY_FIELDS="$(printf '%s' "$NOTARY_JSON" | python3 -c "
import sys, json
text = sys.stdin.read()
try:
    d = json.loads(text)
except ValueError:
    # Progress text reached stdout: keep the last single-line JSON object.
    try:
        lines = [l for l in text.splitlines() if l.lstrip().startswith('{')]
        d = json.loads(lines[-1]) if lines else {}
    except ValueError:
        d = {}
if not isinstance(d, dict):
    d = {}
print(d.get('id', ''), d.get('status', ''), sep='\t')
")"
NOTARY_ID="$(printf '%s' "$NOTARY_FIELDS" | cut -f1)"
NOTARY_STATUS="$(printf '%s' "$NOTARY_FIELDS" | cut -f2)"
echo "  notarization $NOTARY_ID: $NOTARY_STATUS"
if [ "$NOTARY_STATUS" != "Accepted" ]; then
  echo "✗ notarization not accepted (status: ${NOTARY_STATUS:-unknown})" >&2
  if [ -n "$NOTARY_ID" ]; then
    xcrun notarytool log "$NOTARY_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fi
  exit 1
fi
echo "▶︎ staple"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# ── Sparkle: EdDSA-sign the DMG and refresh the appcast ──────────────────────
# Keep in step with the Sparkle.framework version pinned in project.yml.
SPARKLE_VERSION="2.10.0"
# sign_update reads the private EdDSA key: never run an unverified download.
# SHA-256 of the exact tarball below; update both lines together.
SPARKLE_TARBALL_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
# One cache directory per version: bumping SPARKLE_VERSION fetches fresh tools
# instead of silently reusing an older cached sign_update.
SPARKLE_TOOLS="$ROOT/.sparkle-tools/$SPARKLE_VERSION"
if [ ! -x "$SPARKLE_TOOLS/bin/sign_update" ]; then
  echo "▶︎ fetching Sparkle $SPARKLE_VERSION tools (one-time)"
  SPARKLE_TARBALL="$STAGING_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -fsSL -o "$SPARKLE_TARBALL" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  ACTUAL_SHA256="$(shasum -a 256 "$SPARKLE_TARBALL" | cut -d ' ' -f1)"
  if [ "$ACTUAL_SHA256" != "$SPARKLE_TARBALL_SHA256" ]; then
    echo "✗ Sparkle tarball checksum mismatch" >&2
    echo "  expected $SPARKLE_TARBALL_SHA256" >&2
    echo "  got      $ACTUAL_SHA256" >&2
    exit 1
  fi
  mkdir -p "$SPARKLE_TOOLS"
  tar -xJf "$SPARKLE_TARBALL" -C "$SPARKLE_TOOLS"
fi

echo "▶︎ EdDSA-signing the DMG for Sparkle"
# Emits: sparkle:edSignature="…" length="<bytes>"
SPARKLE_SIG_LINE="$("$SPARKLE_TOOLS/bin/sign_update" --account "ClaudeCockpit" "$DMG")"

# Sparkle compares <sparkle:version> against the RUNNING app's CFBundleVersion,
# which is an integer here. Putting the marketing version in that element makes
# the comparator read 1.0.0 against 1 and conclude "up to date", so the update
# is never offered. Marketing version goes in shortVersionString only.
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$STAGING/Contents/Info.plist")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$STAGING/Contents/Info.plist")"
PUB_DATE="$(LC_ALL=C date -R)"

# Feeds and downloads live on GitHub Pages (docs/), which stays public when the
# repository goes private; release assets of a private repository do not.
PAGES_URL="https://smartcolibri.github.io/ClaudeCockpit"
DOWNLOADS_DIR="$ROOT/docs/downloads"
mkdir -p "$DOWNLOADS_DIR"
cp "$DMG" "$DOWNLOADS_DIR/"

# Release notes shown inline in Sparkle's update window: an HTML fragment in
# release/sparkle-notes-<version>.html. Without it, fall back to the GitHub tag page.
NOTES_HTML="$RELEASE_DIR/sparkle-notes-$VERSION.html"
if [ -f "$NOTES_HTML" ]; then
  NOTES_ELEMENT="<description><![CDATA[$(cat "$NOTES_HTML")]]></description>"
else
  NOTES_ELEMENT="<sparkle:releaseNotesLink>https://github.com/smartcolibri/ClaudeCockpit/releases/tag/v$VERSION</sparkle:releaseNotesLink>"
fi

echo "▶︎ writing appcast.xml + docs/appcast.xml (sparkle:version=$BUILD_NUMBER, shortVersionString=$VERSION)"
cat > "$ROOT/appcast.xml" <<APPCAST
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ClaudeCockpit</title>
    <link>$PAGES_URL/appcast.xml</link>
    <description>ClaudeCockpit release feed</description>
    <language>en</language>
    <item>
      <title>v$VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      $NOTES_ELEMENT
      <enclosure
        url="$PAGES_URL/downloads/$DMG_SLUG-$VERSION.dmg"
        type="application/octet-stream"
        $SPARKLE_SIG_LINE />
    </item>
  </channel>
</rss>
APPCAST
# Installed copies up to 1.1.5 poll the root file (raw URL); 1.2.0+ poll Pages.
cp "$ROOT/appcast.xml" "$ROOT/docs/appcast.xml"

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo
echo "✅ Built, signed, notarized & stapled: $(basename "$DMG") ($SIZE)"
echo
echo "Publish on GitHub:"
echo "  gh release create v$VERSION \"$DMG\" --title \"v$VERSION\" --notes-file release/release-notes-$VERSION.md"
echo "Then commit appcast.xml, docs/appcast.xml and docs/downloads/ (git add -f: *.dmg is ignored)."
