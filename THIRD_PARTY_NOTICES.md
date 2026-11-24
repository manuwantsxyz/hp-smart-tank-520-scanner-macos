# Third-party components

## libusb 1.0.27

- Website: https://libusb.info
- Source: https://github.com/libusb/libusb/releases/tag/v1.0.27
- License: GNU Lesser General Public License v2.1 (LGPL-2.1-or-later)

The app bundles libusb **unmodified**, as a separate dynamic library:

```
Escáner Libre.app/Contents/Frameworks/libusb-1.0.0.dylib
```

It is built by `scripts/build-libusb.sh` from the official release tarball, which is verified with SHA-256.

You can replace it with any compatible libusb build, because the app loads it through `@rpath`. The full license text is at https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html
