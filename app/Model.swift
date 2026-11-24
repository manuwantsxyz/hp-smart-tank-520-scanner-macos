// Estado de la app: dispositivo, ajustes, vista general, selecciones y escaneos.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SizePreset: String, CaseIterable, Identifiable {
    case full, a4, letter, legal, a5, photo4x6, photo5x7
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: return "Vidrio completo"
        case .a4: return "A4"
        case .letter: return "Carta (US Letter)"
        case .legal: return "Oficio (US Legal)"
        case .a5: return "A5"
        case .photo4x6: return "Foto 10 × 15 cm"
        case .photo5x7: return "Foto 13 × 18 cm"
        }
    }
    /// Size in inches (nil = whole glass).
    var inches: CGSize? {
        switch self {
        case .full: return nil
        case .a4: return CGSize(width: 8.27, height: 11.69)
        case .letter: return CGSize(width: 8.5, height: 11)
        case .legal: return CGSize(width: 8.5, height: 14)
        case .a5: return CGSize(width: 5.83, height: 8.27)
        case .photo4x6: return CGSize(width: 4, height: 6)
        case .photo5x7: return CGSize(width: 5, height: 7)
        }
    }
}

/// Locked aspect ratio for selections (width : height of the result, after rotation).
enum AspectLock: String, CaseIterable, Identifiable {
    case free, r1x1, r4x5, r3x4, r2x3, r9x16, r5x4, r4x3, r3x2, r16x9, r191x1, r3x1
    var id: String { rawValue }
    var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .r1x1: return 1
        case .r4x5: return 4.0 / 5
        case .r3x4: return 3.0 / 4
        case .r2x3: return 2.0 / 3
        case .r9x16: return 9.0 / 16
        case .r5x4: return 5.0 / 4
        case .r4x3: return 4.0 / 3
        case .r3x2: return 3.0 / 2
        case .r16x9: return 16.0 / 9
        case .r191x1: return 1.91
        case .r3x1: return 3
        }
    }
    var short: String {
        switch self {
        case .free: return "Libre"
        case .r1x1: return "1:1"
        case .r4x5: return "4:5"
        case .r3x4: return "3:4"
        case .r2x3: return "2:3"
        case .r9x16: return "9:16"
        case .r5x4: return "5:4"
        case .r4x3: return "4:3"
        case .r3x2: return "3:2"
        case .r16x9: return "16:9"
        case .r191x1: return "1.91:1"
        case .r3x1: return "3:1"
        }
    }
    var label: String {
        switch self {
        case .free: return "Libre"
        case .r1x1: return "1:1 · Cuadrado (Instagram)"
        case .r4x5: return "4:5 · Instagram vertical"
        case .r3x4: return "3:4 · Instagram, tablet"
        case .r2x3: return "2:3 · Pinterest, foto 10×15"
        case .r9x16: return "9:16 · Stories, Reels, TikTok"
        case .r5x4: return "5:4 · Foto 8×10"
        case .r4x3: return "4:3 · Pantalla clásica"
        case .r3x2: return "3:2 · Foto clásica"
        case .r16x9: return "16:9 · YouTube, presentaciones"
        case .r191x1: return "1.91:1 · Link de Facebook / LinkedIn"
        case .r3x1: return "3:1 · Banner (portada de X)"
        }
    }
    /// The same ratio in the other orientation.
    var flipped: AspectLock {
        switch self {
        case .r4x5: return .r5x4
        case .r5x4: return .r4x5
        case .r3x4: return .r4x3
        case .r4x3: return .r3x4
        case .r2x3: return .r3x2
        case .r3x2: return .r2x3
        case .r9x16: return .r16x9
        case .r16x9: return .r9x16
        default: return self
        }
    }
    static let vertical: [AspectLock] = [.r4x5, .r3x4, .r2x3, .r9x16]
    static let horizontal: [AspectLock] = [.r5x4, .r4x3, .r3x2, .r16x9, .r191x1, .r3x1]
}

enum Units: String, CaseIterable, Identifiable {
    case cm, mm, inch, px
    var id: String { rawValue }
    var label: String { self == .inch ? "pulg." : rawValue }
}

enum AutoSelect: String, CaseIterable, Identifiable {
    case off, enclosing, separate
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Desactivada"
        case .enclosing: return "Detectar recuadro"
        case .separate: return "Detectar elementos separados"
        }
    }
}

