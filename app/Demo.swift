// Screenshots for the README: `ESCANER_DEMO=<output folder>` opens the app with sample content
// (a generated page and photo, never a real scan), captures the window in a few scenes and quits.
// It doesn't touch the scanner and restores the saved settings afterwards.
import AppKit
import SwiftUI

enum Demo {
    static let outDir: URL? = ProcessInfo.processInfo.environment["ESCANER_DEMO"].map { URL(fileURLWithPath: $0) }

    // Sample items on the glass (normalized, top-left origin).
    static let docRect = CGRect(x: 0.06, y: 0.05, width: 0.54, height: 0.55)
    static let photoRect = CGRect(x: 0.32, y: 0.65, width: 0.60, height: 0.28)

    @MainActor
    static func run(_ m: ScannerModel) async {
        guard let out = outDir else { return }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let domain = Bundle.main.bundleIdentifier ?? ""
        let saved = UserDefaults.standard.persistentDomain(forName: domain)
        // Keep running while in the background (App Nap would stall the timers).
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Demo screenshots")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        NSApp.activate(ignoringOtherApps: true)

        try? await Task.sleep(for: .seconds(1))
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { NSApp.terminate(nil); return }
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.center()

        m.info = ScannerInfo(state: "Idle", model: "HP Smart Tank 520_540 series", max_w: 2550, max_h: 3508,
                             resolutions: [75, 100, 150, 200, 300, 400, 600, 1200])
        m.device = .ready
        m.message = nil
        m.batchMode = false
        m.kind = .color
        m.dpi = 300
        m.rotation = 0
        m.aspect = .free
        m.autoSelect = .separate
        m.afterScan = .finder
        m.adj = Adjustments()
        m.showDetails = true
        let glass = glassImage()
        m.preview = glass

        // 1. Overview with two detected items.
        let doc = Selection(rect: docRect), photo = Selection(rect: photoRect)
        m.selections = [doc, photo]
        m.activeID = photo.id
        let photoCrop = crop(glass, photoRect)
        m.results = [ScanResult(url: URL(fileURLWithPath: NSHomeDirectory() + "/Pictures/Scans/Scan 2.jpg"), image: photoCrop),
                     ScanResult(url: URL(fileURLWithPath: NSHomeDirectory() + "/Pictures/Scans/Scan 1.jpg"), image: crop(glass, docRect))]
        await snap(window, out.appendingPathComponent("overview.png"))

        // 2. Aspect-ratio lock (4:5) on the photo.
        m.results = []
        m.selections = [Selection(rect: photoRect.insetBy(dx: 0.02, dy: 0.01))]
        m.activeID = m.selections[0].id
        m.aspect = .r4x5
        await snap(window, out.appendingPathComponent("aspect-ratio.png"))

        // 3. Document PDF mode with a few pages.
        m.aspect = .free
        m.selections = [Selection(rect: docRect)]
        m.activeID = m.selections[0].id
        m.batchMode = true
        m.pages = (1...6).map { i in
            BatchPage(url: out.appendingPathComponent("unused-\(i).jpg"), thumb: page(number: i), dpi: 300)
        }
        await snap(window, out.appendingPathComponent("document-pdf.png"))

        m.pages = []
        m.selections = []
        if let saved { UserDefaults.standard.setPersistentDomain(saved, forName: domain) }
        else { UserDefaults.standard.removePersistentDomain(forName: domain) }
        NSApp.terminate(nil)
    }

