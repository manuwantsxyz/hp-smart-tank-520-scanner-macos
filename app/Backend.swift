// Driver: eSCL (el protocolo AirScan/Mopria: HTTP + XML) sobre IPP-over-USB, con libusb incluida en la app.
// No usa ippusbd (el proxy de macOS que se desincroniza) ni drivers de HP.
// Todas las llamadas bloquean: usarlas fuera del hilo principal.
import Foundation

struct ScannerInfo: Decodable, Sendable {
    let state: String?
    let model: String?
    let max_w: Int
    let max_h: Int
    let resolutions: [Int]
}

enum ScanError: LocalizedError {
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .failed(let m): return m
        case .cancelled: return "Escaneo cancelado."
        }
    }
}

private let debug = ProcessInfo.processInfo.environment["HPSCAN_DEBUG"] != nil
private func log(_ s: @autoclosure () -> String) {
    if debug { FileHandle.standardError.write(Data("[usb] \(s())\n".utf8)) }
}

final class Backend: @unchecked Sendable {
    static let shared = Backend()

    private let session = NSLock()   // one USB conversation at a time
    private let flag = NSLock()
    private var cancelRequested = false
    private var ctx: OpaquePointer?

    private init() {
        if libusb_init(&ctx) != 0 { ctx = nil }
    }

    private var isCancelled: Bool { flag.withLock { cancelRequested } }

    /// Asks the running scan (if any) to stop; the driver then cancels the job on the scanner.
    func cancel() { flag.withLock { cancelRequested = true } }

    private func withScanner<T>(_ body: (UsbHttp) throws -> T) throws -> T {
        session.lock()
        defer { session.unlock() }
        flag.withLock { cancelRequested = false }
        guard let ctx else { throw ScanError.failed("No pude inicializar USB.") }
        let http = try UsbHttp(ctx: ctx, isCancelled: { [unowned self] in self.isCancelled })
        defer { http.close() }
        do {
            return try body(http)
        } catch is UsbHttp.Cancelled {
            throw ScanError.cancelled
        }
    }