/// What to do with the files once saved.
enum AfterScan: String, CaseIterable, Identifiable {
    case nothing, finder, app
    var id: String { rawValue }
}

enum DeviceState: Equatable {
    case checking, ready, busy(String), unavailable(String)
    var label: String {
        switch self {
        case .checking: return "Buscando…"
        case .ready: return "Listo"
        case .busy(let s): return s
        case .unavailable(let s): return s
        }
    }
    var color: Color {
        switch self {
        case .ready: return .green
        case .checking, .busy: return .orange
        case .unavailable: return .red
        }
    }
}

enum Activity: Equatable {
    case idle
    case overview(Date)
    case scanning(Date, String)
    case processing
    case saving(String)

    var isBusy: Bool { self != .idle }
    var isCancellable: Bool {
        switch self {
        case .overview, .scanning: return true
        default: return false
        }
    }
}

/// One page of the document being assembled (stored on disk, thumbnail in memory).
struct BatchPage: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let thumb: CGImage
    let dpi: Int
}

struct ScanResult: Identifiable {
    let id = UUID()
    let url: URL
    let image: CGImage
}

/// An app that can open the scanned files.
struct EditorApp: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    var name: String { FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
    var icon: NSImage {
        let i = NSWorkspace.shared.icon(forFile: url.path)
        i.size = NSSize(width: 16, height: 16)
        return i
    }
}

@MainActor
final class ScannerModel: ObservableObject {
    private let defaults = UserDefaults.standard

    // Device
    @Published var info: ScannerInfo?
    @Published var device: DeviceState = .checking

    // Scan settings (persisted)
    @Published var kind: ScanKind { didSet { save("kind", kind.rawValue); refreshDisplay() } }
    @Published var dpi: Int { didSet { save("dpi", dpi) } }
    @Published var sizePreset: SizePreset { didSet { save("size", sizePreset.rawValue) } }
    @Published var units: Units { didSet { save("units", units.rawValue) } }
    @Published var aspect: AspectLock {
        didSet { save("aspect", aspect.rawValue); if aspect != oldValue { conformSelections(createIfEmpty: true) } }
    }
    @Published var rotation: Int {
        didSet {
            save("rotation", rotation); refreshDisplay()
            // The ratio refers to the rotated result: keep it when the result turns sideways.
            if (rotation == 90 || rotation == 270) != (oldValue == 90 || oldValue == 270) { conformSelections() }
        }
    }
    @Published var autoSelect: AutoSelect { didSet { save("auto", autoSelect.rawValue) } }
    @Published var folder: URL { didSet { save("folder", folder.path) } }
    @Published var baseName: String { didSet { save("name", baseName) } }
    @Published var format: OutputFormat { didSet { save("format", format.rawValue) } }
    @Published var combinePDF: Bool { didSet { save("combine", combinePDF) } }
    @Published var afterScan: AfterScan { didSet { save("after", afterScan.rawValue) } }
    @Published var afterApp: URL? { didSet { save("afterApp", afterApp?.path ?? "") } }
    @Published var adj: Adjustments { didSet { saveAdj(); refreshDisplay() } }

    // Document (batch) mode
    @Published var batchMode: Bool { didSet { save("batch", batchMode); if !batchMode { stopCountdown() } } }
    @Published var splitSpreads: Bool { didSet { save("split", splitSpreads) } }
    @Published var continuous: Bool { didSet { save("continuous", continuous); if !continuous { stopCountdown() } } }
    @Published var continuousDelay: Int { didSet { save("delay", continuousDelay) } }
    @Published var ocr: Bool { didSet { save("ocr", ocr) } }
    @Published var pages: [BatchPage] = []
    @Published var countdown: Int?
    private var countdownTask: Task<Void, Never>?
    static weak var current: ScannerModel?

    // Preview & selections
    @Published var preview: CGImage? { didSet { refreshDisplay() } }
    @Published var display: CGImage?
    @Published var selections: [Selection] = []
    @Published var activeID: UUID?

    // Activity & results
    @Published var activity: Activity = .idle
    @Published var message: String?
    @Published var isError = false
    @Published var results: [ScanResult] = []
    @Published var showDetails = true

