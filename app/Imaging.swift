// Detección de áreas, recorte, corrección y guardado de imágenes.
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// A scan area in normalized glass coordinates (0...1, origin top-left).
/// `quad` (tl, tr, br, bl) is set when the area was detected as a tilted item, for deskewing.
struct Selection: Identifiable, Equatable, Sendable {
    var id = UUID()
    var rect: CGRect
    var quad: [CGPoint]? = nil
}

enum ScanKind: String, CaseIterable, Identifiable, Sendable {
    case color, gray, bw
    var id: String { rawValue }
    var label: String {
        switch self {
        case .color: return "Color"
        case .gray: return "Escala de grises"
        case .bw: return "Blanco y negro"
        }
    }
    /// What the driver asks the scanner for.
    var driverColor: String { self == .color ? "color" : (self == .gray ? "gray" : "bw") }
}

enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg, png, tiff, heic, pdf
    var id: String { rawValue }
    var label: String { rawValue == "jpeg" ? "JPEG" : rawValue.uppercased() }
    var ext: String { self == .jpeg ? "jpg" : rawValue }
    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .tiff: return .tiff
        case .heic: return .heic
        case .pdf: return .pdf
        }
    }
}

struct Adjustments: Equatable, Sendable {
    var manual = false
    var brightness = 0.0   // -0.5 ... 0.5
    var contrast = 1.0     // 0.5 ... 2
    var saturation = 1.0   // 0 ... 2
    var sharpness = 0.0    // 0 ... 2
    var threshold = 0.5    // B&W cut-off
}

enum Imaging {
    static let context = CIContext(options: [.cacheIntermediates: false])

    // MARK: Rotation geometry (normalized, origin top-left; rotations are clockwise)

    static func toView(_ p: CGPoint, rotation: Int) -> CGPoint {
        switch rotation {
        case 90: return CGPoint(x: 1 - p.y, y: p.x)
        case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 270: return CGPoint(x: p.y, y: 1 - p.x)
        default: return p
        }
    }

    static func toGlass(_ v: CGPoint, rotation: Int) -> CGPoint {
        switch rotation {
        case 90: return CGPoint(x: v.y, y: 1 - v.x)
        case 180: return CGPoint(x: 1 - v.x, y: 1 - v.y)
        case 270: return CGPoint(x: 1 - v.y, y: v.x)
        default: return v
        }
    }

    static func load(_ url: URL) -> CGImage? {
        // Decode everything now: a lazily decoded image keeps reading the file later, and
        // big scans came out gray once the temp file was deleted.
        let opts = [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, opts) else { return nil }
        return img
    }

    // MARK: Detection (on the low-res overview of the whole glass)

    /// Bounding box of what's on the glass. Works out first whether the background is dark
    /// (lid open, e.g. a thick notebook) or white (lid closed) and looks for the opposite.
    static func detectEnclosingBox(_ image: CGImage) -> CGRect? {
        if let r = detectOnDarkBackground(image) { return r }
        return detectOnWhiteLid(image)
    }

