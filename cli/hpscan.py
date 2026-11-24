#!/usr/bin/env python3
"""hpscan — scanner driver for the HP Smart Tank 520/540 over USB, without HP software.

The printer exposes eSCL (the AirScan/Mopria scanning protocol: HTTP + XML) on its
USB interfaces (IPP-over-USB, class 7/1/4 alt settings). This tool speaks HTTP
directly over the USB bulk endpoints with libusb.

Usage:
  hpscan.py scan [-o out.pdf] [--format pdf|jpeg] [--color color|gray] [--dpi 300] [--area a4|letter|full]
  hpscan.py status
  hpscan.py caps
"""
import argparse
import json
import re
import signal
import sys
import time
from pathlib import Path


class Cancelled(Exception):
    pass


def _on_sigterm(*_):
    raise Cancelled()

import usb.backend.libusb1
import usb.core
import usb.util

VID, PID = 0x03F0, 0x4554  # HP Smart Tank 520/540; override with HPSCAN_PID=0x....
PID = int(__import__("os").environ.get("HPSCAN_PID", hex(PID)), 16)
LIBUSB = next((p for p in [__import__("os").environ.get("LIBUSB", ""),
                           "/opt/homebrew/lib/libusb-1.0.dylib", "/usr/local/lib/libusb-1.0.dylib"]
               if p and Path(p).exists()), None)
DEBUG = bool(__import__("os").environ.get("HPSCAN_DEBUG"))
ESCL_NS = "http://schemas.hp.com/imaging/escl/2011/05/03"
PWG_NS = "http://www.pwg.org/schemas/2010/12/sm"

# Sizes in 1/300 inch (eSCL ThreeHundredthsOfInches)
AREAS = {
    "a4": (2480, 3508),
    "letter": (2550, 3300),
    "full": None,  # filled from capabilities (max platen size)
}


class UsbHttp:
    """Minimal HTTP/1.1 client over a USB bulk interface pair (IPP-over-USB style)."""

    def __init__(self):
        backend = usb.backend.libusb1.get_backend(find_library=(lambda _: LIBUSB) if LIBUSB else None)
        self.dev = usb.core.find(idVendor=VID, idProduct=PID, backend=backend)
        if self.dev is None:
            sys.exit("Impresora no encontrada por USB (¿está encendida y conectada?)")
        self.intf = self.ep_in = self.ep_out = None
        self._claim()
        self.buf = bytearray()
        self._drain()

    def _claim(self):
        cfg = self.dev.get_active_configuration()
        # Prefer standard IPP-over-USB (7/1/4) alternate settings on interfaces 2/3
        # (interface 0 can vanish after a USB reset); HP's 0xFF/0xCC channel last.
        candidates = sorted(
            cfg,
            key=lambda i: (0 if (i.bInterfaceClass, i.bInterfaceSubClass, i.bInterfaceProtocol) == (7, 1, 4) else 1,
                           -i.bInterfaceNumber if i.bInterfaceNumber else 99),
        )
        last_err = None
        for intf in candidates:
            sig = (intf.bInterfaceClass, intf.bInterfaceSubClass, intf.bInterfaceProtocol)
            if sig not in [(7, 1, 4), (0xFF, 0xCC, 0)]:
                continue
            try:
                usb.util.claim_interface(self.dev, intf.bInterfaceNumber)
                if intf.bAlternateSetting:
                    self.dev.set_interface_altsetting(intf.bInterfaceNumber, intf.bAlternateSetting)
            except usb.core.USBError as e:
                last_err = e
                continue
            self.intf = intf
            if DEBUG:
                print(f"[debug] usando interfaz {intf.bInterfaceNumber} alt {intf.bAlternateSetting} {sig}", file=sys.stderr)
            self.ep_out = usb.util.find_descriptor(
                intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT)
            self.ep_in = usb.util.find_descriptor(
                intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN
                and usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK)
            return
        sys.exit(f"No pude tomar ninguna interfaz USB del escáner: {last_err}")

    def close(self):
        if self.intf is not None:
            usb.util.release_interface(self.dev, self.intf.bInterfaceNumber)
        usb.util.dispose_resources(self.dev)

    def _drain(self):
        """Discard stale responses left over from other software."""
        # The printer sends zero-length packets; keep reading until it goes quiet.
        for _ in range(2000):
            try:
                self.ep_in.read(self.ep_in.wMaxPacketSize, timeout=500)
            except usb.core.USBTimeoutError:
                break

    def _fill(self, timeout=30000):
        # Read one packet at a time: on macOS a large read that times out before a
        # short packet arrives loses the partial data and desyncs the stream.
        chunk = self.ep_in.read(self.ep_in.wMaxPacketSize, timeout=timeout)
        self.buf += chunk

    def _read_until(self, sep, timeout):
        deadline = time.time() + timeout / 1000
        while sep not in self.buf:
            if time.time() > deadline:
                raise TimeoutError("timeout esperando respuesta del escáner")
            try:
                self._fill(timeout=5000)
            except usb.core.USBTimeoutError:
                pass
        i = self.buf.index(sep) + len(sep)
        out, self.buf = bytes(self.buf[:i]), self.buf[i:]
        return out

    def _read_n(self, n, timeout):
        deadline = time.time() + timeout / 1000
        while len(self.buf) < n:
            if time.time() > deadline:
                raise TimeoutError("timeout leyendo el cuerpo de la respuesta")
            try:
                self._fill(timeout=5000)
            except usb.core.USBTimeoutError:
                pass
        out, self.buf = bytes(self.buf[:n]), self.buf[n:]
        return out

    def request(self, method, path, body=b"", content_type="text/xml", timeout=120000):
        head = (f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n"
                f"Content-Length: {len(body)}\r\n")
        if body:
            head += f"Content-Type: {content_type}\r\n"
        head += "\r\n"
        self.ep_out.write(head.encode() + body, timeout=10000)

        raw = self._read_until(b"\r\n\r\n", timeout).decode("latin-1")
        if DEBUG:
            print(f"[debug] {method} {path} -> {raw!r}", file=sys.stderr)
        status_line, *header_lines = raw.strip().split("\r\n")
        status = int(status_line.split()[1])
        headers = {}
        for line in header_lines:
            k, _, v = line.partition(":")
            headers[k.strip().lower()] = v.strip()

        if headers.get("transfer-encoding", "").lower() == "chunked":
            data = bytearray()
            while True:
                size = int(self._read_until(b"\r\n", timeout).strip().split(b";")[0], 16)
                if size == 0:
                    self._read_until(b"\r\n", timeout)
                    break
                data += self._read_n(size, timeout)
                self._read_n(2, timeout)
            body_out = bytes(data)
        elif "content-length" in headers:
            body_out = self._read_n(int(headers["content-length"]), timeout)
        else:
            body_out = b""
        return status, headers, body_out


