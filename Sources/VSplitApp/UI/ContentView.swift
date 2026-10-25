import SwiftUI
import UniformTypeIdentifiers
import VSplitCore

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Header(model: model)
            if model.hasDocument {
                HStack(spacing: 10) {
                    Sidebar(model: model).frame(width: 272).plate()
                    VStack(spacing: 0) {
                        EditorBar(model: model)
                        Rectangle().fill(Theme.line).frame(height: 1)
                        Notices(model: model)
                        PianoRollView(model: model)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .plate(screws: false)
                }
                TransportBar(model: model).plate()
            } else {
                ZStack {
                    PianoRollView(model: model).opacity(0).frame(width: 1, height: 1)
                    EmptyState(model: model)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding([.horizontal, .bottom], 10)
        .background(AuroraBackground())
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .ignoresSafeArea(.container, edges: .top)
        .onDrop(of: [.fileURL, .midi], isTargeted: nil) { providers in receive(providers) }
        .sheet(isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } })) {
            TrackPicker(model: model)
        }
        .overlay {
            if let a = model.arrival, !model.showOnboarding {
                ArrivalOverlay(arrival: a) { withAnimation(.easeIn(duration: 0.3)) { if model.arrival?.id == a.id { model.arrival = nil } } }
                    .id(a.id)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity.combined(with: .scale(scale: 1.03))))
            }
        }
        .overlay { if model.showOnboarding { OnboardingView(model: model).transition(.opacity) } }
        .background(WindowAccessor { w in if model.window !== w { model.window = w } })
    }

    private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.open(url: url) }
            }
            return true
        }
        if p.hasItemConformingToTypeIdentifier(UTType.midi.identifier) {
            let name = p.suggestedName ?? "Clip"
            p.loadDataRepresentation(forTypeIdentifier: UTType.midi.identifier) { data, error in
                DispatchQueue.main.async {
                    guard let data else { model.presentError(String(localized: "Can't receive the dropped file"), error?.localizedDescription ?? ""); return }
                    do { try model.open(data: data, url: nil, name: name) } catch { model.presentError(String(localized: "Can't open “\(name)”"), error.localizedDescription) }
                }
            }
            return true
        }
        return false
    }
}

// MARK: - Cabecera

struct Header: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 8) {
                Color.clear.frame(width: 62)  // semáforo de la ventana
                Spacer()
                // En modo "encima de otras apps" no hay barra de menús: lo esencial está aquí.
                Menu {
                    Button("Open…") { model.openPanel() }
                    Button("Paste") { model.paste() }
                    Button("Show Watch Folder") { NSWorkspace.shared.open(FolderWatcher.folder) }
                    Divider()
                    Button("Export All Voices to Folder…") { model.exportAllToFolder() }.disabled(!model.hasDocument)
                    Button("Export Multitrack MIDI…") { model.exportMultitrack() }.disabled(!model.hasDocument)
                    Divider()
                    Button("Set \(model.voices.count) Voices · \(model.params.mode.title) as Default") { model.setCurrentAsDefault() }
                        .disabled(!model.hasDocument || (model.defaultVoiceCount == model.voices.count && model.defaultMode == model.params.mode))
                    if let n = model.defaultVoiceCount {
                        Button("Detect Voices Again (Default: \(n) · \((model.defaultMode ?? model.params.mode).title))") { model.clearDefault() }
                    }
                    Divider()
                    Toggle("Keep Above Other Apps", isOn: $model.keepAbove)
                    Toggle("Open VSplit When You Export From Logic", isOn: $model.autoOpenFromFolder)
                    Button("Show Tutorial") { model.showOnboarding = true }
                    Divider()
                    Button("Quit VSplit") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.muted)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
                .help("More")
                if model.hasDocument {
                    Button { model.paste() } label: { Text("Paste") }
                        .buttonStyle(PillStyle())
                        .help("Paste notes copied in Logic (⌘V)")
                    // Arrastrar todas las voces (una pista por voz en Logic). La exportación a carpeta sigue en el menú Archivo.
                    FileDragHandle(symbol: "square.stack.3d.up", help: String(localized: "Drag all voices to Logic (one new track per voice) or to the Finder")) {
                        model.dragFiles(for: model.voices.map(\.id))
                    }
                    .frame(width: 34, height: 24)
                }
            }
            .padding(.leading, 12)  // a la derecha, alineado con el borde de los paneles
            HStack(spacing: 6) {
                Text(model.hasDocument ? model.title : "")
                    .font(.system(size: 11, weight: .medium))
                    .kerning(0.6)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.hasDocument && model.isDirty {
                    Circle().fill(Theme.muted).frame(width: 5, height: 5).help("Not exported yet")
                }
            }
            .frame(maxWidth: 420)
            .allowsHitTesting(false)
        }
        .frame(height: 40)
    }
}

