// Vista previa del vidrio con selecciones editables (crear, mover, redimensionar), al estilo Captura de Imagen.
import AppKit
import SwiftUI

private enum Handle: CaseIterable {
    case tl, t, tr, r, br, b, bl, l

    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .tl: return CGPoint(x: r.minX, y: r.minY)
        case .t: return CGPoint(x: r.midX, y: r.minY)
        case .tr: return CGPoint(x: r.maxX, y: r.minY)
        case .r: return CGPoint(x: r.maxX, y: r.midY)
        case .br: return CGPoint(x: r.maxX, y: r.maxY)
        case .b: return CGPoint(x: r.midX, y: r.maxY)
        case .bl: return CGPoint(x: r.minX, y: r.maxY)
        case .l: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    var cursor: NSCursor {
        switch self {
        case .t, .b: return .resizeUpDown
        case .l, .r: return .resizeLeftRight
        default: return .crosshair
        }
    }
}

private enum DragMode {
    case create(UUID, CGPoint)
    case move(UUID, CGRect)
    case resize(UUID, Handle, CGRect)
}

struct PreviewCanvas: View {
    @ObservedObject var model: ScannerModel
    @State private var drag: DragMode?
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let pad: CGFloat = 28
            let avail = CGSize(width: max(50, geo.size.width - pad * 2), height: max(50, geo.size.height - pad * 2))
            let aspect = model.viewAspect
            let fit: CGSize = avail.width / avail.height > aspect
                ? CGSize(width: avail.height * aspect, height: avail.height)
                : CGSize(width: avail.width, height: avail.width / aspect)

            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.white)
                if let img = model.display {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                } else {
                    placeholder.frame(width: fit.width, height: fit.height)
                }
                overlay(size: fit)
            }
            .frame(width: fit.width, height: fit.height)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand { model.removeActiveSelection() }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 44, weight: .ultraLight))
            Text("Hacé clic en Vista general para ver lo que hay sobre el vidrio")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .foregroundStyle(Color.black.opacity(0.35))
    }

    // MARK: Selections

    private func overlay(size: CGSize) -> some View {
        // Glass rect → points in the (rotated) preview.
        let toView: (CGRect) -> CGRect = { g in
            let r = model.toView(g)
            return CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
        }
        let activeID = model.activeID ?? model.selections.first?.id
        let busy = model.activity.isBusy

        return ZStack(alignment: .topLeading) {
            // Dim what will not be scanned.
            if !model.selections.isEmpty {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    for s in model.selections { p.addRect(toView(s.rect)) }
                }
                .fill(Color.black.opacity(0.18), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            }
            TimelineView(.animation(minimumInterval: 0.08, paused: busy)) { tl in
                let phase = CGFloat(tl.date.timeIntervalSinceReferenceDate * 14).truncatingRemainder(dividingBy: 12)
                ZStack(alignment: .topLeading) {
                    ForEach(model.selections) { s in
                        let r = toView(s.rect)
                        let isActive = s.id == activeID
                        if let q = s.quad, q.count == 4 {
                            Path { p in
                                p.addLines(q.map { g in
                                    let v = model.toView(g)
                                    return CGPoint(x: v.x * size.width, y: v.y * size.height)
                                })
                                p.closeSubpath()
                            }
                            .stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
                        }
                        Rectangle()
                            .path(in: r)
                            .stroke(Color.white, lineWidth: 1.5)
                        Rectangle()
                            .path(in: r)
                            .stroke(isActive ? Color.accentColor : Color.black.opacity(0.8),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 6], dashPhase: phase))
                        if isActive && !busy {
                            ForEach(Array(Handle.allCases.enumerated()), id: \.offset) { _, h in
                                let pt = h.point(in: r)
                                Rectangle()
                                    .fill(Color.white)
                                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                                    .frame(width: 7, height: 7)
                                    .position(pt)
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(dragGesture(size: size, toView: toView), including: busy ? .none : .all)
        .onContinuousHover { phase in
            guard !busy else { return }
            switch phase {
            case .active(let p): cursor(at: p, size: size, toView: toView).set()
            case .ended: NSCursor.arrow.set()
            }
        }
        .contextMenu {
            Button("Detectar automáticamente") { model.detectNow() }.disabled(model.preview == nil)
            Button("Seleccionar todo el vidrio") {
                let s = model.conformed(Selection(rect: CGRect(x: 0, y: 0, width: 1, height: 1)), inscribe: true)
                model.selections = [s]
                model.activeID = s.id
            }
            Divider()
            Button("Quitar selección") { model.removeActiveSelection() }.disabled(model.selections.isEmpty)
            Button("Quitar todas") { model.selections = [] }.disabled(model.selections.isEmpty)
        }
    }

    private func hitHandle(_ p: CGPoint, _ r: CGRect) -> Handle? {
        Handle.allCases.first { h in
            let c = h.point(in: r)
            return abs(c.x - p.x) <= 7 && abs(c.y - p.y) <= 7
        }
    }

    private func cursor(at p: CGPoint, size: CGSize, toView: (CGRect) -> CGRect) -> NSCursor {
        if let a = model.active, let h = hitHandle(p, toView(a.rect)) { return h.cursor }
        if model.selections.contains(where: { toView($0.rect).contains(p) }) { return .openHand }
        return .crosshair
    }

    private func dragGesture(size: CGSize, toView: @escaping (CGRect) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                focused = true
                let norm = { (p: CGPoint) in
                    CGPoint(x: min(1, max(0, p.x / size.width)), y: min(1, max(0, p.y / size.height)))
                }
                if drag == nil {
                    let start = v.startLocation
                    // Drag modes keep their geometry in preview (rotated) coordinates.
                    if let a = model.active, let h = hitHandle(start, toView(a.rect)) {
                        drag = .resize(a.id, h, model.toView(a.rect))
                    } else if let s = model.selections.last(where: { toView($0.rect).contains(start) }) {
                        model.activeID = s.id
                        drag = .move(s.id, model.toView(s.rect))
                    } else {
                        let s = Selection(rect: model.toGlass(CGRect(origin: norm(start), size: .zero)))
                        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
                            model.selections.append(s)
                        } else {
                            model.selections = [s]
                        }
                        model.activeID = s.id
                        drag = .create(s.id, norm(start))
                    }
                }
                let cur = norm(v.location)
                switch drag {
                case .create(let id, let origin):
                    update(id) { _ in
                        if let k = model.aspectK { return Self.aspectRect(from: origin, to: cur, k: k) }
                        return CGRect(x: min(origin.x, cur.x), y: min(origin.y, cur.y),
                                      width: abs(cur.x - origin.x), height: abs(cur.y - origin.y))
                    }
                case .move(let id, let orig):
                    let dx = v.translation.width / size.width, dy = v.translation.height / size.height
                    update(id) { _ in
                        var r = orig.offsetBy(dx: dx, dy: dy)
                        r.origin.x = min(max(0, r.origin.x), 1 - r.width)
                        r.origin.y = min(max(0, r.origin.y), 1 - r.height)
                        return r
                    }
                case .resize(let id, let h, let orig):
                    update(id) { _ in
                        if let k = model.aspectK { return Self.aspectResize(orig, handle: h, to: cur, k: k) }
                        return resize(orig, handle: h, to: cur)
                    }
                case nil:
                    break
                }
            }
            .onEnded { _ in
                if case .create(let id, _) = drag,
                   let s = model.selections.first(where: { $0.id == id }),
                   s.rect.width < 0.01 || s.rect.height < 0.01 {
                    // A click on the empty glass: remove the tiny selection (= scan the chosen size).
                    model.selections.removeAll { $0.id == id }
                    model.activeID = model.selections.first?.id
                }
                drag = nil
            }
    }

    /// `f` returns the new rect in preview coordinates; it is stored in glass coordinates.
    private func update(_ id: UUID, _ f: (CGRect) -> CGRect) {
        guard let i = model.selections.firstIndex(where: { $0.id == id }) else { return }
        var s = model.selections[i]
        s.rect = model.toGlass(f(model.toView(s.rect)))
        s.quad = nil  // edited by hand: no deskew
        model.selections[i] = s
    }

    /// Rect with ratio `k` (height per width) from the fixed corner `a` toward `p`, inside the glass.
    static func aspectRect(from a: CGPoint, to p: CGPoint, k: CGFloat) -> CGRect {
        let right = p.x >= a.x, down = p.y >= a.y
        var w = abs(p.x - a.x), h = abs(p.y - a.y)
        if h > w * k { w = h / k } else { h = w * k }  // follow the longer drag
        let maxW = right ? 1 - a.x : a.x, maxH = down ? 1 - a.y : a.y
        if w > maxW { w = maxW; h = w * k }
        if h > maxH { h = maxH; w = h / k }
        return CGRect(x: right ? a.x : a.x - w, y: down ? a.y : a.y - h, width: w, height: h)
    }

    /// Ratio-locked resize: corners pivot on the opposite corner, edges grow around the center line.
    private static func aspectResize(_ r: CGRect, handle: Handle, to p: CGPoint, k: CGFloat) -> CGRect {
        switch handle {
        case .tl: return aspectRect(from: CGPoint(x: r.maxX, y: r.maxY), to: p, k: k)
        case .tr: return aspectRect(from: CGPoint(x: r.minX, y: r.maxY), to: p, k: k)
        case .br: return aspectRect(from: CGPoint(x: r.minX, y: r.minY), to: p, k: k)
        case .bl: return aspectRect(from: CGPoint(x: r.maxX, y: r.minY), to: p, k: k)
        case .l, .r:
            let a = handle == .r ? r.minX : r.maxX
            var w = max(0, handle == .r ? p.x - a : a - p.x), h = w * k
            let maxH = 2 * min(r.midY, 1 - r.midY)
            if h > maxH { h = maxH; w = h / k }
            return CGRect(x: handle == .r ? a : a - w, y: r.midY - h / 2, width: w, height: h)
        case .t, .b:
            let a = handle == .b ? r.minY : r.maxY
            var h = max(0, handle == .b ? p.y - a : a - p.y), w = h / k
            let maxW = 2 * min(r.midX, 1 - r.midX)
            if w > maxW { w = maxW; h = w * k }
            return CGRect(x: r.midX - w / 2, y: handle == .b ? a : a - h, width: w, height: h)
        }
    }

    private func resize(_ r: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .tl: minX = p.x; minY = p.y
        case .t: minY = p.y
        case .tr: maxX = p.x; minY = p.y
        case .r: maxX = p.x
        case .br: maxX = p.x; maxY = p.y
        case .b: maxY = p.y
        case .bl: minX = p.x; maxY = p.y
        case .l: minX = p.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }
}
