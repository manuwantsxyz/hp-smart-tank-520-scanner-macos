#!/bin/zsh
# Descarga y compila libusb como dylib universal (Apple Silicon + Intel) en vendor/libusb.
# La app la lleva adentro (Contents/Frameworks), así nadie necesita Homebrew.
set -euo pipefail
ROOT="${0:A:h:h}"
VER=1.0.27
SHA=ffaa41d741a8a3bee244ac8e54a72ea05bf2879663c098c82fc5757853441575
OUT="$ROOT/vendor/libusb"
[[ -f "$OUT/lib/libusb-1.0.0.dylib" ]] && { echo "libusb ya está en $OUT"; exit 0; }

mkdir -p "$ROOT/vendor" && cd "$ROOT/vendor"
TAR="libusb-$VER.tar.bz2"
[[ -f "$TAR" ]] || curl -fsSL -o "$TAR" "https://github.com/libusb/libusb/releases/download/v$VER/$TAR"
echo "$SHA  $TAR" | shasum -a 256 -c -
rm -rf "libusb-$VER" && tar xjf "$TAR"
cd "libusb-$VER"
export CFLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -O2"
export LDFLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=14.0"
./configure --prefix="$OUT" --disable-dependency-tracking --disable-static >/dev/null
make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null
install_name_tool -id @rpath/libusb-1.0.0.dylib "$OUT/lib/libusb-1.0.0.dylib"
lipo -info "$OUT/lib/libusb-1.0.0.dylib"