/// Marca: dos barras de notas en dos colores, dibujada a mano.
struct AppMark: View {
    var body: some View {
        HStack(spacing: 7) {
            Canvas { ctx, size in
                // Una "V" hecha con dos haces de luz (azul y naranja), como el fondo.
                var l = Path(); l.move(to: CGPoint(x: 2, y: 2)); l.addLine(to: CGPoint(x: 9, y: 18))
                var r = Path(); r.move(to: CGPoint(x: 16, y: 2)); r.addLine(to: CGPoint(x: 9, y: 18))
                var glow = ctx; glow.addFilter(.blur(radius: 2.5))
                glow.stroke(l, with: .color(Color(hex: 0x4A9BFF)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                glow.stroke(r, with: .color(Color(hex: 0xFF8C38)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                ctx.stroke(l, with: .linearGradient(Gradient(colors: [Color(hex: 0x9FD0FF), Color(hex: 0x4A9BFF)]), startPoint: CGPoint(x: 2, y: 2), endPoint: CGPoint(x: 9, y: 18)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                ctx.stroke(r, with: .linearGradient(Gradient(colors: [Color(hex: 0xFFC35C), Color(hex: 0xFF6A2A)]), startPoint: CGPoint(x: 16, y: 2), endPoint: CGPoint(x: 9, y: 18)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
            .frame(width: 18, height: 20)
            Text("VSPLIT").font(Theme.display(15)).kerning(1.5).foregroundStyle(Theme.text)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Barra del editor

struct EditorBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Tool.allCases) { t in
                    Button { model.tool = t } label: { Image(systemName: t.symbol) }
                        .buttonStyle(IconStyle(on: model.tool == t))
                        .help("\(t.title) (\(t.key.uppercased()))")
                        .accessibilityLabel(t.title)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))

            Menu {
                ForEach(Array(model.voices.enumerated()), id: \.element.id) { i, v in
                    Button(i < 9 ? "\(v.name)  (\(i + 1))" : v.name) { model.activeVoiceID = v.id }
                }
            } label: {
                let v = model.doc?.voice(model.activeVoiceID)
                HStack(spacing: 6) {
                    Circle().fill(v?.color.color ?? .gray).frame(width: 7, height: 7)
                    Text(v?.name ?? "—").font(.system(size: 10, weight: .semibold)).kerning(1.2).textCase(.uppercase)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Active voice (keys 1–9)")

            Spacer()

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(IconStyle()).disabled(!(model.editor?.canUndo ?? false)).help(model.undoTitle)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(IconStyle()).disabled(!(model.editor?.canRedo ?? false)).help(model.redoTitle)
            Rectangle().fill(Theme.line).frame(width: 1, height: 16)
            Button { model.showLabels.toggle() } label: { Image(systemName: "textformat") }
                .buttonStyle(IconStyle(on: model.showLabels)).help("Note names inside the bars")
            Button { model.controller.fitToContent() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(IconStyle()).help("Fit to content (⌘0)")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Color.black.opacity(0.25))
    }
}

// MARK: - Avisos (una línea, discretos)

struct Notices: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.showWarnings, !model.warnings.isEmpty {
                strip(icon: "exclamationmark.triangle", tint: Color(hex: 0xE8A33D)) {
                    Text(model.warnings.map(\.message).joined(separator: "  ·  ")).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Button { model.showWarnings = false } label: { Image(systemName: "xmark") }.buttonStyle(IconStyle(size: 22)).accessibilityLabel("Dismiss")
                }
            }
            if let bar = model.fileOriginBar, model.pastedText == nil {
                strip(icon: "folder", tint: Theme.muted) {
                    Text("From Logic, bar \(bar) — drop the voices back at that bar.").lineLimit(1)
                    Spacer()
                }
            }
        }
    }

    private func strip<C: View>(icon: String, tint: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                content()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.text)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color.white.opacity(0.03))
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

// MARK: - Transporte

struct TransportBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.isPlaying ? Color.black : Theme.text)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(model.isPlaying ? Theme.accent : Color.black.opacity(0.5)))
                    .overlay(Circle().strokeBorder(Theme.lineStrong))
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Play / Stop (Space)")
            Button { model.toStart() } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(IconStyle()).help("Go to start (Return)")

            if let d = model.doc {
                let pos = d.tempoMap.position(atTick: model.playheadTick)
                let endPos = d.tempoMap.position(atTick: d.endTick)
                Text("\(pos.bar + 1).\(pos.beat + 1)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .frame(width: 40, alignment: .trailing)
                    .help("Playhead position (bar.beat)")
                Text("/ \(endPos.bar + 1).\(endPos.beat + 1)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.faint)
                Slider(value: Binding(get: { Double(model.playheadTick) }, set: { model.seek(Int($0)) }), in: 0...Double(max(1, d.endTick)))
                    .controlSize(.small)
                    .frame(minWidth: 160)
            } else {
                Spacer()
            }

            Button { model.loopEnabled.toggle() } label: { Image(systemName: "repeat") }
                .buttonStyle(IconStyle(on: model.loopEnabled)).help("Loop over the selection, or the whole clip (⌘L)")
            // Clic: activar/desactivar; clic derecho para el sonido, volumen y acento.
            Button { model.metronome.toggle() } label: { Image(systemName: "metronome") }
                .buttonStyle(IconStyle(on: model.metronome))
                .help("Metronome (⌘K). Right-click: sound and volume")
                .contextMenu { MetronomeMenu(model: model) }
            MeterField(model: model)
            BPMField(model: model)
            Menu {
                ForEach(PreviewInstrument.allCases) { inst in
                    Button { model.instrument = inst } label: {
                        if model.instrument == inst { Label(inst.title, systemImage: "checkmark") } else { Text(inst.title) }
                    }
                }
            } label: {
                Text(model.instrument.title).font(Theme.din(12.5)).kerning(1.6).textCase(.uppercase).foregroundStyle(Theme.muted)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Preview instrument")

            if let d = model.doc {
                Rectangle().fill(Theme.line).frame(width: 1, height: 18)
                Text("\(d.notes.count) notes").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.faint)
                if !model.selection.isEmpty {
                    Text("\(model.selection.count) selected").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted)
                }
                if model.unassignedCount > 0 {
                    Button("\(model.unassignedCount) unassigned") { model.selectUnassigned() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color(hex: 0xE8A33D))
                        .help("Select them")
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .disabled(!model.hasDocument)
    }
}

// MARK: - Primera pantalla

struct EmptyState: View {
    let model: AppModel
    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Text("VSPLIT").font(Theme.display(64)).kerning(4).foregroundStyle(Theme.text.opacity(0.92))
                Text("Voices, set apart.").font(.system(size: 17, weight: .regular)).foregroundStyle(Theme.text.opacity(0.85))
            }
            .padding(.bottom, 10)
            HStack(alignment: .top, spacing: 4) {
                step("doc.on.doc", "1", title: "Copy the notes", detail: "In Logic: Piano Roll, ⌘A ⌘C")
                arrow
                step("doc.on.clipboard", "2", title: "Paste here", detail: "⌘V")
                arrow
                step("arrow.up.doc", "3", title: "Drag the voices back", detail: "One track per voice")
            }
            Button { model.paste() } label: { Text("Paste").frame(minWidth: 90) }
                .buttonStyle(PillStyle(wide: true))
                .controlSize(.large)
            HStack(spacing: 4) {
                Text("or export MIDI from Logic to Documents › VSplit, drop a .mid here ·").foregroundStyle(Theme.muted)
                Button("Open…") { model.openPanel() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            .font(.system(size: 11.5))
        }
        .padding(.horizontal, 30).padding(.vertical, 26)
    }

    private var arrow: some View {
        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint).padding(.top, 17)
    }

    private func step(_ symbol: String, _ n: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.text)
                    .frame(width: 50, height: 50)
                    .plate(radius: 8, screws: false)
                Text(n).font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(Theme.red))
                    .offset(x: 5, y: -5)
            }
            Text(title).font(.system(size: 9.5, weight: .semibold)).kerning(1.6).textCase(.uppercase).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .frame(width: 120)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Elegir pistas

struct TrackPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This MIDI file has several tracks").font(.system(size: 14, weight: .semibold))
            Text("Choose which ones to load. If you pick several, their notes are merged into one clip.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let p = model.pending {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(p.sequence.tracksWithNotes, id: \.index) { t in
                        Toggle(isOn: Binding(get: { model.pending?.choice[t.index] ?? false }, set: { model.pending?.choice[t.index] = $0 })) {
                            HStack {
                                Text(t.name ?? String(localized: "Track \(t.index + 1)")).fontWeight(.medium)
                                Text("· \(t.noteCount) notes · ch \(t.channels.map { String(Int($0) + 1) }.joined(separator: ", "))")
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            }
            HStack {
                Button("All") { selectAll(true) }.buttonStyle(ChipStyle())
                Button("None") { selectAll(false) }.buttonStyle(ChipStyle())
                Spacer()
                Button("Cancel", role: .cancel) { model.pending = nil }.keyboardShortcut(.cancelAction).buttonStyle(ChipStyle())
                Button("Load") { model.confirmPending() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ChipStyle(prominent: true))
                    .disabled(!(model.pending?.choice.values.contains(true) ?? false))
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.panel)
    }

    private func selectAll(_ on: Bool) {
        guard var p = model.pending else { return }
        for k in p.choice.keys { p.choice[k] = on }
        model.pending = p
    }
}


/// Menú del clic (clic derecho en el botón del metrónomo): sonido, volumen y acento.
struct MetronomeMenu: View {
    @Bindable var model: AppModel
    var body: some View {
        Toggle("Metronome", isOn: $model.metronome)
        Divider()
        Section("Sound") {
            ForEach(MetronomeSound.allCases) { s in
                Button { model.metronomeSound = s } label: {
                    if model.metronomeSound == s { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                }
            }
        }
        Section("Volume") {
            ForEach([(0.4, String(localized: "Soft")), (0.7, String(localized: "Medium")), (1.0, String(localized: "Loud"))], id: \.0) { v, name in
                Button { model.metronomeVolume = v } label: {
                    if abs(model.metronomeVolume - v) < 0.01 { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        }
        Divider()
        Toggle("Accent First Beat", isOn: $model.metronomeAccent)
    }
}

/// Tempo de la preview: arrastra arriba/abajo para cambiarlo; doble clic para escribirlo.
/// Compás, en la misma caja que el tempo. Con notas pegadas se puede cambiar (Logic no lo copia si no hay Accesibilidad).
struct MeterField: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            ForEach(["2/4", "3/4", "4/4", "5/4", "6/8", "7/8", "9/8", "12/8"], id: \.self) { m in
                Button { set(m) } label: {
                    if model.meterLabel == m { Label(m, systemImage: "checkmark") } else { Text(m) }
                }
            }
        } label: {
            Text(model.meterLabel).font(Theme.din(15)).padding(.top, 2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.lineStrong))
        .disabled(model.pastedText == nil)
        .help("Meter")
    }

    private func set(_ m: String) {
        let p = m.split(separator: "/").compactMap { Int($0) }
        if p.count == 2 { model.reinterpretPaste(numerator: p[0], denominator: p[1]) }
    }
}

struct BPMField: View {
    @Bindable var model: AppModel
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 3) {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(Theme.din(15))
                    .frame(width: 40)
                    .focused($focused)
                    .onAppear { text = format(model.tempoBPM); DispatchQueue.main.async { focused = true } }
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, f in if !f { commit() } }
            } else {
                Text(format(model.tempoBPM))
                    .font(Theme.din(15).monospacedDigit())
                    .padding(.top, 2)
                    .frame(minWidth: 24)
            }
            Text("BPM").font(Theme.din(11)).padding(.top, 2).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.lineStrong))
        .overlay {
            if !editing {
                DragNumberCatcher(
                    begin: { model.tempoBPM },
                    change: { start, dy, fine in
                        // 1 BPM cada 3 px (con ⌥, décimas).
                        let v = start - dy / (fine ? 30 : 3)
                        model.tempoBPM = max(20, min(400, fine ? (v * 10).rounded() / 10 : v.rounded()))
                    },
                    doubleClick: { editing = true })
            }
        }
        .help("Preview tempo: drag up/down, double-click to type (the exported files keep the original tempo map)")
    }

    private func format(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    private func commit() {
        if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { model.tempoBPM = max(20, min(400, v)) }
        editing = false
        if let v = model.controller.view { v.window?.makeFirstResponder(v) }
    }
}

/// Zona AppKit que distingue arrastre vertical (cambiar valor) y doble clic (escribir), sin que se pisen.
struct DragNumberCatcher: NSViewRepresentable {
    var begin: () -> Double
    var change: (_ start: Double, _ dy: Double, _ fine: Bool) -> Void
    var doubleClick: () -> Void

    final class V: NSView {
        var begin: () -> Double = { 0 }
        var change: (Double, Double, Bool) -> Void = { _, _, _ in }
        var doubleClick: () -> Void = {}
        private var startValue = 0.0
        private var startY: CGFloat = 0
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func mouseDown(with e: NSEvent) {
            if e.clickCount == 2 { doubleClick(); return }
            startValue = begin()
            startY = e.locationInWindow.y
        }
        override func mouseDragged(with e: NSEvent) {
            // En coordenadas de ventana la y crece hacia arriba: subir el ratón = valor mayor.
            change(startValue, Double(startY - e.locationInWindow.y), e.modifierFlags.contains(.option))
        }
    }

    func makeNSView(context: Context) -> V { let v = V(); update(v); return v }
    func updateNSView(_ v: V, context: Context) { update(v) }
    private func update(_ v: V) { v.begin = begin; v.change = change; v.doubleClick = doubleClick }
}