    private let workDir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("EscanerHP-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() {
        let d = UserDefaults.standard
        kind = ScanKind(rawValue: d.string(forKey: "kind") ?? "") ?? .color
        dpi = d.object(forKey: "dpi") as? Int ?? 300
        sizePreset = SizePreset(rawValue: d.string(forKey: "size") ?? "") ?? .a4
        units = Units(rawValue: d.string(forKey: "units") ?? "") ?? .cm
        aspect = AspectLock(rawValue: d.string(forKey: "aspect") ?? "") ?? .free
        rotation = d.object(forKey: "rotation") as? Int ?? 0
        autoSelect = AutoSelect(rawValue: d.string(forKey: "auto") ?? "") ?? .enclosing
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        folder = d.string(forKey: "folder").map { URL(fileURLWithPath: $0) } ?? pictures
        baseName = d.string(forKey: "name") ?? "Escaneo"
        format = OutputFormat(rawValue: d.string(forKey: "format") ?? "") ?? .jpeg
        combinePDF = d.object(forKey: "combine") as? Bool ?? true
        afterScan = AfterScan(rawValue: d.string(forKey: "after") ?? "") ?? .finder
        afterApp = d.string(forKey: "afterApp").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        var a = Adjustments()
        if let data = d.data(forKey: "adj"), let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
            a.manual = (dict["manual"] ?? 0) > 0
            a.brightness = dict["brightness"] ?? 0
            a.contrast = dict["contrast"] ?? 1
            a.saturation = dict["saturation"] ?? 1
            a.sharpness = dict["sharpness"] ?? 0
            a.threshold = dict["threshold"] ?? 0.5
        }
        adj = a
        batchMode = d.object(forKey: "batch") as? Bool ?? false
        splitSpreads = d.object(forKey: "split") as? Bool ?? false
        continuous = d.object(forKey: "continuous") as? Bool ?? false
        continuousDelay = d.object(forKey: "delay") as? Int ?? 8
        ocr = d.object(forKey: "ocr") as? Bool ?? true
        Self.current = self
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
    private func saveAdj() {
        let dict: [String: Double] = ["manual": adj.manual ? 1 : 0, "brightness": adj.brightness, "contrast": adj.contrast,
                                      "saturation": adj.saturation, "sharpness": adj.sharpness, "threshold": adj.threshold]
        defaults.set(try? JSONSerialization.data(withJSONObject: dict), forKey: "adj")
    }

    // MARK: Glass geometry

    var maxW: Int { info?.max_w ?? 2550 }
    var maxH: Int { info?.max_h ?? 3508 }
    var glassAspect: CGFloat { CGFloat(maxW) / CGFloat(maxH) }
    var resolutions: [Int] { info?.resolutions ?? [75, 100, 150, 200, 300, 400, 600, 1200] }

    // The preview is shown rotated like the output; selections stay in glass coordinates.
    var quarterTurn: Bool { rotation == 90 || rotation == 270 }
    var viewAspect: CGFloat { quarterTurn ? 1 / glassAspect : glassAspect }

    /// Glass point (normalized, top-left) → point in the rotated preview.
    func toView(_ p: CGPoint) -> CGPoint { Imaging.toView(p, rotation: rotation) }

    /// Point in the rotated preview → glass point.
    func toGlass(_ v: CGPoint) -> CGPoint { Imaging.toGlass(v, rotation: rotation) }

    func toView(_ r: CGRect) -> CGRect { Self.span(toView(r.origin), toView(CGPoint(x: r.maxX, y: r.maxY))) }
    func toGlass(_ r: CGRect) -> CGRect { Self.span(toGlass(r.origin), toGlass(CGPoint(x: r.maxX, y: r.maxY))) }

    static func span(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Area for the size preset (used when there is no selection).
    var presetRect: CGRect {
        guard let s = sizePreset.inches else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: 0, y: 0, width: min(1, s.width * 300 / CGFloat(maxW)), height: min(1, s.height * 300 / CGFloat(maxH)))
    }

    /// The selections that will be scanned (or the preset area).
    var effectiveSelections: [Selection] { selections.isEmpty ? [Selection(rect: presetRect)] : selections }

    var active: Selection? { selections.first { $0.id == activeID } ?? selections.first }

    /// Inches → value in the current units.
    func toUnits(_ inches: Double) -> Double {
        switch units {
        case .cm: return inches * 2.54
        case .mm: return inches * 25.4
        case .inch: return inches
        case .px: return inches * Double(dpi)
        }
    }