    static func grayPixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 255, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? pixels : nil
    }

    /// Otsu's threshold and the gap between the two class means.
    static func otsu(_ pixels: [UInt8]) -> (threshold: Int, gap: Double) {
        var hist = [Double](repeating: 0, count: 256)
        for p in pixels { hist[Int(p)] += 1 }
        let total = Double(pixels.count)
        let sumAll = (0..<256).reduce(0.0) { $0 + Double($1) * hist[$1] }
        var wB = 0.0, sumB = 0.0, best = 0.0, t = 128, gap = 0.0
        for i in 0..<256 {
            wB += hist[i]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(i) * hist[i]
            let mB = sumB / wB, mF = (sumAll - sumB) / wF
            let between = wB * wF * (mB - mF) * (mB - mF)
            if between > best { best = between; t = i; gap = mF - mB }
        }
        return (t, gap)
    }

    /// Lid open: the background is dark gray, the item is the largest bright region.
    static func detectOnDarkBackground(_ image: CGImage) -> CGRect? {
        guard let px = grayPixels(image) else { return nil }
        let w = image.width, h = image.height
        let (t, gap) = otsu(px)
        guard gap > 45 else { return nil }  // not two clearly different tones
        // Is the border mostly dark? Then the background is dark.
        let band = max(2, min(w, h) / 50)
        var dark = 0, count = 0
        for y in 0..<h {
            for x in 0..<w where x < band || x >= w - band || y < band || y >= h - band {
                count += 1
                if Int(px[y * w + x]) < t { dark += 1 }
            }
        }
        guard Double(dark) / Double(count) > 0.45 else { return nil }

        // Largest 4-connected bright component.
        var label = [Int32](repeating: 0, count: w * h)
        var bestBox = CGRect.null, bestSize = 0, next: Int32 = 1
        var stack: [Int] = []
        stack.reserveCapacity(w * h / 4)
        for start in 0..<(w * h) where label[start] == 0 && Int(px[start]) >= t {
            label[start] = next
            stack.append(start)
            var size = 0, minX = w, maxX = 0, minY = h, maxY = 0
            while let i = stack.popLast() {
                size += 1
                let x = i % w, y = i / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if x > 0, label[i - 1] == 0, Int(px[i - 1]) >= t { label[i - 1] = next; stack.append(i - 1) }
                if x < w - 1, label[i + 1] == 0, Int(px[i + 1]) >= t { label[i + 1] = next; stack.append(i + 1) }
                if y > 0, label[i - w] == 0, Int(px[i - w]) >= t { label[i - w] = next; stack.append(i - w) }
                if y < h - 1, label[i + w] == 0, Int(px[i + w]) >= t { label[i + w] = next; stack.append(i + w) }
            }
            if size > bestSize {
                bestSize = size
                bestBox = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            }
            next += 1
        }
        guard bestSize > w * h / 50 else { return nil }
        let m = 0.012
        let r = CGRect(x: bestBox.minX / Double(w) - m, y: bestBox.minY / Double(h) - m,
                       width: bestBox.width / Double(w) + 2 * m, height: bestBox.height / Double(h) + 2 * m)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return r.width * r.height < 0.97 ? r : nil
    }

    /// Lid closed: everything that is not lid-white, ignoring dust specks.
    static func detectOnWhiteLid(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard w > 10, h > 10 else { return nil }
        var pixels = [UInt8](repeating: 255, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        // Estimate the lid's white level, then call "content" anything clearly darker.
        let sorted = pixels.sorted()
        let white = Int(sorted[sorted.count * 9 / 10])
        let cut = UInt8(max(0, white - 28))
        let edgeX = max(2, w / 60), edgeY = max(2, h / 60)
        var cols = [Int](repeating: 0, count: w), rows = [Int](repeating: 0, count: h)
        for y in edgeY..<(h - edgeY) {
            let base = y * w
            for x in edgeX..<(w - edgeX) where pixels[base + x] < cut {
                cols[x] += 1
                rows[y] += 1
            }
        }
        let colMin = max(3, h / 80), rowMin = max(3, w / 80)
        guard let x0 = cols.firstIndex(where: { $0 >= colMin }),
              let x1 = cols.lastIndex(where: { $0 >= colMin }),
              let y0 = rows.firstIndex(where: { $0 >= rowMin }),
              let y1 = rows.lastIndex(where: { $0 >= rowMin }),
              x1 > x0, y1 > y0 else { return nil }
        let m = 0.012
        var r = CGRect(x: Double(x0) / Double(w) - m, y: Double(y0) / Double(h) - m,
                       width: Double(x1 - x0) / Double(w) + 2 * m, height: Double(y1 - y0) / Double(h) + 2 * m)
        r = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return r.width * r.height > 0.002 ? r : nil
    }

    /// The document on the glass (page, notebook, photo) via Vision's document segmentation,
    /// which copes with an open lid (gray background) where the white-lid heuristic fails.
    static func detectDocument(_ image: CGImage) -> Selection? {
        let req = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        guard let o = req.results?.first, o.confidence > 0.3 else { return nil }
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: min(1, max(0, p.x)), y: min(1, max(0, 1 - p.y))) }
        let quad = [flip(o.topLeft), flip(o.topRight), flip(o.bottomRight), flip(o.bottomLeft)]
        let xs = quad.map(\.x), ys = quad.map(\.y)
        let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -0.004, dy: -0.004)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard rect.width > 0.05, rect.height > 0.05, rect.width * rect.height < 0.97 else { return nil }
        // Only deskew when the page is visibly tilted; otherwise keep a plain rectangle.
        let tilt = abs(atan2(quad[1].y - quad[0].y, quad[1].x - quad[0].x)) * 180 / .pi
        return Selection(rect: rect, quad: tilt > 0.7 ? quad : nil)
    }

    /// Share of pixels inside `rect` (normalized, top-left) that are clearly darker than the lid.
    static func contentFraction(_ image: CGImage, in rect: CGRect) -> Double {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 255, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        let sorted = pixels.sorted()
        let cut = UInt8(max(0, Int(sorted[sorted.count * 9 / 10]) - 28))
        let x0 = max(0, Int(rect.minX * Double(w))), x1 = min(w, Int(rect.maxX * Double(w)))
        let y0 = max(0, Int(rect.minY * Double(h))), y1 = min(h, Int(rect.maxY * Double(h)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var dark = 0
        for y in y0..<y1 { for x in x0..<x1 where pixels[y * w + x] < cut { dark += 1 } }
        return Double(dark) / Double((x1 - x0) * (y1 - y0))
    }

    /// Separate rectangular items (photos, cards), each with its tilted corners for deskewing.
    static func detectSeparateItems(_ image: CGImage) -> [Selection] {
        let req = VNDetectRectanglesRequest()
        req.maximumObservations = 12
        req.minimumSize = 0.08
        req.minimumAspectRatio = 0.15
        req.maximumAspectRatio = 1.0
        req.quadratureTolerance = 25
        req.minimumConfidence = 0.4
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        let obs = (req.results ?? []).filter { $0.boundingBox.width * $0.boundingBox.height < 0.9 }
        // Vision: normalized, origin bottom-left → ours: origin top-left.
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        var items: [Selection] = obs.map { o in
            let quad = [flip(o.topLeft), flip(o.topRight), flip(o.bottomRight), flip(o.bottomLeft)]
            let bb = o.boundingBox
            let rect = CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
                .insetBy(dx: -0.004, dy: -0.004)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            return Selection(rect: rect, quad: quad)
        }
        // Drop "items" that are just lid texture or the glass edge: real items differ from the lid.
        items = items.filter { contentFraction(image, in: $0.rect) > 0.06 }
        // Drop items nested inside a bigger one (e.g. a photo's inner frame).
        items = items.filter { a in
            !items.contains { b in b.id != a.id && b.rect.contains(a.rect) && b.rect != a.rect }
        }
        return items.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
    }

    // MARK: Processing

    /// Cuts one selection out of a scan that covers `scanned` (normalized glass rect).
    static func extract(_ sel: Selection, from image: CGImage, scanned: CGRect) -> CIImage {
        let ci = CIImage(cgImage: image)
        let W = CGFloat(image.width), H = CGFloat(image.height)
        func px(_ p: CGPoint) -> CGPoint {
            // normalized glass (top-left) → pixel in CI space (bottom-left)
            let x = (p.x - scanned.minX) / scanned.width * W
            let y = (p.y - scanned.minY) / scanned.height * H
            return CGPoint(x: x, y: H - y)
        }
        if let q = sel.quad, q.count == 4 {
            let f = CIFilter.perspectiveCorrection()
            f.inputImage = ci
            f.topLeft = px(q[0])
            f.topRight = px(q[1])
            f.bottomRight = px(q[2])
            f.bottomLeft = px(q[3])
            if let out = f.outputImage { return out }
        }
        let tl = px(CGPoint(x: sel.rect.minX, y: sel.rect.minY))
        let br = px(CGPoint(x: sel.rect.maxX, y: sel.rect.maxY))
        let crop = CGRect(x: tl.x, y: br.y, width: br.x - tl.x, height: tl.y - br.y).integral
        return ci.cropped(to: crop.intersection(ci.extent))
    }

    /// Applies kind (gray / B&W), manual correction and rotation.
    static func process(_ input: CIImage, kind: ScanKind, adj: Adjustments, rotation: Int) -> CIImage {
        var img = input
        if adj.manual {
            let cc = CIFilter.colorControls()
            cc.inputImage = img
            cc.brightness = Float(adj.brightness)
            cc.contrast = Float(adj.contrast)
            cc.saturation = Float(kind == .color ? adj.saturation : 0)
            img = cc.outputImage ?? img
            if adj.sharpness > 0.01 {
                let sh = CIFilter.sharpenLuminance()
                sh.inputImage = img
                sh.sharpness = Float(adj.sharpness)
                sh.radius = 1.5
                img = sh.outputImage ?? img
            }
        } else if kind != .color {
            let cc = CIFilter.colorControls()
            cc.inputImage = img
            cc.saturation = 0
            img = cc.outputImage ?? img
        }
        if kind == .bw {
            let th = CIFilter.colorThreshold()
            th.inputImage = img
            th.threshold = Float(adj.threshold)
            img = th.outputImage ?? img
        }
        switch rotation {
        case 90: img = img.oriented(.right)
        case 180: img = img.oriented(.down)
        case 270: img = img.oriented(.left)
        default: break
        }
        return img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
    }

    static func render(_ img: CIImage, gray: Bool) -> CGImage? {
        if gray {
            return context.createCGImage(img, from: img.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        return context.createCGImage(img, from: img.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    // MARK: Batch documents (books, multi-page PDFs)

    /// Splits an open-book spread into left and right pages (each moved to the origin).
    /// Trims the few pixels of rounding so the result has exactly the ratio (e.g. 1080×1350 for 4:5).
    static func cropToRatio(_ img: CIImage, _ ratio: CGFloat) -> CIImage {
        let e = img.extent.integral
        var w = e.width, h = e.height
        if w / h > ratio { w = (h * ratio).rounded() } else { h = (w / ratio).rounded() }
        guard w > 0, h > 0, w != e.width || h != e.height else { return img }
        let r = CGRect(x: e.minX + ((e.width - w) / 2).rounded(.down), y: e.minY + ((e.height - h) / 2).rounded(.down), width: w, height: h)
        return img.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    static func splitSpread(_ img: CIImage) -> [CIImage] {
        let e = img.extent
        let half = (e.width / 2).rounded()
        let left = img.cropped(to: CGRect(x: e.minX, y: e.minY, width: half, height: e.height))
        let right = img.cropped(to: CGRect(x: e.minX + half, y: e.minY, width: e.width - half, height: e.height))
        return [left, right].map { $0.transformed(by: CGAffineTransform(translationX: -$0.extent.minX, y: -$0.extent.minY)) }
    }

    /// Writes one page to disk (JPEG, or PNG for black & white) so long batches don't fill memory.
    static func writePage(_ img: CGImage, dpi: Int, lossless: Bool, to url: URL) throws {
        let type = (lossless ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw ScanError.failed("No pude guardar la página.")
        }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if !lossless { props[kCGImageDestinationLossyCompressionQuality] = 0.85 }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ScanError.failed("No pude guardar la página.") }
    }

    static func thumbnail(_ img: CGImage, maxSide: CGFloat = 360) -> CGImage? {
        let scale = min(1, maxSide / CGFloat(max(img.width, img.height)))
        let ci = CIImage(cgImage: img).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(ci, from: ci.extent.integral)
    }

    /// Recognized lines of text (Spanish and English), boxes normalized with origin bottom-left.
    static func recognizeText(_ img: CGImage) -> [(String, CGRect)] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["es-ES", "en-US"]
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        return (req.results ?? []).compactMap { o in
            guard let s = o.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            return (s, o.boundingBox)
        }
    }

    /// Builds the PDF page by page, streaming from disk. JPEG pages are embedded as-is
    /// (no recompression). With `ocr`, an invisible text layer makes the PDF searchable.
    static func writePDF(pages: [(url: URL, dpi: Int)], to url: URL, ocr: Bool,
                         progress: (Int) -> Void) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil,
                                  [kCGPDFContextCreator: "Escáner Libre"] as CFDictionary) else {
            throw ScanError.failed("No pude crear el PDF.")
        }
        for (i, page) in pages.enumerated() {
            progress(i)
            try autoreleasepool {
                let image: CGImage?
                if page.url.pathExtension.lowercased() == "jpg", let provider = CGDataProvider(url: page.url as CFURL) {
                    image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                } else {
                    image = load(page.url)
                }
                guard let img = image else { throw ScanError.failed("No pude leer la página \(i + 1).") }
                let w = Double(img.width) / Double(page.dpi) * 72, h = Double(img.height) / Double(page.dpi) * 72
                var box = CGRect(x: 0, y: 0, width: w, height: h)
                ctx.beginPage(mediaBox: &box)
                ctx.draw(img, in: box)
                if ocr {
                    for (text, bb) in recognizeText(img) {
                        drawInvisible(text, in: CGRect(x: bb.minX * w, y: bb.minY * h, width: bb.width * w, height: bb.height * h), ctx: ctx)
                    }
                }
                ctx.endPage()
            }
        }
        ctx.closePDF()
    }

    private static func drawInvisible(_ text: String, in r: CGRect, ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, max(1, r.height * 0.85), nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard lineWidth > 0 else { return }
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        ctx.textMatrix = .identity
        ctx.translateBy(x: r.minX, y: r.minY + r.height * 0.2)
        ctx.scaleBy(x: r.width / lineWidth, y: 1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: Saving

    static func rgbCopy(_ img: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    static func nextFreeURL(folder: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 1
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    static func save(_ images: [CGImage], dpi: Int, format: OutputFormat, combine: Bool,
                     folder: URL, base: String) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = base.trimmingCharacters(in: .whitespaces).isEmpty ? "Escaneo" : base
        var saved: [URL] = []

        if format == .pdf {
            let groups: [[CGImage]] = combine ? [images] : images.map { [$0] }
            for group in groups {
                let doc = PDFDocument()
                for img in group {
                    let pts = NSSize(width: Double(img.width) / Double(dpi) * 72, height: Double(img.height) / Double(dpi) * 72)
                    let ns = NSImage(cgImage: img, size: pts)
                    let page = PDFPage(image: ns, options: [
                        .mediaBox: NSValue(rect: NSRect(origin: .zero, size: pts)),
                        .compressionQuality: 0.85,
                    ])
                    if let page { doc.insert(page, at: doc.pageCount) }
                }
                let url = nextFreeURL(folder: folder, base: name, ext: "pdf")
                guard doc.write(to: url) else { throw ScanError.failed("No pude guardar \(url.lastPathComponent).") }
                saved.append(url)
            }
            return saved
        }

        for img in images {
            let url = nextFreeURL(folder: folder, base: name, ext: format.ext)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
                throw ScanError.failed("No pude crear \(url.lastPathComponent).")
            }
            var props: [CFString: Any] = [
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi,
            ]
            if format == .jpeg || format == .heic {
                props[kCGImageDestinationLossyCompressionQuality] = 0.9
            }
            if format == .tiff {
                props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]  // LZW
            }
            // The HEIC encoder rejects 8-bit grayscale: hand it an RGB copy.
            let toWrite = (format == .heic && img.colorSpace?.model == .monochrome) ? (rgbCopy(img) ?? img) : img
            CGImageDestinationAddImage(dest, toWrite, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw ScanError.failed("No pude guardar \(url.lastPathComponent).") }
            saved.append(url)
        }
        return saved
    }
}
