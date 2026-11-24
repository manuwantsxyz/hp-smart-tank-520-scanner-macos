// Pruebas del bloqueo de proporción (sin escáner).
import AppKit
import CoreImage

func check(_ ok: Bool, _ msg: String) { print(ok ? "✅ \(msg)" : "❌ \(msg)"); if !ok { exit(1) } }

MainActor.assumeIsolated {
    let m = ScannerModel()
    let saved = (m.aspect, m.rotation)
    m.selections = []
    m.rotation = 0
    @MainActor func shown(_ s: Selection) -> CGFloat { let z = m.shownSize(of: s.rect); return z.width / z.height }

    m.aspect = .r4x5
    check(m.selections.count == 1 && abs(shown(m.selections[0]) - 0.8) < 0.001, "elegir 4:5 crea un marco 4:5 (\(shown(m.selections[0])))")
    m.aspect = .r9x16
    check(abs(shown(m.selections[0]) - 9.0 / 16) < 0.001, "cambiar a 9:16 adapta el marco")
    m.aspect = m.aspect.flipped
    check(m.aspect == .r16x9 && abs(shown(m.selections[0]) - 16.0 / 9) < 0.001, "invertir → 16:9 horizontal")
    let r = m.selections[0].rect
    check(r.minX >= 0 && r.minY >= 0 && r.maxX <= 1.0001 && r.maxY <= 1.0001, "el marco queda dentro del vidrio")

    m.rotation = 90
    check(abs(shown(m.selections[0]) - 16.0 / 9) < 0.001, "con rotación 90° el resultado sigue siendo 16:9")

    // Drawing and resizing with the lock (preview coordinates).
    let k = m.aspectK!
    let drawn = PreviewCanvas.aspectRect(from: CGPoint(x: 0.9, y: 0.9), to: CGPoint(x: 0.1, y: 0.85), k: k)
    m.selections = [Selection(rect: m.toGlass(drawn))]
    check(abs(shown(m.selections[0]) - 16.0 / 9) < 0.001 && drawn.maxX <= 0.9001 && drawn.minX >= 0, "dibujar hacia arriba-izquierda respeta 16:9 y el borde")
    let big = PreviewCanvas.aspectRect(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 1, y: 1), k: 1 / 0.01)
    check(big.maxY <= 1.0001 && big.maxX <= 1.0001, "un arrastre largo se limita al vidrio")

    // Numeric fields keep the ratio.
    m.rotation = 0
    m.aspect = .r1x1
    m.units = .cm
    m.setShownSize(width: 10)
    let z = m.shownSize(of: m.selections[0].rect)
    check(abs(z.width * 2.54 - 10) < 0.05 && abs(z.width - z.height) < 0.01, "escribir 10 cm de ancho → 10 × 10 cm")

    // Detection keeps the frame inside the found photo.
    let photo = Selection(rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.3))
    let c = m.conformed(photo, inscribe: true)
    check(photo.rect.insetBy(dx: -0.0001, dy: -0.0001).contains(c.rect) && abs(shown(c) - 1) < 0.001, "el recuadro detectado se recorta a 1:1 por dentro")

    // Exact pixels.
    let img = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1083, height: 1361))
    let e = Imaging.cropToRatio(img, 0.8).extent
    check(e.width == 1083 && e.height == 1354 && e.minX == 0, "recorte exacto a 4:5: \(Int(e.width))×\(Int(e.height))")
    let e2 = Imaging.cropToRatio(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1080, height: 1352)), 0.8).extent
    check(e2.width == 1080 && e2.height == 1350, "1080×1352 → 1080×1350")

    m.aspect = saved.0; m.rotation = saved.1
    print("Todo OK")
}
