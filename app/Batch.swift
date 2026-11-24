// Tira de páginas del modo Documento: miniaturas reordenables, borrar, guardar el PDF.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PagesStrip: View {
    @ObservedObject var model: ScannerModel
    @State private var dragging: UUID?

    var body: some View {
        HStack(spacing: 0) {
            if model.pages.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "doc.on.doc")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("Modo Documento: cada escaneo agrega páginas acá. Cuando termines, guardá el PDF.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .bottom, spacing: 14) {
                            ForEach(Array(model.pages.enumerated()), id: \.element.id) { idx, page in
                                PageThumb(model: model, page: page, number: idx + 1, dragging: $dragging)
                                    .id(page.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: model.pages.count) {
                        if let last = model.pages.last?.id {
                            withAnimation { proxy.scrollTo(last, anchor: .trailing) }
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .trailing, spacing: 8) {
                Text(model.pages.isEmpty ? "Sin páginas" : "\(model.pages.count) página\(model.pages.count == 1 ? "" : "s")")
                    .font(.headline)
                Button("Guardar PDF") { model.savePDF() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.pages.isEmpty || model.activity.isBusy)
                Button("Descartar") { model.discardPages() }
                    .disabled(model.pages.isEmpty || model.activity.isBusy)
            }
            .padding(14)
            .frame(width: 170)
        }
        .frame(height: 150)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct PageThumb: View {
    @ObservedObject var model: ScannerModel
    let page: BatchPage
    let number: Int
    @Binding var dragging: UUID?
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            Image(decorative: page.thumb, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 110, maxHeight: 100)
                .background(Color.white)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .opacity(dragging == page.id ? 0.4 : 1)
                .overlay(alignment: .topTrailing) {
                    if hover {
                        Button {
                            model.removePage(page)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.7))
                                .font(.system(size: 16))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .help("Quitar página")
                    }
                }
            Text("\(number)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(page.url) }
        .onDrag {
            dragging = page.id
            return NSItemProvider(object: page.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: PageDrop(target: page.id, model: model, dragging: $dragging))
        .contextMenu {
            Button("Mover a la izquierda") { model.movePage(page, by: -1) }.disabled(number == 1)
            Button("Mover a la derecha") { model.movePage(page, by: 1) }.disabled(number == model.pages.count)
            Divider()
            Button("Abrir en Vista Previa") { NSWorkspace.shared.open(page.url) }
            Divider()
            Button("Quitar página") { model.removePage(page) }
        }
        .help("Arrastrá para reordenar · doble clic para abrir")
    }
}

/// Live reordering while dragging a thumbnail over another.
private struct PageDrop: DropDelegate {
    let target: UUID
    let model: ScannerModel
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target else { return }
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.15)) { model.movePage(d, to: target) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
