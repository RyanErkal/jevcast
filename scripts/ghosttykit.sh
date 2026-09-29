#!/bin/bash
# Builds Vendor/GhosttyKit.xcframework, the libghostty library behind the Terminal window,
# from the pinned Ghostty release. Does nothing when that build is already in place.
# Needs Homebrew zig@0.15 (its build links against the macOS 26 and later SDKs) and
# Xcode's Metal Toolchain: xcodebuild -downloadComponent MetalToolchain
#   ZIG  path to a zig 0.15 binary. The default is Homebrew's zig@0.15.
set -euo pipefail
cd "$(dirname "$0")/.."
GHOSTTY_TAG="v1.3.1"
GHOSTTY_COMMIT="332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28"
OUT="Vendor/GhosttyKit.xcframework"
STAMP="Vendor/GhosttyKit.stamp"
# A new commit, build flag, or patch makes a new build.
KEY="$GHOSTTY_COMMIT $(cat scripts/ghosttykit.sh scripts/ghosttykit-libtool.patch | shasum -a 256 | cut -c1-16)"
if [ -d "$OUT" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$KEY" ]; then exit 0; fi

ZIG="${ZIG:-$(brew --prefix zig@0.15 2>/dev/null)/bin/zig}"
if [ ! -x "$ZIG" ]; then echo "zig 0.15 not found. Run: brew install zig@0.15" >&2; exit 1; fi
if ! xcrun metal --version >/dev/null 2>&1; then
  echo "Metal Toolchain not found. Run: xcodebuild -downloadComponent MetalToolchain" >&2; exit 1
fi

# The source is a build cache; a checkout of another commit is replaced.
SRC=".build/ghostty-src"
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$GHOSTTY_COMMIT" ]; then
  rm -rf "$SRC"
  git clone --quiet --depth 1 --branch "$GHOSTTY_TAG" https://github.com/ghostty-org/ghostty.git "$SRC"
  if [ "$(git -C "$SRC" rev-parse HEAD)" != "$GHOSTTY_COMMIT" ]; then
    echo "Ghostty $GHOSTTY_TAG is not commit $GHOSTTY_COMMIT" >&2; exit 1
  fi
fi
# Ghostty's fix for Xcode 26.4 and later (ghostty-org/ghostty be9f1562, on main after 1.3.1): newer
# libtool drops unaligned archive members from Zig with only a warning, which loses the embedding API.
git -C "$SRC" checkout --quiet -- src/build/LibtoolStep.zig
git -C "$SRC" apply "$PWD/scripts/ghosttykit-libtool.patch"
# No Sentry crash handler and no gettext: Jevcast keeps its own crash behaviour and links no LGPL code.
(cd "$SRC" && "$ZIG" build -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false \
  -Dxcframework-target=universal -Dsentry=false -Di18n=false)

# Keep only the macOS slice (arm64 and x86_64). libtool exits 0 even when it drops members, so check the API.
SLICE="$SRC/macos/GhosttyKit.xcframework/macos-arm64_x86_64"
for arch in arm64 x86_64; do
  # grep reads all of nm's output: with -q, nm's SIGPIPE would fail the pipeline.
  if ! nm -arch "$arch" -g "$SLICE/libghostty.a" 2>/dev/null | grep " T _ghostty_surface_new$" >/dev/null; then
    echo "libghostty.a ($arch) has no ghostty_surface_new; the archive merge dropped objects" >&2; exit 1
  fi
done
# Only the embedding header: the libghostty-vt headers beside it are outside the module's umbrella.
HEADERS="$(mktemp -d)"
trap 'rm -rf "$HEADERS"' EXIT
cp "$SLICE/Headers/ghostty.h" "$SLICE/Headers/module.modulemap" "$HEADERS/"
mkdir -p Vendor
rm -rf "$OUT"
xcodebuild -create-xcframework -library "$SLICE/libghostty.a" -headers "$HEADERS" -output "$OUT" >/dev/null
cp "$SRC/LICENSE" Vendor/GhosttyKit-LICENSE.txt
echo "$KEY" > "$STAMP"
echo "Built $OUT from Ghostty $GHOSTTY_TAG"
