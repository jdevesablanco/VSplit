import AppKit
import SwiftUI
import VSplitCore

/// Menús completos. Los atajos de una sola tecla (B, V, 1–9, espacio, Tab…) los gestiona AppModel con un monitor de
/// teclado para no robarle letras a los campos de texto; aquí solo se muestran en el título.
struct AppCommands: Commands {
    @Bindable var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.openPanel() }.keyboardShortcut("o")
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Export All Voices to Folder…") { model.exportAllToFolder() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.hasDocument)
            Button("Export Multitrack MIDI…") { model.exportMultitrack() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!model.hasDocument)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(model.undoTitle) { model.undo() }.keyboardShortcut("z")
            Button(model.redoTitle) { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { model.copySelection(cut: true) }.keyboardShortcut("x")
            Button("Copy") { model.copySelection(cut: false) }.keyboardShortcut("c")
            Button("Paste") { model.paste() }.keyboardShortcut("v")
            Divider()
            Button("Select All") { model.selectAll() }.keyboardShortcut("a")
            Button("Deselect All (Esc)") { model.deselectAll() }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Invert Selection") { model.invertSelection() }.keyboardShortcut("i")
            Divider()
            Button("Select Notes of Active Voice") { model.selectActiveVoice() }.keyboardShortcut("a", modifiers: [.command, .option])
            Button("Select Same Pitch") { model.selectSamePitch() }.keyboardShortcut("p", modifiers: [.command, .option])
            Button("Select Whole Chord (double-click)") { model.selectChordsOfSelection() }.keyboardShortcut("c", modifiers: [.command, .option])
            Button("Select Unassigned Notes") { model.selectUnassigned() }.keyboardShortcut("u", modifiers: [.command, .option])
            Divider()
            Button("Delete Notes") { model.deleteSelectedNotes() }.keyboardShortcut(.delete, modifiers: [.shift])
        }

        CommandMenu("Voices") {
            Button("Add Voice") { model.addVoice() }.keyboardShortcut("n", modifiers: [.command, .option])
            Button("Join Selected Voices") { model.joinSelectedVoices() }
                .keyboardShortcut("j")
                .disabled(!model.canJoinVoices)
            Button("Duplicate Active Voice") { if let v = model.activeVoiceID { model.duplicateVoice(v) } }.keyboardShortcut("d")
            Button("Delete Active Voice…") { model.deleteActiveVoiceCommand() }
                .keyboardShortcut(.delete, modifiers: [.command])
            Divider()
            Menu("Assign Selection To") {
                ForEach(Array(model.voices.enumerated()), id: \.element.id) { i, v in
                    Button(i < 9 ? "\(v.name) (\(i + 1))" : v.name) { model.assignSelection(toVoiceAt: i) }
                }
            }
            Button("Selection to Next Voice (Tab)") { model.shiftSelection(by: 1) }
            Button("Selection to Previous Voice (⇧Tab)") { model.shiftSelection(by: -1) }
            Button("Unassign Selection (⌫)") { model.unassignSelection() }
            Divider()
            Menu("Swap Active Voice With") {
                ForEach(model.voices.filter { $0.id != model.activeVoiceID }) { v in
                    Button(v.name) { if let a = model.activeVoiceID { model.swapVoices(a, v.id) } }
                }
            }
            Divider()
            Button("Apply Auto-split") { model.applyAutoSplit(selectionOnly: false) }.keyboardShortcut("r")
            Button("Re-apply Auto-split to Selection") { model.applyAutoSplit(selectionOnly: true) }.keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandMenu("Tools") {
            ForEach(Tool.allCases) { t in
                Button("\(t.title) (\(t.key.uppercased()))") { model.tool = t }
            }
        }

        CommandGroup(before: .windowArrangement) {
            Toggle("Keep Above Other Apps", isOn: $model.keepAbove).keyboardShortcut("f", modifiers: [.command, .option])
            Divider()
        }

        CommandMenu("Transport") {
            Button(model.isPlaying ? "Stop (Space)" : "Play (Space)") { model.togglePlay() }
            Button("Go to Start (Return)") { model.toStart() }
            Toggle("Loop", isOn: $model.loopEnabled).keyboardShortcut("l")
            Toggle("Metronome", isOn: $model.metronome).keyboardShortcut("k")
            Divider()
            Button("Listen to Active Voice Alone") { if let v = model.activeVoiceID { model.listenAlone(v) } }.keyboardShortcut("s", modifiers: [.command, .option])
        }

        CommandGroup(before: .toolbar) {
            Button("Zoom In") { model.controller.zoom(horizontal: 1.4) }.keyboardShortcut("+")
            Button("Zoom Out") { model.controller.zoom(horizontal: 1 / 1.4) }.keyboardShortcut("-")
            Button("Zoom In Vertically") { model.controller.zoom(vertical: 1.25) }.keyboardShortcut("=", modifiers: [.command, .option])
            Button("Zoom Out Vertically") { model.controller.zoom(vertical: 1 / 1.25) }.keyboardShortcut("-", modifiers: [.command, .option])
            Button("Fit to Content") { model.controller.fitToContent() }.keyboardShortcut("0")
            Divider()
            Toggle("Velocity as Opacity", isOn: $model.showVelocity)
            Toggle("Note Names in Bars", isOn: $model.showLabels)
            Toggle("Show Detected Chords", isOn: $model.showChords)
            Picker("Middle C (MIDI 60) Is", selection: $model.middleCOctave) {
                Text("C3 (Logic)").tag(3)
                Text("C4 (General MIDI)").tag(4)
            }
            Divider()
        }
    }
}
