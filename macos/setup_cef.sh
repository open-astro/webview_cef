#!/usr/bin/env bash
#
# Fetch + stage the CEF binaries the macOS plugin needs. The framework, the
# static wrapper lib, and the two .xcframeworks are git-ignored (hundreds of MB),
# so this script reproduces them from the upstream Spotify CDN distribution. Run
# it once after cloning (and whenever CEF_VERSION below changes) before building
# the macOS plugin via either Swift Package Manager or CocoaPods.
#
#   ./macos/setup_cef.sh            # host arch (arm64 or x86_64)
#   CEF_ARCH=macosx64 ./macos/setup_cef.sh
#
# Requires: curl, cmake, Xcode command-line tools (xcodebuild).
set -euo pipefail

# Keep this in lockstep with third/download.cmake (Windows/Linux) so every
# platform ships the same Chromium.
CEF_VERSION="149.0.4+g2f1bfd8+chromium-149.0.7827.156"

case "${CEF_ARCH:-}" in
  macosx64|macosarm64) ARCH="$CEF_ARCH" ;;
  "") [ "$(uname -m)" = "arm64" ] && ARCH="macosarm64" || ARCH="macosx64" ;;
  *) echo "CEF_ARCH must be macosx64 or macosarm64" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CEF_DIR="$SCRIPT_DIR/webview_cef/third/cef"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

url_version="$(printf '%s' "$CEF_VERSION" | sed 's/+/%2B/g')"
tarball="cef_binary_${url_version}_${ARCH}.tar.bz2"
url="https://cef-builds.spotifycdn.com/${tarball}"

echo "==> Downloading CEF ${CEF_VERSION} (${ARCH})"
curl -fL --retry 3 -o "$WORK/cef.tar.bz2" "$url"

echo "==> Extracting"
tar -xjf "$WORK/cef.tar.bz2" -C "$WORK"
DIST="$(find "$WORK" -maxdepth 1 -type d -name 'cef_binary_*' | head -1)"
[ -n "$DIST" ] || { echo "extraction failed" >&2; exit 1; }

echo "==> Building libcef_dll_wrapper.a"
proj_arch="$([ "$ARCH" = "macosarm64" ] && echo arm64 || echo x86_64)"
( cd "$DIST" && mkdir -p build && cd build \
    && cmake -G Xcode -DPROJECT_ARCH="$proj_arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 .. >/dev/null \
    && xcodebuild -project cef.xcodeproj -target libcef_dll_wrapper -configuration Release -arch "$proj_arch" >/dev/null )
WRAPPER="$DIST/build/libcef_dll_wrapper/Release/libcef_dll_wrapper.a"
[ -f "$WRAPPER" ] || { echo "wrapper build failed" >&2; exit 1; }

echo "==> Staging headers + binaries into $CEF_DIR"
rm -rf "$CEF_DIR/include" "$CEF_DIR/Chromium Embedded Framework.framework" \
       "$CEF_DIR/libcef_dll_wrapper.a" "$CEF_DIR"/*.xcframework
mkdir -p "$CEF_DIR"
cp -R "$DIST/include" "$CEF_DIR/include"
cp "$WRAPPER" "$CEF_DIR/libcef_dll_wrapper.a"

# CEF ships a flat framework; macOS requires a *versioned* bundle for Xcode to
# embed it, so rebuild it in Versions/A layout with the usual top-level symlinks.
echo "==> Versionizing the framework"
FW="$CEF_DIR/Chromium Embedded Framework.framework"
BIN="Chromium Embedded Framework"
SRC_FW="$DIST/Release/$BIN.framework"
rm -rf "$FW"
mkdir -p "$FW/Versions/A"
cp -R "$SRC_FW/$BIN" "$FW/Versions/A/$BIN"
cp -R "$SRC_FW/Resources" "$FW/Versions/A/Resources"
cp -R "$SRC_FW/Libraries" "$FW/Versions/A/Libraries"
ln -s "A" "$FW/Versions/Current"
ln -s "Versions/Current/$BIN" "$FW/$BIN"
ln -s "Versions/Current/Resources" "$FW/Resources"
ln -s "Versions/Current/Libraries" "$FW/Libraries"

# Swift Package Manager binary targets must be .xcframeworks.
echo "==> Wrapping as .xcframeworks (for Swift Package Manager)"
( cd "$CEF_DIR"
  xcodebuild -create-xcframework -framework "$BIN.framework" -output "$BIN.xcframework" >/dev/null
  xcodebuild -create-xcframework -library libcef_dll_wrapper.a -output libcef_dll_wrapper.xcframework >/dev/null )

echo "==> Done. CEF ${CEF_VERSION} (${ARCH}) staged in webview_cef/third/cef"