    func fromUnits(_ v: Double) -> Double {
        switch units {
        case .cm: return v / 2.54
        case .mm: return v / 25.4
        case .inch: return v
        case .px: return v / Double(dpi)
        }
    }

    /// Physical size of a normalized rect, in inches.
    func inches(of r: CGRect) -> CGSize {
        CGSize(width: r.width * CGFloat(maxW) / 300, height: r.height * CGFloat(maxH) / 300)
    }

    /// Width/height as seen in the (rotated) result.
    func shownSize(of r: CGRect) -> CGSize {
        let s = inches(of: r)
        return quarterTurn ? CGSize(width: s.height, height: s.width) : s
    }

    func setShownSize(width: Double? = nil, height: Double? = nil) {
        var width = width, height = height
        if let r = aspect.ratio {
            if let w = width { height = w / Double(r) } else if let h = height { width = h * Double(r) }
        }
        defer { if aspect.ratio != nil { conformSelections() } }
        if quarterTurn { setActiveSize(width: height, height: width) } else { setActiveSize(width: width, height: height) }
    }

    func setActiveSize(width: Double? = nil, height: Double? = nil) {
        guard let id = active?.id, let idx = selections.firstIndex(where: { $0.id == id }) else { return }
        var r = selections[idx].rect
        if let w = width { r.size.width = min(1 - r.minX, max(0.01, fromUnits(w) * 300 / Double(maxW))) }
        if let h = height { r.size.height = min(1 - r.minY, max(0.01, fromUnits(h) * 300 / Double(maxH))) }
        selections[idx].rect = r
        selections[idx].quad = nil
    }

    // MARK: Aspect lock (all in normalized preview coordinates)

    /// Height per unit of width, in normalized preview coordinates, for the locked ratio.
    var aspectK: CGFloat? {
        guard let r = aspect.ratio else { return nil }
        let vw = CGFloat(quarterTurn ? maxH : maxW), vh = CGFloat(quarterTurn ? maxW : maxH)
        return vw / (vh * r)
    }

    /// A rect of size w×h centered on `c`, shrunk (keeping its ratio) and shifted to fit the glass.
    static func fitted(center c: CGPoint, w: CGFloat, h: CGFloat) -> CGRect {
        var w = w, h = h
        if w > 1 { h /= w; w = 1 }
        if h > 1 { w /= h; h = 1 }
        return CGRect(x: min(max(0, c.x - w / 2), 1 - w), y: min(max(0, c.y - h / 2), 1 - h), width: w, height: h)
    }

    /// Reshapes a selection to the locked ratio. `inscribe` keeps it inside the original
    /// (for detected photos); otherwise it keeps the area (for switching ratios).
    func conformed(_ s: Selection, inscribe: Bool) -> Selection {
        guard let k = aspectK else { return s }
        let v = toView(s.rect)
        guard v.width > 0, v.height > 0, abs(v.height - v.width * k) > 0.002 else { return s }
        var w: CGFloat, h: CGFloat
        if inscribe {
            w = v.width; h = w * k
            if h > v.height { h = v.height; w = h / k }
        } else {
            w = sqrt(v.width * v.height / k); h = w * k
        }
        var out = s
        out.rect = toGlass(Self.fitted(center: CGPoint(x: v.midX, y: v.midY), w: w, h: h))
        out.quad = nil
        return out
    }

    func conformSelections(createIfEmpty: Bool = false, inscribe: Bool = false) {
        guard let k = aspectK else { return }
        if selections.isEmpty {
            guard createIfEmpty else { return }
            // Nothing selected: start with a centered frame of that ratio.
            var w: CGFloat = 0.7, h = w * k
            if h > 0.7 { h = 0.7; w = h / k }
            let s = Selection(rect: toGlass(Self.fitted(center: CGPoint(x: 0.5, y: 0.5), w: w, h: h)))
            selections = [s]
            activeID = s.id
            return
        }
        selections = selections.map { conformed($0, inscribe: inscribe) }
    }

    func summary(for r: CGRect) -> String {
        let s = shownSize(of: r)
        let px = "\(Int(s.width * CGFloat(dpi))) × \(Int(s.height * CGFloat(dpi))) px"
        let fmt: (Double) -> String = { v in
            self.units == .px ? String(Int(v)) : String(format: self.units == .mm ? "%.0f" : "%.1f", v)
        }
        return "\(fmt(toUnits(s.width))) × \(fmt(toUnits(s.height))) \(units.label) · \(px)"
    }

