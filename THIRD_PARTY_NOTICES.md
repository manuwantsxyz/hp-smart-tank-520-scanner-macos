# Componentes de terceros

## libusb 1.0.27

- Sitio: https://libusb.info — código fuente: https://github.com/libusb/libusb/releases/tag/v1.0.27
- Licencia: GNU Lesser General Public License v2.1 (LGPL-2.1-or-later)

La app la incluye sin modificar como biblioteca dinámica separada
(`Escáner Libre.app/Contents/Frameworks/libusb-1.0.0.dylib`), compilada con
`scripts/build-libusb.sh` a partir del tarball oficial (verificado por SHA-256).
Podés reemplazarla por otra versión compatible de libusb: la app la carga por `@rpath`.
El texto completo de la licencia está en https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html
