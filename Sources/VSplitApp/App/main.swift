import AppKit
import SwiftUI
import VSplitCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let above = UserDefaults.standard.object(forKey: "keepAbove") as? Bool ?? true
        NSApp.setActivationPolicy(above ? .accessory : .regular)
        // Estilo Logic: siempre oscuro.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Antes de activar: la ventana ya en todos los Espacios, para no saltar al escritorio si Logic está a pantalla completa.
        if above {
            for w in NSApp.windows {
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                w.level = .floating
            }
        }
        if ProcessInfo.processInfo.environment["VSPLIT_SNAPSHOT"] == nil {
            // Abrir directamente encima de Logic (en su Espacio, aunque esté a pantalla completa).
            DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.bringToFront() } }
        }
        Self.snapshotIfRequested()
        MainActor.assumeIsolated { AppModel.shared.startWatchingFolder() }
        // `VSplit archivo.mid` desde Terminal (o VSPLIT_OPEN) abre ese archivo.
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
        if let path = args.first ?? ProcessInfo.processInfo.environment["VSPLIT_OPEN"] {
            DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.open(url: URL(fileURLWithPath: path)) } }
        }
    }

    /// Depuración: `VSPLIT_SNAPSHOT=/ruta.png` guarda la ventana como PNG y sale (opcional VSPLIT_SNAPSHOT_ACTIONS).
    static func snapshotIfRequested() {
        guard let out = ProcessInfo.processInfo.environment["VSPLIT_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated {
                let m = AppModel.shared
                for action in (ProcessInfo.processInfo.environment["VSPLIT_SNAPSHOT_ACTIONS"] ?? "").split(separator: ",") {
                    switch action {
                    case "chords": m.showChords = true
                    case "preview-register": var p = m.params; p.mode = .register; m.params = p
                    case "select-voice-a": m.selectVoice(m.voices.first?.id)
                    case "add-voice": m.addVoice()
                    case "counts": print("counts:", m.counts.sorted { $0.key < $1.key }, "undo:", m.editor?.canUndo ?? false)
                    case "installAgent": m.autoOpenFromFolder = true
                    case "onboarding": m.showOnboarding = true
                    case "noOnboarding": m.showOnboarding = false
                    case "step1": m.onboardingStep = 1
                    case "step2": m.onboardingStep = 2
                    case "step3": m.onboardingStep = 3
                    case "es": m.onboardingLang = .es
                    case "en": m.onboardingLang = .en
                    case "metronome": m.metronome = true
                    case "choir": m.instrument = .choir
                    case "play": m.play(); print("playing:", m.isPlaying, AppModel.shared.audio.lastError ?? "no error")
                    case "paint":
                        // Trazo de brocha sintético con la voz B sobre las 10 primeras notas, luego deshacer/rehacer.
                        m.activeVoiceID = m.voices.last?.id
                        m.beginStroke(erase: false); m.strokeAssign(Array(0..<10), erase: false); m.endStroke()
                        print("after paint B:", m.counts.sorted { $0.key < $1.key }); m.undo()
                        print("after undo:", m.counts.sorted { $0.key < $1.key }); m.redo()
                        print("after redo:", m.counts.sorted { $0.key < $1.key })
                    case "zoom": m.controller.zoom(horizontal: 3, vertical: 1.5)
                    default: break
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    print("playhead:", m.playheadTick)
                    MainActor.assumeIsolated {
                        guard let v = m.window?.contentView?.superview ?? m.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(2) }
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                        exit(0)
                    }
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        MainActor.assumeIsolated { AppModel.shared.open(url: url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Volver a abrir la app (Finder, Spotlight, icono) con la ventana oculta: mostrarla encima del DAW.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.bringToFront() }
        return false
    }

    /// Si se activa estando oculta (p. ej. tras un arrastre), que vuelva a verse.
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            if NSApp.isHidden || !(AppModel.shared.window?.isVisible ?? true) { AppModel.shared.bringToFront() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.flushSave() }
    }
}

struct VSplitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("VSplit", id: "main") {
            ContentView(model: AppModel.shared)
                .frame(minWidth: 820, minHeight: 500)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 820)
        .commands { AppCommands(model: AppModel.shared) }
    }
}

VSplitApp.main()
