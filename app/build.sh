#!/bin/zsh
# Construye "Escáner Libre.app" (universal: Apple Silicon + Intel, macOS 14+) en build/.
#   ./build.sh            → build/Escáner Libre.app
#   ./build.sh --install  → además la copia a ~/Applications
#   ./build.sh --release  → además arma dist/Escaner-Libre-<versión>-macOS.zip
set -euo pipefail
HERE="${0:A:h}"
ROOT="${HERE:h}"
NAME="Escáner Libre"
VERSION="${VERSION:-1.0.0}"
BUILD="$HERE/build"
APP="$BUILD/$NAME.app"
LIBUSB="$ROOT/vendor/libusb"

"$ROOT/scripts/build-libusb.sh"

rm -rf "$BUILD" && mkdir -p "$BUILD"
SOURCES=("$HERE"/{App,Backend,Batch,Demo,Imaging,Model,Inspector,PreviewCanvas}.swift)
for ARCH in arm64 x86_64; do
  swiftc -swift-version 5 -O -parse-as-library -target "$ARCH-apple-macos14.0" \
    -import-objc-header "$HERE/CLibusb.h" -Xcc -I"$LIBUSB/include/libusb-1.0" \
    -L"$LIBUSB/lib" -lusb-1.0 -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$BUILD/EscanerLibre-$ARCH" "${SOURCES[@]}"
done
lipo -create -output "$BUILD/EscanerLibre" "$BUILD"/EscanerLibre-{arm64,x86_64}

# Icono: SF Symbol renderizado a .icns
swift -swift-version 5 "$HERE/make_icon.swift" "$BUILD/icon.png"
mkdir -p "$BUILD/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BUILD/icon.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BUILD/EscanerLibre" "$APP/Contents/MacOS/"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/"
cp "$LIBUSB/lib/libusb-1.0.0.dylib" "$APP/Contents/Frameworks/"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>io.github.manuwantsxyz.escaner-libre</string>
  <key>CFBundleExecutable</key><string>EscanerLibre</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>es</string>
  <key>NSHumanReadableCopyright</key><string>Licencia MIT. No afiliado a HP Inc.</string>
</dict>
</plist>
PLIST

# Firma ad-hoc (sin cuenta de Apple Developer). Con una identidad "Developer ID", pasarla en SIGN_ID.
if [[ -n "${SIGN_ID:-}" ]]; then
  codesign --force --deep --options runtime --timestamp -s "$SIGN_ID" "$APP"
else
  codesign --force --deep -s - "$APP"
fi
echo "OK: $APP"

if [[ " $* " == *" --install "* ]]; then
  rm -rf "$HOME/Applications/$NAME.app"
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$HOME/Applications/"
  echo "Instalada en ~/Applications/$NAME.app"
fi

if [[ " $* " == *" --release "* ]]; then
  mkdir -p "$ROOT/dist"
  ZIP="$ROOT/dist/Escaner-Libre-$VERSION-macOS.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Release: $ZIP"
fi
