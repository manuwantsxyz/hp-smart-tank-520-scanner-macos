// Banco de pruebas: ejercita Backend + Imaging con el escáner real, sin la interfaz.
import AppKit
import CoreImage

func check(_ ok: Bool, _ msg: String) {
    print(ok ? "✅ \(msg)" : "❌ \(msg)")
    if !ok { exit(1) }
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// 1. Rotation: a 200×100 image, red on the left → 90° clockwise puts red on top.
let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
let blue = CIImage(color: .blue).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
let test = red.composited(over: blue)
let rot = Imaging.render(Imaging.process(test, kind: .color, adj: Adjustments(), rotation: 90), gray: false)!
check(rot.width == 100 && rot.height == 200, "rotación 90°: tamaño \(rot.width)×\(rot.height)")
let rep = NSBitmapImageRep(cgImage: rot)
let top = rep.colorAt(x: 50, y: 10)!, bottom = rep.colorAt(x: 50, y: 190)!
check(top.redComponent > 0.9 && bottom.blueComponent > 0.9, "rotación 90° es en sentido horario (rojo arriba)")

// 2. Scanner info
let info = try Backend.shared.info()
check(info.max_w > 0 && info.state == "Idle", "info: \(info.model ?? "?") \(info.max_w)×\(info.max_h), \(info.state ?? "?")")

// 3. Overview + detection
var t = Date()
let ov = try Backend.shared.scan(dpi: 75, color: "color", region: nil, to: out.appendingPathComponent("overview.jpg"))
let ovImg = Imaging.load(ov)!
print("   vista general \(ovImg.width)×\(ovImg.height) en \(String(format: "%.1f", Date().timeIntervalSince(t))) s")
let box = Imaging.detectEnclosingBox(ovImg)
print("   recuadro detectado: \(box.map { "\($0)" } ?? "ninguno (vidrio vacío)")")
let items = Imaging.detectSeparateItems(ovImg)
print("   elementos separados: \(items.count)")

// 4. Region scan of two "items" → one job, cropped locally
let a = Selection(rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2))
let b = Selection(rect: CGRect(x: 0.5, y: 0.4, width: 0.3, height: 0.25),
                  quad: [CGPoint(x: 0.52, y: 0.4), CGPoint(x: 0.8, y: 0.42), CGPoint(x: 0.78, y: 0.65), CGPoint(x: 0.5, y: 0.63)])
let union = a.rect.union(b.rect)
let region = [Int(union.minX * 2550), Int(union.minY * 3508), Int(union.width * 2550), Int(union.height * 3508)]
let scanned = CGRect(x: CGFloat(region[0]) / 2550, y: CGFloat(region[1]) / 3508,
                     width: CGFloat(region[2]) / 2550, height: CGFloat(region[3]) / 3508)
t = Date()
let hi = try Backend.shared.scan(dpi: 150, color: "gray", region: region, to: out.appendingPathComponent("raw.jpg"))
let raw = Imaging.load(hi)!
print("   región \(raw.width)×\(raw.height) px a 150 dpi en \(String(format: "%.1f", Date().timeIntervalSince(t))) s")
check(abs(raw.width - region[2] * 150 / 300) <= 2, "el ancho escaneado coincide con la región pedida")

var imgs: [CGImage] = []
for (i, s) in [a, b].enumerated() {
    let piece = Imaging.extract(s, from: raw, scanned: scanned)
    let done = Imaging.process(piece, kind: .bw, adj: Adjustments(manual: true, contrast: 1.3, sharpness: 0.5), rotation: 0)
    let cg = Imaging.render(done, gray: true)!
    imgs.append(cg)
    print("   elemento \(i + 1): \(cg.width)×\(cg.height) px")
}
let expectA = Int(0.3 * 2550 / 2), expectAh = Int(0.2 * 3508 / 2)
check(abs(imgs[0].width - expectA) <= 3 && abs(imgs[0].height - expectAh) <= 3, "recorte del elemento 1 (\(expectA)×\(expectAh) esperado)")