    // MARK: Device

    func refreshDevice() {
        guard !activity.isBusy else { return }
        device = .checking
        Task.detached {
            let r = Result { try Backend.shared.info() }
            await MainActor.run {
                switch r {
                case .success(let i):
                    self.info = i
                    self.device = (i.state == "Idle") ? .ready : .busy("Ocupado (\(i.state ?? "?"))")
                case .failure(let e):
                    self.device = .unavailable(e.localizedDescription.contains("en uso") ? "En uso por otra app" : "No disponible")
                    self.showError(e)
                }
            }
        }
    }

    // MARK: Overview

    func overview() {
        guard !activity.isBusy else { return }
        activity = .overview(Date())
        message = nil
        isError = false
        let color = kind == .color ? "color" : "gray"
        let target = workDir.appendingPathComponent("overview-\(UUID().uuidString.prefix(6)).jpg")
        let mode = autoSelect
        Task.detached {
            do {
                let url = try Backend.shared.scan(dpi: 75, color: color, region: nil, to: target)
                guard let img = Imaging.load(url) else { throw ScanError.failed("No pude leer la vista general.") }
                let detected = Self.detect(mode, in: img)
                await MainActor.run {
                    self.activity = .idle
                    self.device = .ready
                    self.preview = img
                    if mode != .off {
                        self.selections = detected.map { self.conformed($0, inscribe: true) }
                        self.activeID = detected.first?.id
                    }
                }
            } catch {
                await MainActor.run {
                    self.activity = .idle
                    if case ScanError.cancelled = error { self.message = "Vista general cancelada." } else { self.showError(error) }
                }
            }
        }
    }

    nonisolated static func detect(_ mode: AutoSelect, in img: CGImage) -> [Selection] {
        switch mode {
        case .off: return []
        case .enclosing: return Imaging.detectEnclosingBox(img).map { [Selection(rect: $0)] } ?? []
        case .separate:
            let items = Imaging.detectSeparateItems(img)
            if !items.isEmpty { return items }
            return Imaging.detectEnclosingBox(img).map { [Selection(rect: $0)] } ?? []
        }
    }

    func detectNow() {
        guard let img = preview else { return }
        let found = Self.detect(autoSelect == .off ? .enclosing : autoSelect, in: img)
        selections = found.map { conformed($0, inscribe: true) }
        activeID = found.first?.id
        if found.isEmpty { message = "No encontré nada sobre el vidrio."; isError = false }
    }

    // MARK: Scan

