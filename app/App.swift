// Escáner Libre — la experiencia de escaneo de Captura de Imagen para la HP Smart Tank 520 (y otras impresoras eSCL),
// hablando eSCL directo por USB (sin ippusbd ni drivers de HP).
import AppKit
import SwiftUI

@main
struct EscanerHPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = ScannerModel()

    var body: some Scene {
        Window("Escáner Libre", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Escáner") {
                Button("Vista general") { model.overview() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(model.activity.isBusy)
                Button("Escanear") { model.scan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.activity.isBusy)
                Button("Cancelar") { model.cancel(); model.stopCountdown() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.activity.isCancellable && model.countdown == nil)
                Divider()
                Button("Modo Documento PDF") { model.batchMode.toggle() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Guardar documento PDF") { model.savePDF() }
                    .disabled(model.pages.isEmpty || model.activity.isBusy)
                Button("Descartar páginas") { model.discardPages() }
                    .disabled(model.pages.isEmpty || model.activity.isBusy)
                Divider()
                Button("Detectar áreas") { model.detectNow() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.preview == nil)
                Button("Quitar selección") { model.removeActiveSelection() }
                    .disabled(model.selections.isEmpty)
                Divider()
                Button("Buscar escáner de nuevo") { model.refreshDevice() }
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cortar") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x")
                Button("Copiar") {
                    // In a text field, copy text; otherwise copy the last scan.
                    if NSApp.keyWindow?.firstResponder is NSText {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    } else {
                        model.copyResults()
                    }
                }
                .keyboardShortcut("c")
                Button("Pegar") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v")
                Button("Seleccionar todo") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                    .keyboardShortcut("a")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { Backend.shared.cancel() }

    /// Don't lose a document in progress (e.g. half a book) on quit.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let m = ScannerModel.current, !m.pages.isEmpty else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "Tenés \(m.pages.count) página\(m.pages.count == 1 ? "" : "s") sin guardar"
        a.informativeText = "Si salís ahora, el documento en curso se pierde."
        a.addButton(withTitle: "Cancelar")
        a.addButton(withTitle: "Salir sin guardar")
        a.buttons[1].hasDestructiveAction = true
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct ContentView: View {
    @ObservedObject var model: ScannerModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    PreviewCanvas(model: model)
                    if model.showDetails {
                        Divider()
                        Inspector(model: model)
                            .frame(width: 360)
                            .transition(.move(edge: .trailing))
                    }
                }
                if !model.results.isEmpty {
                    Divider()
                    ResultsBar(model: model)
                }
                if model.batchMode {
                    Divider()
                    PagesStrip(model: model)
                }
                Divider()
                BottomBar(model: model)
            }
            .navigationTitle(model.info?.model ?? "Escáner Libre")
        }
        .onAppear {
            if Demo.outDir != nil { Task { await Demo.run(model) } } else { model.refreshDevice() }
        }
    }

    private var sidebar: some View {
        List(selection: .constant("hp")) {
            Section("Dispositivos") {
                HStack(spacing: 8) {
                    Image(systemName: "scanner")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.info?.model ?? "Impresora USB")
                            .lineLimit(1)
                        Text("USB · \(model.device.label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Circle().fill(model.device.color).frame(width: 7, height: 7)
                }
                .tag("hp")
                .contextMenu { Button("Buscar de nuevo") { model.refreshDevice() } }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.refreshDevice()
            } label: {
                Label("Buscar de nuevo", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.activity.isBusy)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BottomBar: View {
    @ObservedObject var model: ScannerModel

    var body: some View {
        HStack(spacing: 10) {
            Button(model.showDetails ? "Ocultar detalles" : "Mostrar detalles") {
                withAnimation(.easeInOut(duration: 0.2)) { model.showDetails.toggle() }
            }
            Spacer()
            status
            Spacer()
            if model.activity.isBusy {
                Button("Cancelar") { model.cancel() }
                    .disabled(!model.activity.isCancellable)
            } else if model.countdown != nil {
                Button("Pausar") { model.stopCountdown() }
                Button("Escanear ahora") { model.scanNow() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Vista general") { model.overview() }
                Button(model.batchMode ? "Escanear página" : "Escanear") { model.scan() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder private var status: some View {
        switch model.activity {
        case .idle where model.countdown != nil:
            HStack(spacing: 8) {
                Image(systemName: "book.pages")
                    .foregroundStyle(Color.accentColor)
                Text("Cambiá de página · próximo escaneo en \(model.countdown ?? 0) s")
                    .monospacedDigit()
            }
        case .saving(let label):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(label).foregroundStyle(.secondary).monospacedDigit()
            }
        case .idle:
            if let m = model.message {
                HStack(spacing: 6) {
                    if model.isError {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(m)
                        .lineLimit(2)
                        .foregroundStyle(model.isError ? .primary : .secondary)
                        .textSelection(.enabled)
                }
            } else {
                Text(model.selections.isEmpty
                     ? "Se escaneará: \(model.sizePreset.label)"
                     : (model.selections.count == 1 ? "Se escaneará la selección" : "Se escanearán \(model.selections.count) elementos"))
                    .foregroundStyle(.secondary)
            }
        case .overview(let start):
            progress("Vista general…", since: start)
        case .scanning(let start, let label):
            progress(label, since: start)
        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Procesando…").foregroundStyle(.secondary)
            }
        }
    }

    private func progress(_ label: String, since start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 1)) { ctx in
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(label) \(Int(ctx.date.timeIntervalSince(start))) s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The last scan: thumbnail (draggable), Open With, Copy, Show in Finder.
struct ResultsBar: View {
    @ObservedObject var model: ScannerModel

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: -18) {
                ForEach(model.results.prefix(4)) { r in
                    Image(decorative: r.image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 60, maxHeight: 46)
                        .background(Color.white)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .onDrag { NSItemProvider(contentsOf: r.url) ?? NSItemProvider() }
                        .help("Arrastrá para soltarlo en otra app")
                }
            }
            // The bar can be evaluated once more after the results are cleared: never index blindly.
            let first = model.results.first?.url
            VStack(alignment: .leading, spacing: 2) {
                Text(model.results.count == 1 ? (first?.lastPathComponent ?? "")
                                               : "\(model.results.count) archivos")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((first?.deletingLastPathComponent().path ?? "")
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            openWithMenu
            Button {
                model.copyResults()
            } label: {
                Label("Copiar", systemImage: "doc.on.doc")
            }
            .help("Copiar la imagen al portapapeles (⌘C)")
            Button {
                model.revealResults()
            } label: {
                Label("Mostrar en Finder", systemImage: "folder")
            }
            Button {
                model.results = []
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Cerrar")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var openWithMenu: some View {
        Menu {
            if let d = model.defaultApp() {
                Button {
                    model.openResults(with: d.url)
                } label: {
                    Label { Text("\(d.name) (predeterminada)") } icon: { Image(nsImage: d.icon) }
                }
                Divider()
            }
            ForEach(model.editorApps()) { app in
                Button {
                    model.openResults(with: app.url)
                } label: {
                    Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                }
            }
            Divider()
            Button("Otra…") {
                if let u = model.chooseOtherApp() { model.openResults(with: u) }
            }
        } label: {
            Label("Abrir con", systemImage: "arrow.up.forward.app")
        }
        .fixedSize()
    }
}
