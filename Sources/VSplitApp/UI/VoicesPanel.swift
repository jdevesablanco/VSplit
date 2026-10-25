import SwiftUI
import VSplitCore

extension RGBAColor {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    init(_ c: Color) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .gray
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), 1)
    }
}

/// Columna izquierda: voces, reparto y exportación.
struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SectionTitle(title: "Voices")
                Spacer()
                Button("+ Add") { model.addVoice() }
                    .buttonStyle(PillStyle())
                    .help("Add voice (⌥⌘N)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .frame(height: 44)

            // Selección nativa de la lista: ⌘-clic y ⇧-clic eligen varias voces (para unirlas con ⌘J).
            List(selection: $model.selectedVoiceIDs) {
                ForEach(Array(model.voices.enumerated()), id: \.element.id) { index, voice in
                    VoiceRow(model: model, voice: voice, index: index)
                        .tag(voice.id)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove { model.moveVoices(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .tint(Color.white.opacity(0.12))
            // Menú contextual sobre la selección (con varias voces, "Unir") y doble clic para renombrar.
            .contextMenu(forSelectionType: VoiceID.self) { ids in
                if ids.count >= 2 {
                    Button("Join \(ids.count) Voices (⌘J)") { model.selectedVoiceIDs = ids; model.joinSelectedVoices() }
                } else if let id = ids.first, let i = model.doc?.voiceIndex(id), let v = model.doc?.voice(id) {
                    VoiceMenuItems(model: model, voice: v, index: i)
                }
            } primaryAction: { ids in
                if ids.count == 1, let id = ids.first { model.activeVoiceID = id; model.renamingVoiceID = id }
            }
            // La voz activa sigue a la selección (con varias, la última que se añadió).
            .onChange(of: model.selectedVoiceIDs) { old, sel in
                if let added = sel.subtracting(old).first { model.activeVoiceID = added }
                else if sel.count == 1, let v = sel.first { model.activeVoiceID = v }
            }
            .frame(maxHeight: .infinity)

            Rectangle().fill(Theme.line).frame(height: 1)
            SplitSection(model: model).padding(14)
            Rectangle().fill(Theme.line).frame(height: 1)
            ExportSection(model: model).padding(14)
        }
    }
}

struct VoiceRow: View {
    @Bindable var model: AppModel
    let voice: Voice
    let index: Int

    var isActive: Bool { model.activeVoiceID == voice.id }
    var isSelected: Bool { model.selectedVoiceIDs.contains(voice.id) }
    @FocusState private var nameFocused: Bool

    var count: Int {
        if model.isPreviewing, index < model.previewCounts.count { return model.previewCounts[index] }
        return model.counts[voice.id] ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ColorSwatchMenu(model: model, voice: voice)
                // Un clic activa la voz; doble clic (o "Rename…") la renombra.
                if model.renamingVoiceID == voice.id {
                    TextField("Name", text: Binding(get: { voice.name }, set: { n in model.updateVoice(voice.id, field: "name") { $0.name = n } }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .focused($nameFocused)
                        .onAppear { DispatchQueue.main.async { nameFocused = true } }
                        .onSubmit { model.finishRenaming() }
                        .onExitCommand { model.finishRenaming() }
                        .onChange(of: nameFocused) { _, f in if !f && model.renamingVoiceID == voice.id { model.finishRenaming() } }
                } else {
                    Text(voice.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                Text("\(count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(model.isPreviewing ? Theme.accent : Theme.faint)
                    .help("Notes in this voice")
                small("M", on: voice.isMuted, tint: Color(hex: 0x5B8DEF), help: "Mute") { model.toggleMute(voice.id) }
                small("S", on: voice.isSolo, tint: Color(hex: 0xE8B931), help: "Solo") { model.toggleSolo(voice.id) }
                FileDragHandle(symbol: "arrow.up.doc", help: String(localized: "Drag this voice to Logic or the Finder")) {
                    model.dragFiles(for: [voice.id])
                }
                .frame(width: 22, height: 20)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(isActive ? Color.white.opacity(0.08) : (isSelected ? Color.white.opacity(0.05) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected && model.selectedVoiceIDs.count > 1 ? Theme.red.opacity(0.7) : Color.clear))
        )
        .overlay(alignment: .leading) {
            if isActive { RoundedRectangle(cornerRadius: 1).fill(voice.color.color).frame(width: 2).padding(.vertical, 6) }
        }
        .contentShape(Rectangle())
        .help(index < 9 ? Text("Key \(index + 1)") : Text(""))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Voice \(voice.name)"))
    }

    private func small(_ label: String, on: Bool, tint: Color, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9.5, weight: .bold))
                .frame(width: 18, height: 17)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? tint : Color.black.opacity(0.4)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? Color.clear : Theme.lineStrong))
                .foregroundStyle(on ? Color.black : Theme.muted)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityValue(on ? Text("On") : Text("Off"))
    }
}

/// Círculo de color: paleta por defecto + selector libre.
struct ColorSwatchMenu: View {
    @Bindable var model: AppModel
    let voice: Voice
    var body: some View {
        Menu {
            ForEach(Array(Voice.palette.enumerated()), id: \.offset) { k, c in
                Button { set(c) } label: { Label { Text("Color \(k + 1)") } icon: { Image(nsImage: swatch(c)) } }
            }
            Divider()
            Button("Custom Color…") {
                let panel = NSColorPanel.shared
                panel.showsAlpha = false
                panel.color = NSColor(srgbRed: voice.color.r, green: voice.color.g, blue: voice.color.b, alpha: 1)
                ColorPanelTarget.shared.onChange = { c in set(RGBAColor(Color(nsColor: c))) }
                panel.setTarget(ColorPanelTarget.shared)
                panel.setAction(#selector(ColorPanelTarget.changed(_:)))
                panel.orderFront(nil)
            }
        } label: {
            Image(nsImage: swatch(voice.color, size: 12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 16)
        .help("Voice color")
        .accessibilityLabel("Voice color")
    }

    private func set(_ c: RGBAColor) { model.updateVoice(voice.id, field: "color") { $0.color = c } }

    private func swatch(_ c: RGBAColor, size: CGFloat = 12) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}

final class ColorPanelTarget: NSObject {
    static let shared = ColorPanelTarget()
    var onChange: ((NSColor) -> Void)?
    @objc func changed(_ sender: NSColorPanel) { onChange?(sender.color) }
}

struct VoiceMenuItems: View {
    @Bindable var model: AppModel
    let voice: Voice
    let index: Int
    var body: some View {
        Button("Rename…") { model.activeVoiceID = voice.id; model.renamingVoiceID = voice.id }
        Button("Listen to This Voice Alone") { model.listenAlone(voice.id) }
        Button("Select Notes of This Voice") { model.selectVoice(voice.id) }
        Button("Assign Selection Here") { model.assignSelection(toVoiceAt: index) }.disabled(model.selection.isEmpty)
        Divider()
        Button("Duplicate Voice") { model.duplicateVoice(voice.id) }
        Menu("Swap Notes With") {
            ForEach(model.voices.filter { $0.id != voice.id }) { other in Button(other.name) { model.swapVoices(voice.id, other.id) } }
        }
        Button("Move Up") { model.moveVoice(voice.id, by: -1) }.disabled(index == 0)
        Button("Move Down") { model.moveVoice(voice.id, by: 1) }.disabled(index == model.voices.count - 1)
        Divider()
        Button("Delete Voice…", role: .destructive) { model.requestDelete(voice.id) }.disabled(model.voices.count <= 1)
    }
}

/// Opciones de exportación, plegadas por defecto.
struct ExportSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { model.exportExpanded.toggle() } } label: {
                HStack {
                    SectionTitle(title: "Export")
                    Spacer()
                    if model.unassignedCount > 0 {
                        Text("\(model.unassignedCount) unassigned").font(.system(size: 10.5)).foregroundStyle(Theme.red)
                    }
                    Image(systemName: model.exportExpanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.exportExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Copy CC, sustain and pitch bend", isOn: $model.exportOptions.copyNonNoteEvents)
                    Toggle("Trim leading silence", isOn: $model.exportOptions.normalizeStart)
                        .help("Off: notes keep their absolute position so they land in the same place in Logic.")
                    Picker("Channel", selection: $model.exportOptions.channelMode) {
                        Text("Keep original").tag(ExportOptions.ChannelMode.original)
                        Text("All on one channel").tag(ExportOptions.ChannelMode.single)
                        Text("Channel = voice number").tag(ExportOptions.ChannelMode.perVoice)
                    }
                    if model.exportOptions.channelMode == .single {
                        Stepper("Channel \(model.exportOptions.singleChannel + 1)", value: $model.exportOptions.singleChannel, in: 0...15)
                    }
                    if model.unassignedCount > 0 {
                        Picker("Unassigned notes", selection: Binding(get: { unassignedTag }, set: { setUnassigned($0) })) {
                            Text("Leave out").tag(-1)
                            ForEach(model.voices) { v in Text("Include in \(v.name)").tag(v.id) }
                        }
                    }
                    HStack(spacing: 6) {
                        Button("Export All…") { model.exportAllToFolder() }.buttonStyle(ChipStyle()).help("One .mid per voice in a folder (⇧⌘E)")
                        Button("Multitrack…") { model.exportMultitrack() }.buttonStyle(ChipStyle()).help("A single .mid with one track per voice (⌥⌘E)")
                    }
                }
                .font(.system(size: 12))
                .controlSize(.small)
                .foregroundStyle(Theme.text)
            }

            FileDragHandle(title: String(localized: "Drag All Voices"), symbol: "square.stack.3d.up", help: String(localized: "Drag to Logic (one new track per voice) or to the Finder")) {
                model.dragFiles(for: model.voices.map(\.id))
            }
            .frame(height: 30)
        }
    }

    private var unassignedTag: Int {
        if case .toVoice(let v) = model.exportOptions.unassigned { return v }
        return -1
    }
    private func setUnassigned(_ tag: Int) { model.exportOptions.unassigned = tag < 0 ? .discard : .toVoice(tag) }
}