    func scan() {
        guard !activity.isBusy else { return }
        let sels = effectiveSelections
        let union = sels.dropFirst().reduce(sels[0].rect) { $0.union($1.rect) }
        let region = [Int((union.minX * CGFloat(maxW)).rounded(.down)),
                      Int((union.minY * CGFloat(maxH)).rounded(.down)),
                      Int((union.width * CGFloat(maxW)).rounded(.up)),
                      Int((union.height * CGFloat(maxH)).rounded(.up))]
        let scanned = CGRect(x: CGFloat(region[0]) / CGFloat(maxW), y: CGFloat(region[1]) / CGFloat(maxH),
                             width: CGFloat(region[2]) / CGFloat(maxW), height: CGFloat(region[3]) / CGFloat(maxH))
        let kind = self.kind, dpi = self.dpi, adj = self.adj, rotation = self.rotation
        let format = self.format, combine = self.combinePDF, folder = self.folder, base = self.baseName
        let batch = batchMode, split = batchMode && splitSpreads
        let ratio = selections.isEmpty ? nil : aspect.ratio
        let count = sels.count
        stopCountdown()
        let label = batch ? "Escaneando página \(pages.count + 1) a \(dpi) dpi…"
            : (count > 1 ? "Escaneando \(count) elementos a \(dpi) dpi…" : "Escaneando a \(dpi) dpi…")
        activity = .scanning(Date(), label)
        message = nil
        isError = false
        let target = workDir.appendingPathComponent("scan-\(UUID().uuidString.prefix(6)).jpg")
        let pagesDir = workDir.appendingPathComponent("pages")

        Task.detached {
            do {
                let url = try Backend.shared.scan(dpi: dpi, color: kind.driverColor, region: region, to: target)
                await MainActor.run { self.activity = .processing }
                guard let raw = Imaging.load(url) else { throw ScanError.failed("No pude leer la imagen escaneada.") }
                var images: [CGImage] = []
                for sel in sels {
                    let piece = Imaging.extract(sel, from: raw, scanned: scanned)
                    var done = Imaging.process(piece, kind: kind, adj: adj, rotation: rotation)
                    if let r = ratio { done = Imaging.cropToRatio(done, r) }
                    for part in split ? Imaging.splitSpread(done) : [done] {
                        if let cg = Imaging.render(part, gray: kind != .color) { images.append(cg) }
                    }
                }
                try? FileManager.default.removeItem(at: url)

                if batch {
                    // Document mode: keep the pages (on disk) for the PDF instead of saving files.
                    try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
                    var added: [BatchPage] = []
                    for img in images {
                        let lossless = kind == .bw
                        let pageURL = pagesDir.appendingPathComponent("\(UUID().uuidString).\(lossless ? "png" : "jpg")")
                        try Imaging.writePage(img, dpi: dpi, lossless: lossless, to: pageURL)
                        added.append(BatchPage(url: pageURL, thumb: Imaging.thumbnail(img) ?? img, dpi: dpi))
                    }
                    let newPages = added
                    await MainActor.run {
                        let added = newPages
                        self.activity = .idle
                        self.device = .ready
                        self.pages += added
                        self.message = added.count == 1 ? "Página \(self.pages.count) agregada."
                                                        : "Páginas \(self.pages.count - added.count + 1)–\(self.pages.count) agregadas."
                        if self.continuous { self.startCountdown() }
                    }
                    return
                }

                let saved = try Imaging.save(images, dpi: dpi, format: format, combine: combine, folder: folder, base: base)
                try? FileManager.default.removeItem(at: url)
                // Pair each file with its image (a combined PDF shows its first page).
                let results = saved.enumerated().map { i, u in ScanResult(url: u, image: images[min(i, images.count - 1)]) }
                await MainActor.run {
                    self.activity = .idle
                    self.device = .ready
                    self.results = results
                    self.message = saved.count == 1 ? "Guardado: \(saved[0].lastPathComponent)"
                                                    : "Guardados \(saved.count) archivos en \(folder.lastPathComponent)"
                    self.runAfterScan(saved)
                }
            } catch {
                await MainActor.run {
                    self.activity = .idle
                    if case ScanError.cancelled = error { self.message = "Escaneo cancelado." } else { self.showError(error) }
                }
            }
        }
    }

    func cancel() {
        Backend.shared.cancel()
    }

    // MARK: Document (batch) mode

