// Panel de detalles (derecha), al estilo de "Mostrar detalles" de Captura de Imagen.
import AppKit
import SwiftUI

struct Inspector: View {
    @ObservedObject var model: ScannerModel
    @State private var editorApps: [EditorApp] = []

    var body: some View {
        Form {
            Section {
                Picker("Modo", selection: $model.batchMode) {
                    Text("Archivos").tag(false)
                    Text("Documento PDF").tag(true)
                }
                .pickerStyle(.segmented)
                if model.batchMode {
                    Toggle("Libro abierto: dividir en 2 páginas", isOn: $model.splitSpreads)
                    Toggle("Escaneo continuo", isOn: $model.continuous)
                    if model.continuous {
                        Stepper(value: $model.continuousDelay, in: 3...60) {
                            LabeledContent("Tiempo para cambiar de página", value: "\(model.continuousDelay) s")
                        }
                    }
                    Toggle("Reconocer texto (PDF con búsqueda)", isOn: $model.ocr)
                }
            } footer: {
                if model.batchMode {
                    Text("Cada escaneo agrega páginas abajo. La selección se mantiene entre páginas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Tipo", selection: $model.kind) {
                    ForEach(ScanKind.allCases) { Text($0.label).tag($0) }
                }
                Picker("Resolución", selection: $model.dpi) {
                    ForEach(model.resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
                }
                Picker("Rotación", selection: $model.rotation) {
                    Text("0°").tag(0)
                    Text("90° ↻").tag(90)
                    Text("180°").tag(180)
                    Text("90° ↺").tag(270)
                }
            }

            Section("Área") {
                LabeledContent("Proporción") {
                    HStack(spacing: 4) {
                        Picker("Proporción", selection: $model.aspect) {
                            Text(AspectLock.free.label).tag(AspectLock.free)
                            Text(AspectLock.r1x1.label).tag(AspectLock.r1x1)
                            Section("Vertical") {
                                ForEach(AspectLock.vertical) { Text($0.label).tag($0) }
                            }
                            Section("Horizontal") {
                                ForEach(AspectLock.horizontal) { Text($0.label).tag($0) }
                            }
                        }
                        .labelsHidden()
                        Button {
                            model.aspect = model.aspect.flipped
                        } label: {
                            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.aspect.flipped == model.aspect)
                        .help("Cambiar entre vertical y horizontal")
                    }
                }
                if model.selections.isEmpty {
                    Picker("Tamaño", selection: $model.sizePreset) {
                        ForEach(SizePreset.allCases) { Text($0.label).tag($0) }
                    }
                    LabeledContent("Resultado", value: model.summary(for: model.presetRect))
                        .foregroundStyle(.secondary)
                } else {
                    sizeFields
                    if model.selections.count > 1 {
                        LabeledContent("Elementos", value: "\(model.selections.count) (un archivo por elemento)")
                            .foregroundStyle(.secondary)
                    }
                    Button("Quitar selección") { model.removeActiveSelection() }
                }
                Picker("Detección automática", selection: $model.autoSelect) {
                    ForEach(AutoSelect.allCases) { Text($0.label).tag($0) }
                }
                if model.preview != nil {
                    Button("Detectar ahora") { model.detectNow() }
                }
            }

            Section("Destino") {
                LabeledContent("Escanear en") {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: model.folder.path))
                            .resizable().frame(width: 16, height: 16)
                        Text(FileManager.default.displayName(atPath: model.folder.path))
                            .lineLimit(1).truncationMode(.middle)
                        Button("Elegir…") { model.chooseFolder() }
                    }
                }
                TextField("Nombre", text: $model.baseName)
                if model.batchMode {
                    LabeledContent("Formato", value: "PDF de varias páginas")
                } else {
                    Picker("Formato", selection: $model.format) {
                        ForEach(OutputFormat.allCases) { Text($0.label).tag($0) }
                    }
                    if model.format == .pdf {
                        Toggle("Combinar en un solo documento", isOn: $model.combinePDF)
                    }
                }
                Picker("Al terminar", selection: afterBinding) {
                    Text("No hacer nada").tag("nothing")
                    Text("Mostrar en Finder").tag("finder")
                    Divider()
                    ForEach(editorApps) { app in
                        Label { Text("Abrir en \(app.name)") } icon: { Image(nsImage: app.icon) }
                            .tag("app:" + app.url.path)
                    }
                    if let a = model.afterApp, !editorApps.contains(where: { $0.url == a }) {
                        Text("Abrir en \(EditorApp(url: a).name)").tag("app:" + a.path)
                    }
                    Divider()
                    Text("Otra app…").tag("other")
                }
            }

            Section {
                Picker("Corrección de imagen", selection: $model.adj.manual) {
                    Text("Ninguna").tag(false)
                    Text("Manual").tag(true)
                }
                if model.adj.manual {
                    slider("Brillo", $model.adj.brightness, -0.5...0.5)
                    slider("Contraste", $model.adj.contrast, 0.5...2)
                    if model.kind == .color {
                        slider("Saturación", $model.adj.saturation, 0...2)
                    }
                    slider("Nitidez", $model.adj.sharpness, 0...2)
                    Button("Restablecer") {
                        let t = model.adj.threshold
                        model.adj = Adjustments(manual: true, threshold: t)
                    }
                }
                if model.kind == .bw {
                    slider("Umbral", $model.adj.threshold, 0.1...0.9)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reloadApps() }
        .onChange(of: model.format) { reloadApps() }
        .onChange(of: model.batchMode) { reloadApps() }
    }

    private var sizeFields: some View {
        let r = model.active?.rect ?? .zero
        let s = model.shownSize(of: r)
        let fmt: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(model.units == .px || model.units == .mm ? 0 : 1))
        return Group {
            LabeledContent("Tamaño") {
                HStack(spacing: 4) {
                    TextField("Ancho", value: Binding(get: { model.toUnits(Double(s.width)) },
                                                      set: { model.setShownSize(width: $0) }), format: fmt)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                    Text("×").foregroundStyle(.secondary)
                    TextField("Alto", value: Binding(get: { model.toUnits(Double(s.height)) },
                                                     set: { model.setShownSize(height: $0) }), format: fmt)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                    Picker("", selection: $model.units) {
                        ForEach(Units.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 76)
                }
            }
            LabeledContent("Resultado", value: model.summary(for: r))
                .foregroundStyle(.secondary)
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range).controlSize(.small)
        }
    }

    private var afterBinding: Binding<String> {
        Binding(
            get: {
                switch model.afterScan {
                case .nothing: return "nothing"
                case .finder: return "finder"
                case .app: return model.afterApp.map { "app:" + $0.path } ?? "finder"
                }
            },
            set: { v in
                if v == "nothing" { model.afterScan = .nothing }
                else if v == "finder" { model.afterScan = .finder }
                else if v == "other" {
                    if let u = model.chooseOtherApp() { model.afterApp = u; model.afterScan = .app }
                } else if v.hasPrefix("app:") {
                    model.afterApp = URL(fileURLWithPath: String(v.dropFirst(4)))
                    model.afterScan = .app
                }
            }
        )
    }

    private func reloadApps() {
        let type = (model.batchMode || model.format == .pdf) ? OutputFormat.pdf.utType : model.format.utType
        editorApps = ScannerModel.apps(for: type)
    }
}