// 5. Save in every format
for f in OutputFormat.allCases {
    let urls = try Imaging.save(imgs, dpi: 150, format: f, combine: true, folder: out, base: "prueba")
    let sizes = urls.map { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0 }
    check(!urls.isEmpty && sizes.allSatisfy { $0 > 0 }, "\(f.label): \(urls.map(\.lastPathComponent).joined(separator: ", "))")
}
// PDF page size = physical size
let pdf = PDFDocumentCheck.pageInches(out.appendingPathComponent("prueba.pdf"))
check(abs(pdf.width - 0.3 * 2550 / 300) < 0.05, "PDF con tamaño físico correcto (\(String(format: "%.2f", pdf.width)) pulg. de ancho)")

// 6. Document mode: open-book spread → split → pages on disk → searchable PDF
func spread() -> CGImage {
    let w = 2400, h = 1650  // two 4"×5.5" pages at 300 dpi
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(.white)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 90), .foregroundColor: NSColor.black]
    ("Capítulo uno" as NSString).draw(at: NSPoint(x: 150, y: 1100), withAttributes: attrs)
    ("izquierda" as NSString).draw(at: NSPoint(x: 150, y: 900), withAttributes: attrs)
    ("Página derecha" as NSString).draw(at: NSPoint(x: 1350, y: 1100), withAttributes: attrs)
    NSGraphicsContext.current = nil
    return ctx.makeImage()!
}
let halves = Imaging.splitSpread(CIImage(cgImage: spread()))
check(halves.count == 2 && Int(halves[0].extent.width) == 1200, "libro abierto dividido en 2 páginas de 1200 px")
var pageList: [(url: URL, dpi: Int)] = []
for (i, half) in halves.enumerated() {
    let cg = Imaging.render(half, gray: false)!
    let u = out.appendingPathComponent("pagina-\(i).jpg")
    try Imaging.writePage(cg, dpi: 300, lossless: false, to: u)
    pageList.append((u, 300))
}
pageList.append(pageList[0])  // a third page, like a longer book
let pdfURL = out.appendingPathComponent("libro.pdf")
t = Date()
try Imaging.writePDF(pages: pageList, to: pdfURL, ocr: true) { _ in }
let doc = PDFKitDoc.open(pdfURL)
check(doc.count == 3, "PDF con \(doc.count) páginas (\(String(format: "%.1f", Date().timeIntervalSince(t))) s con OCR)")
check(abs(doc.sizes[0].width - 4) < 0.02 && abs(doc.sizes[0].height - 5.5) < 0.02,
      "tamaño de página físico \(String(format: "%.2f × %.2f", doc.sizes[0].width, doc.sizes[0].height)) pulg.")
check(doc.texts[0].localizedCaseInsensitiveContains("capítulo") && doc.texts[0].localizedCaseInsensitiveContains("izquierda"),
      "texto buscable en la página 1: \"\(doc.texts[0].replacingOccurrences(of: "\n", with: " / "))\"")
check(doc.texts[1].localizedCaseInsensitiveContains("derecha") && !doc.texts[1].localizedCaseInsensitiveContains("izquierda"),
      "texto buscable en la página 2: \"\(doc.texts[1].replacingOccurrences(of: "\n", with: " / "))\"")
let pdfSize = (try FileManager.default.attributesOfItem(atPath: pdfURL.path)[.size] as? Int) ?? 0
let jpgSize = pageList.map { (try? FileManager.default.attributesOfItem(atPath: $0.url.path)[.size] as? Int) ?? 0 }.reduce(0, +)
check(pdfSize < jpgSize * 2, "el PDF no recomprime las páginas (\(pdfSize / 1024) KB vs \(jpgSize / 1024) KB de JPEG)")

// 7. Apps that can open a JPEG (for "Abrir con")
let apps = NSWorkspace.shared.urlsForApplications(toOpen: .jpeg).map { $0.deletingPathExtension().lastPathComponent }
print("   apps para JPEG: \(apps.prefix(15).joined(separator: ", "))")
print("Todo OK")