    func info() throws -> ScannerInfo {
        try withScanner { http in
            let caps = try http.text("GET", "/eSCL/ScannerCapabilities")
            let state = tag(try http.text("GET", "/eSCL/ScannerStatus"), "State")
            let res = Set(matches(#"<scan:XResolution>(\d+)</scan:XResolution>"#, caps).compactMap(Int.init)).sorted()
            guard let w = tag(caps, "MaxWidth").flatMap(Int.init), let h = tag(caps, "MaxHeight").flatMap(Int.init) else {
                throw ScanError.failed("La impresora no informó un escáner (eSCL).")
            }
            var model = tag(caps, "MakeAndModel")
            if http.isHP, let m = model, !m.uppercased().hasPrefix("HP") { model = "HP " + m }
            return ScannerInfo(state: state, model: model, max_w: w, max_h: h,
                               resolutions: res.isEmpty ? [75, 150, 300, 600] : res)
        }
    }

    /// Scans to a JPEG. `region` is x,y,w,h in 1/300 inch from the top-left of the glass (nil = whole glass).
    /// `color` is "color", "gray" or "bw" (black & white is thresholded by the app from grayscale).
    func scan(dpi: Int, color: String, region: [Int]?, to url: URL) throws -> URL {
        try withScanner { http in
            let caps = try http.text("GET", "/eSCL/ScannerCapabilities")
            var state: String?
            for i in 0..<60 {  // the head takes a few seconds to park after a scan
                state = tag(try http.text("GET", "/eSCL/ScannerStatus"), "State")
                if state == "Idle" { break }
                if i == 59 { throw ScanError.failed("El escáner no está libre (estado: \(state ?? "?")).") }
                try http.sleep(1)
            }
            guard let maxW = tag(caps, "MaxWidth").flatMap(Int.init), let maxH = tag(caps, "MaxHeight").flatMap(Int.init) else {
                throw ScanError.failed("La impresora no informó un escáner (eSCL).")
            }
            var x = 0, y = 0, w = maxW, h = maxH
            if let r = region, r.count == 4 {
                x = max(0, min(r[0], maxW - 30)); y = max(0, min(r[1], maxH - 30))
                w = max(30, min(r[2], maxW - x)); h = max(30, min(r[3], maxH - y))
            }
            let mode = color == "color" ? "RGB24" : "Grayscale8"
            let settings = """
            <?xml version="1.0" encoding="UTF-8"?>
            <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
              <pwg:Version>2.63</pwg:Version>
              <pwg:ScanRegions>
                <pwg:ScanRegion>
                  <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
                  <pwg:XOffset>\(x)</pwg:XOffset>
                  <pwg:YOffset>\(y)</pwg:YOffset>
                  <pwg:Width>\(w)</pwg:Width>
                  <pwg:Height>\(h)</pwg:Height>
                </pwg:ScanRegion>
              </pwg:ScanRegions>
              <pwg:InputSource>Platen</pwg:InputSource>
              <scan:ColorMode>\(mode)</scan:ColorMode>
              <scan:XResolution>\(dpi)</scan:XResolution>
              <scan:YResolution>\(dpi)</scan:YResolution>
              <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
              <scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>
            </scan:ScanSettings>
            """
            let job = try http.request("POST", "/eSCL/ScanJobs", body: Data(settings.utf8))
            guard job.status == 201, let loc = job.headers["location"] else {
                let msg = String(decoding: job.body.prefix(300), as: UTF8.self)
                throw ScanError.failed("El escáner rechazó el trabajo (HTTP \(job.status)): \(msg)")
            }
            let path = loc.replacingOccurrences(of: #"^https?://[^/]+"#, with: "", options: .regularExpression)

            var data: Data?
            do {
                for _ in 0..<60 {
                    let r = try http.request("GET", "\(path)/NextDocument", timeout: 600_000)
                    if r.status == 200 { data = r.body; break }
                    if r.status == 503 { try http.sleep(1); continue }  // busy / not ready yet
                    throw ScanError.failed("Error obteniendo el documento (HTTP \(r.status)).")
                }
            } catch is UsbHttp.Cancelled {
                // Drop the half-read response, then cancel the job so the head returns.
                http.abort(job: path)
                throw ScanError.cancelled
            }
            guard let data else { throw ScanError.failed("El escáner no entregó la imagen a tiempo.") }
            try data.write(to: url)
            // Tell the scanner we're done (the next NextDocument returns 404 = job finished).
            _ = try? http.request("GET", "\(path)/NextDocument", timeout: 15_000)
            return url
        }
    }
}

// MARK: - HTTP over USB bulk endpoints

final class UsbHttp {
    struct Cancelled: Error {}
    struct Timeout: Error {}

    private struct Candidate {
        let iface: Int32, alt: Int32, ippUsb: Bool, epIn: UInt8, epOut: UInt8, packet: Int32
    }

    private(set) var isHP = false
    private var handle: OpaquePointer?
    private var claimed: Int32 = -1
    private var epIn: UInt8 = 0, epOut: UInt8 = 0, packet: Int32 = 512
    private var buf = Data()
    private let isCancelled: () -> Bool
    private var ignoreCancel = false

    init(ctx: OpaquePointer, isCancelled: @escaping () -> Bool) throws {
        self.isCancelled = isCancelled
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let n = libusb_get_device_list(ctx, &list)
        defer { if let list { libusb_free_device_list(list, 1) } }

        // Every printer with an IPP-over-USB interface (7/1/4); HP first.
        var found: [(dev: OpaquePointer, hp: Bool, cands: [Candidate])] = []
        for i in 0..<max(0, n) {
            guard let dev = list?[i] else { continue }
            var d = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &d) == 0 else { continue }
            let hp = d.idVendor == 0x03F0
            let cands = Self.candidates(dev, allowHPChannel: hp)
            if cands.contains(where: \.ippUsb) {
                log(String(format: "dispositivo %04x:%04x, %d interfaces candidatas", d.idVendor, d.idProduct, cands.count))
                found.append((dev, hp, cands))
            }
        }
        found.sort { $0.hp && !$1.hp }
        guard !found.isEmpty else {
            throw ScanError.failed("No encuentro la impresora por USB. ¿Está encendida y conectada?")
        }

        var busy = false
        for f in found {
            var h: OpaquePointer?
            guard libusb_open(f.dev, &h) == 0, let h else { busy = true; continue }
            for c in f.cands {
                guard libusb_claim_interface(h, c.iface) == 0 else { busy = true; continue }
                if c.alt != 0, libusb_set_interface_alt_setting(h, c.iface, c.alt) != 0 {
                    libusb_release_interface(h, c.iface)
                    busy = true
                    continue
                }
                handle = h; isHP = f.hp; claimed = c.iface; epIn = c.epIn; epOut = c.epOut; packet = c.packet
                log("usando interfaz \(c.iface) alt \(c.alt)\(c.ippUsb ? " (IPP-USB)" : " (canal HP)")")
                drain()
                return
            }
            libusb_close(h)
        }
        throw ScanError.failed(busy
            ? "El escáner está en uso por otra app (Captura de Imagen o Vista Previa). Cerrala y probá de nuevo."
            : "No pude conectarme al escáner por USB.")
    }

    /// Interfaces to try, best first: standard IPP-over-USB alt settings on the highest interface
    /// numbers (interface 0 can vanish after a USB reset), HP's 0xFF/0xCC channel last.
    private static func candidates(_ dev: OpaquePointer, allowHPChannel: Bool) -> [Candidate] {
        var cfg: UnsafeMutablePointer<libusb_config_descriptor>?
        guard libusb_get_active_config_descriptor(dev, &cfg) == 0, let cfg else { return [] }
        defer { libusb_free_config_descriptor(cfg) }
        var out: [Candidate] = []
        for i in 0..<Int(cfg.pointee.bNumInterfaces) {
            let intf = cfg.pointee.interface[i]
            for a in 0..<Int(intf.num_altsetting) {
                let alt = intf.altsetting[a]
                let sig = (alt.bInterfaceClass, alt.bInterfaceSubClass, alt.bInterfaceProtocol)
                let ipp = sig == (7, 1, 4)
                guard ipp || (allowHPChannel && sig == (0xFF, 0xCC, 0)) else { continue }
                var inEP: UInt8 = 0, outEP: UInt8 = 0, size: Int32 = 512
                for e in 0..<Int(alt.bNumEndpoints) {
                    let ep = alt.endpoint[e]
                    guard ep.bmAttributes & 0x03 == 2 else { continue }  // bulk
                    if ep.bEndpointAddress & 0x80 != 0 {
                        if inEP == 0 { inEP = ep.bEndpointAddress; size = Int32(ep.wMaxPacketSize) }
                    } else if outEP == 0 {
                        outEP = ep.bEndpointAddress
                    }
                }
                guard inEP != 0, outEP != 0 else { continue }
                out.append(Candidate(iface: Int32(alt.bInterfaceNumber), alt: Int32(alt.bAlternateSetting),
                                     ippUsb: ipp, epIn: inEP, epOut: outEP, packet: max(64, size)))
            }
        }
        return out.sorted {
            if $0.ippUsb != $1.ippUsb { return $0.ippUsb }
            let a = $0.iface == 0 ? -1 : $0.iface, b = $1.iface == 0 ? -1 : $1.iface
            return a > b
        }
    }

    func close() {
        guard let h = handle else { return }
        libusb_release_interface(h, claimed)
        libusb_close(h)
        handle = nil
    }

    deinit { close() }

    // MARK: Low level

    /// Reads one packet. On macOS a large read that times out before a short packet arrives
    /// loses the partial data and desyncs the stream, so never ask for more than a packet.
    @discardableResult
    private func fill(timeout: UInt32) throws -> Bool {
        var chunk = [UInt8](repeating: 0, count: Int(packet))
        var got: Int32 = 0
        let r = libusb_bulk_transfer(handle, epIn, &chunk, packet, &got, timeout)
        if got > 0 { buf.append(contentsOf: chunk[0..<Int(got)]) }
        if r == LIBUSB_ERROR_TIMEOUT.rawValue { return false }
        if r != 0 {
            throw ScanError.failed("Se perdió la conexión USB con el escáner (\(String(cString: libusb_error_name(r)))).")
        }
        return true
    }

    /// Discards stale responses left over from other software. The printer also sends
    /// zero-length packets, so keep reading until it goes quiet.
    func drain() {
        buf = Data()
        for _ in 0..<2000 {
            guard (try? fill(timeout: 500)) == true else { break }
            buf = Data()
        }
        buf = Data()
    }

    private func checkCancel() throws {
        if !ignoreCancel && isCancelled() { throw Cancelled() }
    }

    func sleep(_ seconds: Double) throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try checkCancel()
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func readUntil(_ sep: Data, timeout: Int) throws -> Data {
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000)
        var searchFrom = 0
        while true {
            if let r = buf.range(of: sep, in: max(0, searchFrom - sep.count)..<buf.count) {
                let out = buf.subdata(in: 0..<r.upperBound)
                buf = buf.subdata(in: r.upperBound..<buf.count)
                return out
            }
            searchFrom = buf.count
            try checkCancel()
            if Date() > deadline { throw ScanError.failed("El escáner no respondió a tiempo.") }
            try fill(timeout: 1000)
        }
    }

    private func readCount(_ n: Int, timeout: Int) throws -> Data {
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000)
        buf.reserveCapacity(n)
        while buf.count < n {
            try checkCancel()
            if Date() > deadline { throw ScanError.failed("El escáner dejó de enviar datos.") }
            try fill(timeout: 1000)
        }
        let out = buf.subdata(in: 0..<n)
        buf = buf.subdata(in: n..<buf.count)
        return out
    }