    @MainActor
    private static func snap(_ window: NSWindow, _ url: URL) async {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(1.5))
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func crop(_ img: CGImage, _ r: CGRect) -> CGImage {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        return img.cropping(to: CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h)) ?? img
    }

    // MARK: Sample content

    private static func context(_ w: Int, _ h: Int, draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)  // top-left origin
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    private static func text(_ s: String, _ p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, gray: CGFloat = 0.15) {
        (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                     .foregroundColor: NSColor(white: gray, alpha: 1)])
    }

    /// The glass at 150 dpi: lid, a printed page and a landscape photo.
    static func glassImage() -> CGImage {
        let W = 1275, H = 1754
        return context(W, H) { ctx in
            ctx.setFillColor(CGColor(gray: 0.93, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            let d = CGRect(x: docRect.minX * CGFloat(W), y: docRect.minY * CGFloat(H), width: docRect.width * CGFloat(W), height: docRect.height * CGFloat(H))
            ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: CGColor(gray: 0, alpha: 0.25))
            ctx.setFillColor(.white)
            ctx.fill(d)
            ctx.setShadow(offset: .zero, blur: 0)
            text("Field Notes", CGPoint(x: d.minX + 50, y: d.minY + 50), size: 40, weight: .bold)
            text("Spring garden plan", CGPoint(x: d.minX + 50, y: d.minY + 105), size: 22, gray: 0.4)
            var y = d.minY + 170
            for i in 0..<22 {
                let len = [0.92, 0.85, 0.97, 0.6, 0.9, 0.95, 0.7][i % 7]
                if i == 9 { y += 30; text("Planting schedule", CGPoint(x: d.minX + 50, y: y - 10), size: 24, weight: .semibold); y += 40 }
                ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
                ctx.fill(CGRect(x: d.minX + 50, y: y, width: (d.width - 100) * len, height: 7))
                y += 24
            }
            // Photo: sunset over hills.
            let p = CGRect(x: photoRect.minX * CGFloat(W), y: photoRect.minY * CGFloat(H), width: photoRect.width * CGFloat(W), height: photoRect.height * CGFloat(H))
            ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: CGColor(gray: 0, alpha: 0.3))
            ctx.setFillColor(.white)
            ctx.fill(p)
            ctx.setShadow(offset: .zero, blur: 0)
            let img = p.insetBy(dx: 18, dy: 18)
            ctx.saveGState()
            ctx.clip(to: img)
            let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                CGColor(red: 0.20, green: 0.25, blue: 0.55, alpha: 1), CGColor(red: 0.95, green: 0.55, blue: 0.35, alpha: 1),
                CGColor(red: 1.0, green: 0.85, blue: 0.55, alpha: 1)] as CFArray, locations: [0, 0.6, 1])!
            ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: img.minY), end: CGPoint(x: 0, y: img.maxY), options: [])
            ctx.setFillColor(CGColor(red: 1, green: 0.93, blue: 0.7, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: img.minX + img.width * 0.62, y: img.minY + img.height * 0.38, width: 90, height: 90))
            for (k, shade) in [(0.0, 0.32), (1.0, 0.2)] {
                ctx.setFillColor(CGColor(red: 0.15 + shade * 0.3, green: 0.25 + shade * 0.4, blue: 0.2 + shade * 0.2, alpha: 1))
                ctx.move(to: CGPoint(x: img.minX, y: img.maxY))
                for s in stride(from: 0.0, through: 1.0, by: 0.05) {
                    let yy = img.minY + img.height * (0.62 + 0.1 * k + 0.08 * sin(s * 7 + k * 2))
                    ctx.addLine(to: CGPoint(x: img.minX + img.width * s, y: yy))
                }
                ctx.addLine(to: CGPoint(x: img.maxX, y: img.maxY))
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
    }

    /// A book page for the Document PDF strip.
    static func page(number n: Int) -> CGImage {
        context(260, 360) { ctx in
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: 260, height: 360))
            if n == 1 {
                text("Chapter One", CGPoint(x: 24, y: 70), size: 22, weight: .bold)
            }
            var y: CGFloat = n == 1 ? 120 : 30
            var i = n
            while y < 320 {
                ctx.setFillColor(CGColor(gray: 0.6, alpha: 1))
                ctx.fill(CGRect(x: 24, y: y, width: 212 * [0.95, 0.9, 1, 0.7, 0.93][i % 5], height: 4))
                y += 13; i += 1
            }
            text("\(n)", CGPoint(x: 124, y: 334), size: 10, gray: 0.5)
        }
    }
}
