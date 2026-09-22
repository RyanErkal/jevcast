#!/bin/bash
# Builds, signs, notarizes, and packages a release in dist/:
#   Jevcast.app, Jevcast.dmg, Jevcast.dmg.sha256, and jevcast.rb (optional Homebrew cask)
#
# Usage:
#   scripts/release.sh --version X.Y.Z   set the version, raise the build number, and stop
#   scripts/release.sh [--unsigned] [--skip-tests] [--draft-release]
#     --unsigned        ad-hoc signature, no notarization: checks the packaging steps only
#     --skip-tests      do not run swift test first
#     --draft-release   push the tag and create a draft GitHub release with the DMG and checksum
# Environment:
#   SIGNING_IDENTITY  default: the first "Developer ID Application" identity in the keychain
#   NOTARY_PROFILE    notarytool keychain profile (default: jevcast-notary), made once with
#                     xcrun notarytool store-credentials jevcast-notary --apple-id <id> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")/.."
APP_NAME="Jevcast"
DMG="dist/Jevcast.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-jevcast-notary}"
UNSIGNED=0 SKIP_TESTS=0 DRAFT=0
step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      [[ "${2:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version must look like 1.2.3"
      source scripts/version.env
      sed -i '' -e "s/^VERSION=.*/VERSION=$2/" -e "s/^BUILD=.*/BUILD=$((BUILD + 1))/" scripts/version.env
      echo "scripts/version.env: $2 (build $((BUILD + 1))). Add a CHANGELOG.md section for $2, commit, then run scripts/release.sh."
      exit 0 ;;
    --unsigned) UNSIGNED=1; shift ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --draft-release) DRAFT=1; shift ;;
    *) fail "Unknown option: $1" ;;
  esac
done
source scripts/version.env
TAG="v$VERSION"

if [ "$UNSIGNED" = 1 ]; then
  IDENTITY="-"
else
  IDENTITY="${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
  [ -n "$IDENTITY" ] || fail "No Developer ID Application certificate in the keychain. Create one at developer.apple.com (Certificates, Identifiers & Profiles), or pass --unsigned for a local check."
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "No notarytool profile named $NOTARY_PROFILE. Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <team-id>"
  [ -z "$(git status --porcelain)" ] || fail "The working tree has uncommitted changes. Commit them so the release matches a commit."
  grep -q "^## \[$VERSION\]" CHANGELOG.md || fail "CHANGELOG.md has no \"## [$VERSION]\" section."
fi

if [ "$SKIP_TESTS" = 0 ]; then step "Tests"; swift test 2>&1 | tail -3; fi

step "Build $APP_NAME $VERSION ($BUILD), signed with: $IDENTITY"
SIGNING_IDENTITY="$IDENTITY" scripts/build.sh >/dev/null
APP="dist/$APP_NAME.app"
BIN="$APP/Contents/MacOS/JevLauncher"
# This lipo checks one architecture per call.
for arch in arm64 x86_64; do lipo "$BIN" -verify_arch "$arch" || fail "The binary has no $arch slice."; done
codesign --verify --strict --deep "$APP"

notarize() {
  step "Notarize $1"
  local out id
  out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
  id="$(printf '%s' "$out" | plutil -extract id raw -o - - 2>/dev/null || true)"
  if ! printf '%s' "$out" | grep -q '"status" *: *"Accepted"'; then
    printf '%s\n' "$out" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fail "Notarization of $1 was not accepted."
  fi
}

if [ "$UNSIGNED" = 0 ]; then
  # The app carries its own ticket, so a copy dragged out of the DMG opens offline too.
  ZIP="dist/.notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

step "Disk image"
STAGE="$(mktemp -d dist/.dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
if [ "$UNSIGNED" = 0 ]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  step "Gatekeeper checks"
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  xcrun stapler validate "$APP"
  xcrun stapler validate "$DMG"
fi

( cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
SHA="$(cut -d' ' -f1 "$DMG.sha256")"

step "Done"
echo "App:      $APP"
echo "DMG:      $DMG ($(du -h "$DMG" | cut -f1))"
echo "SHA-256:  $SHA"
if [ "$UNSIGNED" = 1 ]; then
  echo "Unsigned check only. Gatekeeper blocks this DMG on other Macs. Do not publish it."
  exit 0
fi

sed -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
  packaging/homebrew/jevcast.rb > dist/jevcast.rb
echo "Cask:     dist/jevcast.rb (optional; publish only after the GitHub release is public)"

if [ "$DRAFT" = 1 ]; then
  step "Draft GitHub release $TAG"
  NOTES="$(mktemp)"
  awk -v v="$VERSION" 'index($0, "## [" v "]") == 1 {on=1; next} on && /^## / {exit} on {print}' CHANGELOG.md > "$NOTES"
  git tag -a "$TAG" -m "$APP_NAME $VERSION" 2>/dev/null || echo "Tag $TAG already exists."
  git push origin "$TAG"
  gh release create "$TAG" "$DMG" "$DMG.sha256" --draft --verify-tag --title "$APP_NAME $VERSION" --notes-file "$NOTES"
  rm -f "$NOTES"
  echo "Draft created. Check it on GitHub, then publish it."
fi
