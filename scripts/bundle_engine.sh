#!/usr/bin/env bash
# Build a self-contained Minutes.app (standalone Python + MLX engine inside) and package it as a DMG.
#
#   scripts/bundle_engine.sh            -> dist/Minutes-<version>-arm64.dmg
#
# Needs: macOS on Apple Silicon, Xcode, xcodegen, uv, gh (or curl) for the Python download.
# Set SIGN_IDENTITY="Developer ID Application: ..." to sign for distribution; defaults to ad-hoc ("-").
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
CACHE="$BUILD/cache"
PY_SERIES="3.12"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
mkdir -p "$BUILD" "$DIST" "$CACHE"

step() { printf '\n==> %s\n' "$*"; }

step "Building Minutes.app (Release)"
(cd "$ROOT/app" && xcodegen generate --quiet)
xcodebuild -project "$ROOT/app/Minutes.xcodeproj" -scheme Minutes -configuration Release \
  -derivedDataPath "$BUILD/xcode" -destination 'platform=macOS,arch=arm64' build -quiet
APP_SRC="$BUILD/xcode/Build/Products/Release/Minutes.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SRC/Contents/Info.plist")"
STAGE="$BUILD/stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
APP="$STAGE/Minutes.app"
ditto "$APP_SRC" "$APP"

step "Fetching standalone Python $PY_SERIES (python-build-standalone)"
PATTERN="cpython-${PY_SERIES//./\\.}\\.[0-9]+\\+[0-9]+-aarch64-apple-darwin-install_only_stripped\\.tar\\.gz$"
PATTERN="${PATTERN//\\+/(\\+|%2B)}"
if command -v gh >/dev/null; then
  ASSETS="$(gh api repos/astral-sh/python-build-standalone/releases/latest -q '.assets[].browser_download_url')"
else
  ASSETS="$(curl -fsSL https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest | grep -Eo 'https://[^"]+')"
fi
URL="$(echo "$ASSETS" | grep -E "$PATTERN" | head -1 || true)"
[ -n "$URL" ] || { echo "could not find a standalone Python build"; exit 1; }
TARBALL="$CACHE/$(basename "${URL//%2B/+}")"
[ -f "$TARBALL" ] || curl -fL --progress-bar -o "$TARBALL" "$URL"

ENGINE="$APP/Contents/Resources/engine"
mkdir -p "$ENGINE"
tar -xzf "$TARBALL" -C "$ENGINE"   # -> $ENGINE/python
PY="$ENGINE/python/bin/python3"

step "Installing the engine into the bundled Python"
# parakeet-mlx only uses librosa.filters.mel; ship a NumPy shim instead of librosa + scipy/sklearn/numba (~250 MB).
REQS="$BUILD/engine-requirements.txt"
(cd "$ROOT/engine" && uv export --frozen --no-dev --no-emit-project --no-hashes --prune librosa -o "$REQS" --quiet)
uv pip install --python "$PY" --break-system-packages --no-deps --quiet -r "$REQS"
uv pip install --python "$PY" --break-system-packages --no-deps --quiet "$ROOT/engine"
SITE="$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
cp -R "$ROOT/engine/bundle_shims/librosa" "$SITE/librosa"

step "Trimming the runtime"
PYLIB="$ENGINE/python/lib/python$PY_SERIES"
rm -rf "$ENGINE/python/include" "$ENGINE/python/share" \
  "$PYLIB/idlelib" "$PYLIB/tkinter" "$PYLIB/turtledemo" "$PYLIB/ensurepip" "$PYLIB/test" \
  "$PYLIB"/lib-dynload/_tkinter* "$ENGINE"/python/lib/libtcl* "$ENGINE"/python/lib/libtk* \
  "$ENGINE"/python/lib/tcl* "$ENGINE"/python/lib/tk* "$ENGINE"/python/lib/itcl* "$ENGINE"/python/lib/thread*
find "$ENGINE" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "$PYLIB/site-packages" -type d \( -name tests -o -name test \) -path "*site-packages/*/*" -prune -exec rm -rf {} + 2>/dev/null || true

step "Smoke-testing the bundled engine"
"$PY" -c "import minutes_engine.server, minutes_engine.asr, minutes_engine.llm, mlx.core as mx, parakeet_mlx, mlx_lm; print('engine ok, mlx', mx.__version__)"
find "$ENGINE" -name "__pycache__" -type d -prune -exec rm -rf {} +

step "Removing dev-only Info.plist keys"
for key in MinutesEngineDevPath MinutesProfilesDevPath; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Contents/Info.plist" 2>/dev/null || true
done

step "Signing ($SIGN_IDENTITY)"
# Sign every Mach-O inside the engine first, then the app bundle itself.
find "$ENGINE" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) -print0 |
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q "Mach-O"; then codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$f" >/dev/null 2>&1; fi
  done
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
  --entitlements "$ROOT/app/Sources/Minutes/Minutes.entitlements" "$APP"
codesign --verify --strict "$APP" && echo "signature ok"

step "Creating DMG"
DMG_DIR="$BUILD/dmg"
rm -rf "$DMG_DIR" && mkdir -p "$DMG_DIR"
ditto "$APP" "$DMG_DIR/Minutes.app"
ln -s /Applications "$DMG_DIR/Applications"
cat > "$DMG_DIR/READ ME FIRST.txt" <<'EOF'
Minutes: local meeting notes for Apple Silicon Macs (macOS 14 or later).

1. Drag Minutes into Applications.
2. The first time, Control-click Minutes in Applications and choose Open, then click Open.
   (If macOS still refuses: System Settings > Privacy & Security > "Open Anyway".)
3. Click "Download" on the first screen to fetch the local models (about 4 GB, one time).

Everything runs on your Mac. Audio never leaves your computer.
EOF
DMG="$DIST/Minutes-$VERSION-arm64.dmg"
rm -f "$DMG"
hdiutil create -volname "Minutes $VERSION" -srcfolder "$DMG_DIR" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" -quiet
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$DMG" 2>/dev/null || true

du -sh "$APP" "$DMG" | sed 's/^/   /'
echo "Built $DMG"