    private func write(_ data: Data) throws {
        var bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            var sent: Int32 = 0
            let r = bytes.withUnsafeMutableBufferPointer { p in
                libusb_bulk_transfer(handle, epOut, p.baseAddress! + offset, Int32(p.count - offset), &sent, 10_000)
            }
            guard r == 0 || sent > 0 else {
                throw ScanError.failed("No pude enviar el pedido al escáner (\(String(cString: libusb_error_name(r)))).")
            }
            offset += Int(sent)
        }
    }

    // MARK: HTTP

    struct Response { let status: Int; let headers: [String: String]; let body: Data }

    func request(_ method: String, _ path: String, body: Data = Data(), timeout: Int = 120_000) throws -> Response {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.count)\r\n"
        if !body.isEmpty { head += "Content-Type: text/xml\r\n" }
        head += "\r\n"
        try write(Data(head.utf8) + body)

        let raw = String(decoding: try readUntil(Data("\r\n\r\n".utf8), timeout: timeout), as: UTF8.self)
        log("\(method) \(path) → \(raw.debugDescription)")
        let lines = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw ScanError.failed("Respuesta inesperada del escáner.")
        }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }

        var out = Data()
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            while true {
                let line = String(decoding: try readUntil(Data("\r\n".utf8), timeout: timeout), as: UTF8.self)
                let hex = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ";").first.map(String.init) ?? ""
                guard let size = Int(hex, radix: 16) else { throw ScanError.failed("Respuesta dañada del escáner.") }
                if size == 0 { _ = try readUntil(Data("\r\n".utf8), timeout: timeout); break }
                out += try readCount(size, timeout: timeout)
                _ = try readCount(2, timeout: timeout)
            }
        } else if let len = headers["content-length"].flatMap(Int.init), len > 0 {
            out = try readCount(len, timeout: timeout)
        }
        return Response(status: status, headers: headers, body: out)
    }

    func text(_ method: String, _ path: String) throws -> String {
        String(decoding: try request(method, path).body, as: UTF8.self)
    }

    /// After a cancel: resync the stream and delete the job so the scan head returns.
    func abort(job path: String) {
        ignoreCancel = true
        drain()
        _ = try? request("DELETE", path, timeout: 10_000)
        drain()
    }
}

// MARK: - XML helpers

private func tag(_ xml: String, _ name: String) -> String? {
    matches("<(?:\\w+:)?\(name)>([^<]*)</(?:\\w+:)?\(name)>", xml).first
}

private func matches(_ pattern: String, _ s: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
        Range($0.range(at: 1), in: s).map { String(s[$0]) }
    }
}