def tag(xml, name):
    m = re.search(rf"<(?:\w+:)?{name}>([^<]*)</(?:\w+:)?{name}>", xml)
    return m.group(1) if m else None


def cmd_caps(http, _args):
    st, _, body = http.request("GET", "/eSCL/ScannerCapabilities")
    print(body.decode())


def cmd_status(http, _args):
    st, _, body = http.request("GET", "/eSCL/ScannerStatus")
    xml = body.decode()
    print(f"Estado: {tag(xml, 'State')}  ADF: {tag(xml, 'AdfState') or 'n/a'}")


def cmd_info(http, _args):
    """Machine-readable summary for the app: state + platen size + resolutions."""
    caps = http.request("GET", "/eSCL/ScannerCapabilities")[2].decode()
    state = tag(http.request("GET", "/eSCL/ScannerStatus")[2].decode(), "State")
    res = sorted({int(x) for x in re.findall(r"<scan:XResolution>(\d+)</scan:XResolution>", caps)})
    print(json.dumps({
        "state": state,
        "model": tag(caps, "MakeAndModel"),
        "max_w": int(tag(caps, "MaxWidth")),
        "max_h": int(tag(caps, "MaxHeight")),
        "resolutions": res,
    }))


def cmd_scan(http, args):
    caps = http.request("GET", "/eSCL/ScannerCapabilities")[2].decode()
    for _ in range(60):  # the head takes a few seconds to park after a scan
        state = tag(http.request("GET", "/eSCL/ScannerStatus")[2].decode(), "State")
        if state == "Idle":
            break
        time.sleep(1)
    else:
        sys.exit(f"El escáner no está libre (estado: {state}).")

    max_w, max_h = int(tag(caps, "MaxWidth")), int(tag(caps, "MaxHeight"))
    x = y = 0
    if args.region:  # x,y,w,h in 1/300 inch, origin top-left of the glass
        x, y, w, h = (int(round(float(v))) for v in args.region.split(","))
        x, y = max(0, min(x, max_w - 30)), max(0, min(y, max_h - 30))
        w, h = max(30, min(w, max_w - x)), max(30, min(h, max_h - y))
    elif args.area == "full":
        w, h = max_w, max_h
    else:
        w, h = AREAS[args.area]
        w, h = min(w, max_w), min(h, max_h)

    mime = {"pdf": "application/pdf", "jpeg": "image/jpeg"}[args.format]
    # Black & white is thresholded by the app from a grayscale scan.
    color = {"color": "RGB24", "gray": "Grayscale8", "bw": "Grayscale8"}[args.color]
    settings = f"""<?xml version="1.0" encoding="UTF-8"?>
<scan:ScanSettings xmlns:scan="{ESCL_NS}" xmlns:pwg="{PWG_NS}">
  <pwg:Version>2.63</pwg:Version>
  <pwg:ScanRegions>
    <pwg:ScanRegion>
      <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
      <pwg:XOffset>{x}</pwg:XOffset>
      <pwg:YOffset>{y}</pwg:YOffset>
      <pwg:Width>{w}</pwg:Width>
      <pwg:Height>{h}</pwg:Height>
    </pwg:ScanRegion>
  </pwg:ScanRegions>
  <pwg:InputSource>Platen</pwg:InputSource>
  <scan:ColorMode>{color}</scan:ColorMode>
  <scan:XResolution>{args.dpi}</scan:XResolution>
  <scan:YResolution>{args.dpi}</scan:YResolution>
  <pwg:DocumentFormat>{mime}</pwg:DocumentFormat>
  <scan:DocumentFormatExt>{mime}</scan:DocumentFormatExt>
</scan:ScanSettings>"""

    status, headers, body = http.request("POST", "/eSCL/ScanJobs", settings.encode())
    if status != 201:
        sys.exit(f"El escáner rechazó el trabajo (HTTP {status}): {body.decode(errors='replace')[:300]}")
    job = headers["location"]
    job = re.sub(r"^https?://[^/]+", "", job)
    print(f"Escaneando ({args.dpi} dpi, {args.color}, {args.format})…", file=sys.stderr)

    try:
        for attempt in range(60):
            status, headers, data = http.request("GET", f"{job}/NextDocument", timeout=600000)
            if status == 200:
                break
            if status == 503:  # busy / not ready yet
                time.sleep(1)
                continue
            sys.exit(f"Error obteniendo el documento (HTTP {status})")
        else:
            sys.exit("El escáner no entregó la imagen a tiempo")
    except Cancelled:
        # Drop any half-read response, then cancel the job so the head returns.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        http.buf = bytearray()
        http._drain()
        try:
            http.request("DELETE", job, timeout=10000)
            http._drain()
        except Exception:
            pass
        sys.exit("Escaneo cancelado")

    out = Path(args.output or f"scan-{time.strftime('%Y%m%d-%H%M%S')}.{'pdf' if args.format == 'pdf' else 'jpg'}")
    out.write_bytes(data)
    # Tell the scanner we're done (next NextDocument returns 404 = job finished).
    try:
        http.request("GET", f"{job}/NextDocument", timeout=15000)
    except Exception:
        pass
    print(out.resolve())


def main():
    p = argparse.ArgumentParser(description="Escáner HP Smart Tank 520 vía eSCL sobre USB")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan")
    s.add_argument("-o", "--output")
    s.add_argument("--format", choices=["pdf", "jpeg"], default="pdf")
    s.add_argument("--color", choices=["color", "gray", "bw"], default="color")
    s.add_argument("--dpi", type=int, default=300)
    s.add_argument("--area", choices=list(AREAS), default="a4")
    s.add_argument("--region", help="x,y,w,h en 1/300 de pulgada (origen arriba a la izquierda)")
    sub.add_parser("status")
    sub.add_parser("caps")
    sub.add_parser("info")
    args = p.parse_args()

    signal.signal(signal.SIGTERM, _on_sigterm)
    try:
        http = UsbHttp()
    except Cancelled:
        sys.exit("Escaneo cancelado")
    try:
        {"scan": cmd_scan, "status": cmd_status, "caps": cmd_caps, "info": cmd_info}[args.cmd](http, args)
    except Cancelled:
        sys.exit("Escaneo cancelado")
    finally:
        http.close()


if __name__ == "__main__":
    main()