    /// Continuous scanning: count down so the user can turn the page, then scan again.
    func startCountdown() {
        stopCountdown()
        countdown = continuousDelay
        countdownTask = Task { @MainActor in
            while let c = self.countdown, c > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self.countdown = c - 1
            }
            guard !Task.isCancelled, self.countdown == 0 else { return }
            self.countdown = nil
            self.scan()
        }
    }

    func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    func scanNow() {
        stopCountdown()
        scan()
    }

    func removePage(_ p: BatchPage) {
        pages.removeAll { $0.id == p.id }
        try? FileManager.default.removeItem(at: p.url)
    }

    func movePage(_ id: UUID, to target: UUID) {
        guard let from = pages.firstIndex(where: { $0.id == id }),
              let to = pages.firstIndex(where: { $0.id == target }), from != to else { return }
        let p = pages.remove(at: from)
        pages.insert(p, at: to)
    }

    func movePage(_ p: BatchPage, by delta: Int) {
        guard let i = pages.firstIndex(of: p) else { return }
        let j = max(0, min(pages.count - 1, i + delta))
        pages.swapAt(i, j)
    }

    func discardPages(confirm: Bool = true) {
        guard !pages.isEmpty else { return }
        if confirm {
            let a = NSAlert()
            a.messageText = "¿Descartar \(pages.count) página\(pages.count == 1 ? "" : "s")?"
            a.informativeText = "Las páginas escaneadas que todavía no guardaste se van a perder."
            a.addButton(withTitle: "Descartar")
            a.addButton(withTitle: "Cancelar")
            a.buttons[0].hasDestructiveAction = true
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        stopCountdown()
        pages.forEach { try? FileManager.default.removeItem(at: $0.url) }
        pages = []
        message = "Documento descartado."
        isError = false
    }

    /// Writes all pages as one PDF (searchable if OCR is on) to the destination folder.
    func savePDF() {
        guard !pages.isEmpty, !activity.isBusy else { return }
        stopCountdown()
        let list = pages.map { (url: $0.url, dpi: $0.dpi) }
        let total = list.count
        let firstThumb = pages[0].thumb
        let ocr = self.ocr, folder = self.folder
        let base = baseName.trimmingCharacters(in: .whitespaces).isEmpty ? "Escaneo" : baseName
        activity = .saving("Armando el PDF…")
        Task.detached {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = Imaging.nextFreeURL(folder: folder, base: base, ext: "pdf")
                try Imaging.writePDF(pages: list, to: url, ocr: ocr) { i in
                    Task { @MainActor in
                        self.activity = .saving(ocr ? "Reconociendo texto y guardando página \(i + 1) de \(total)…"
                                                    : "Guardando página \(i + 1) de \(total)…")
                    }
                }
                await MainActor.run {
                    self.activity = .idle
                    self.pages.forEach { try? FileManager.default.removeItem(at: $0.url) }
                    self.pages = []
                    self.results = [ScanResult(url: url, image: firstThumb)]
                    self.message = "Guardado: \(url.lastPathComponent) (\(total) página\(total == 1 ? "" : "s"))"
                    self.isError = false
                    self.runAfterScan([url])
                }
            } catch {
                await MainActor.run {
                    self.activity = .idle
                    self.showError(error)
                }
            }
        }
    }

    private func runAfterScan(_ urls: [URL]) {
        switch afterScan {
        case .nothing: break
        case .finder: NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .app:
            if let app = afterApp { open(urls, with: app) } else { urls.forEach { NSWorkspace.shared.open($0) } }
        }
    }

    // MARK: Results: open with / copy

    /// Apps that can open the last results (image editors first, like Finder's "Open With").
    func editorApps() -> [EditorApp] {
        let type: UTType = format == .pdf ? .pdf : format.utType
        return Self.apps(for: type, sample: results.first?.url)
    }

    static func apps(for type: UTType, sample: URL? = nil) -> [EditorApp] {
        var urls = sample.map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []
        if urls.isEmpty { urls = NSWorkspace.shared.urlsForApplications(toOpen: type) }
        var seen = Set<String>()
        return urls.compactMap { u in
            let name = u.deletingPathExtension().lastPathComponent
            guard !seen.contains(name) else { return nil }
            seen.insert(name)
            return EditorApp(url: u)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func defaultApp() -> EditorApp? {
        guard let u = results.first?.url, let app = NSWorkspace.shared.urlForApplication(toOpen: u) else { return nil }
        return EditorApp(url: app)
    }

    func open(_ urls: [URL], with app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Task { @MainActor in self.showError(error) }
            }
        }
    }

    func openResults(with app: URL?) {
        let urls = results.map(\.url)
        guard !urls.isEmpty else { return }
        if let app { open(urls, with: app) } else { urls.forEach { NSWorkspace.shared.open($0) } }
    }

    func chooseOtherApp() -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Abrir"
        panel.message = "Elegí la app con la que querés abrir el escaneo"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Copies the scanned image(s) to the clipboard: image data for editors, plus the file for Finder.
    func copyResults() {
        guard !results.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let items: [NSPasteboardItem] = results.map { r in
            let item = NSPasteboardItem()
            let rep = NSBitmapImageRep(cgImage: r.image)
            if let png = rep.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
            if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
            item.setString(r.url.absoluteString, forType: .fileURL)
            return item
        }
        pb.writeObjects(items)
        message = results.count == 1 ? "Copiado al portapapeles." : "Copiadas \(results.count) imágenes al portapapeles."
        isError = false
    }

    func revealResults() {
        NSWorkspace.shared.activateFileViewerSelecting(results.map(\.url))
    }

    // MARK: Misc

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Elegir"
        if panel.runModal() == .OK, let u = panel.url { folder = u }
    }

    func removeActiveSelection() {
        guard let id = activeID ?? selections.first?.id else { return }
        selections.removeAll { $0.id == id }
        activeID = selections.first?.id
    }

    func showError(_ e: Error) {
        isError = true
        message = e.localizedDescription
    }

    private func refreshDisplay() {
        guard let p = preview else { display = nil; return }
        let out = Imaging.process(CIImage(cgImage: p), kind: kind, adj: adj, rotation: rotation)
        display = Imaging.render(out, gray: false) ?? p
    }
}
