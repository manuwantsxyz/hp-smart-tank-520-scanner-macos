#!/bin/zsh
# Pruebas: lógica de selección (sin escáner) y banco con el escáner real (sin la interfaz).
# Uso: tests/run.sh            (todo; necesita la impresora conectada)
#      tests/run.sh --offline  (solo lo que no usa el escáner)
set -euo pipefail
HERE="${0:A:h}"; APP="${HERE:h}"; ROOT="${APP:h}"
BIN="$HERE/.bin"
LIBUSB="$ROOT/vendor/libusb"
"$ROOT/scripts/build-libusb.sh" >/dev/null
rm -rf "$BIN" && mkdir -p "$BIN"
FLAGS=(-swift-version 5 -target "$(uname -m)-apple-macos14.0" -import-objc-header "$APP/CLibusb.h"
       -Xcc -I"$LIBUSB/include/libusb-1.0" -L"$LIBUSB/lib" -lusb-1.0 -Xlinker -rpath -Xlinker "$LIBUSB/lib")

swiftc "${FLAGS[@]}" -o "$BIN/aspect" "$HERE/aspect/main.swift" \
  "$APP"/{Model,PreviewCanvas,Imaging,Backend,Batch,Inspector,L10n}.swift
"$BIN/aspect"
[[ "${1:-}" == "--offline" ]] && exit 0

swiftc "${FLAGS[@]}" -O -o "$BIN/runtests" "$HERE/main.swift" "$HERE/PDFCheck.swift" "$APP/Backend.swift" "$APP/Imaging.swift" "$APP/L10n.swift"
"$BIN/runtests" "$BIN/out"
