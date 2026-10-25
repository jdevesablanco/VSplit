import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VSplitCore

/// Pintar (todo lo que tocas pasa a la voz activa), Dibujar (crea notas y ajusta su duración), Seleccionar
/// (clic, rectángulo, ⌥ = lazo; arrastrar el borde derecho alarga) y Borrar (quita la voz).
enum Tool: String, CaseIterable, Identifiable {
    case brush, draw, select, eraser
    var id: String { rawValue }
    var key: String { ["brush": "b", "draw": "d", "select": "v", "eraser": "e"][rawValue]! }
    var symbol: String {
        switch self {
        case .brush: return "paintbrush.pointed"
        case .draw: return "pencil"
        case .select: return "cursorarrow"
        case .eraser: return "eraser"
        }
    }
    var title: String {
        switch self {
        case .brush: return String(localized: "Paint")
        case .draw: return String(localized: "Draw")
        case .select: return String(localized: "Select")
        case .eraser: return String(localized: "Erase")
        }
    }
}

enum PreviewInstrument: Int, CaseIterable, Identifiable {
    case piano = 0, choir = 52, strings = 48, organ = 19
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .piano: return String(localized: "Piano")
        case .choir: return String(localized: "Choir Aahs")
        case .strings: return String(localized: "Strings")
        case .organ: return String(localized: "Organ")
        }
    }
}

struct PendingLoad {
    var sequence: MIDISequence
    var url: URL?
    var hash: String
    var name: String
    var choice: [Int: Bool]
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Documento

    private(set) var editor: Editor?
    private(set) var fileURL: URL?
    private(set) var baseName = ""
    private(set) var fileHash = ""
    private(set) var warnings: [MIDIWarning] = []
    var showWarnings = false
    private(set) var revision = 0
    private(set) var isDirty = false
    private(set) var counts: [VoiceID: Int] = [:]
    private(set) var unassignedCount = 0
    private(set) var chordInfo: (chords: [[Int]], chordOf: [Int]) = ([], [])
    var pending: PendingLoad?

    var doc: SplitDocument? { editor?.document }
    var voices: [Voice] { editor?.document.voices ?? [] }
    var hasDocument: Bool { editor != nil }

    // MARK: Herramientas y vista

    var tool: Tool = .brush { didSet { controller.toolChanged() } }
    var activeVoiceID: VoiceID? {
        didSet { if let v = activeVoiceID, !selectedVoiceIDs.contains(v) { selectedVoiceIDs = [v] } }
    }
    var selection: Set<Int> = [] { didSet { controller.redraw() } }
    var showVelocity = UserDefaults.standard.object(forKey: "showVelocity") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showVelocity, forKey: "showVelocity"); controller.redraw() }
    }
    var showLabels = UserDefaults.standard.object(forKey: "showLabels") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showLabels, forKey: "showLabels"); controller.redraw() }
    }
    var showChords = UserDefaults.standard.bool(forKey: "showChords") {
        didSet { UserDefaults.standard.set(showChords, forKey: "showChords"); controller.redraw() }
    }
    /// Octava con la que se nombra la nota 60 (Logic: C3).
    var middleCOctave = UserDefaults.standard.object(forKey: "middleCOctave") as? Int ?? 3 {
        didSet { UserDefaults.standard.set(middleCOctave, forKey: "middleCOctave"); controller.redraw() }
    }

    let controller = PianoRollController()

    // MARK: Auto-split

    var showAutoSplit = true
    var splitOptionsExpanded = false
    var exportExpanded = false
    var sidebarVisibility: NavigationSplitViewVisibility = .all
    var params = SplitParams() {
        didSet {
            guard params != oldValue else { return }
            if params.chordWindowMs != oldValue.chordWindowMs { recomputeChords() }
            saveParamsDefault()
            modeKnob = Double(SplitSection.modes.firstIndex(of: params.mode) ?? 0)
        }
    }
    private(set) var isPreviewing = false
    private(set) var preview: [VoiceID?]?
    private(set) var previewCounts: [Int] = []

    // MARK: Exportación

    var exportOptions = ExportOptions() { didSet { scheduleSave() } }

    // MARK: Audio

    let audio = PreviewEngine()
    private(set) var isPlaying = false
    private(set) var playheadTick = 0
    var loopEnabled = false { didSet { controller.redraw() } }
    var metronome = false { didSet { audio.setMetronome(metronome) } }
    var metronomeSound = MetronomeSound(rawValue: UserDefaults.standard.string(forKey: "metronomeSound") ?? "") ?? .klopfgeist {
        didSet { UserDefaults.standard.set(metronomeSound.rawValue, forKey: "metronomeSound"); metronomeSettingsChanged() }
    }
    var metronomeVolume = UserDefaults.standard.object(forKey: "metronomeVolume") as? Double ?? 0.7 {
        didSet { UserDefaults.standard.set(metronomeVolume, forKey: "metronomeVolume"); metronomeSettingsChanged() }
    }
    var metronomeAccent = UserDefaults.standard.object(forKey: "metronomeAccent") as? Bool ?? true {
        didSet { UserDefaults.standard.set(metronomeAccent, forKey: "metronomeAccent"); metronomeSettingsChanged() }
    }
    private func metronomeSettingsChanged() {
        audio.setMetronomeSound(metronomeSound, volume: metronomeVolume, accent: metronomeAccent)
        if isPlaying { audio.reloadWhilePlaying(model: self) }
    }
    var instrument: PreviewInstrument = .piano { didSet { audio.setInstrument(instrument.rawValue) } }
    var tempoBPM: Double = 120 {
        didSet {
            audio.setRate(rate)
            // Notas pegadas: el tempo de abajo es el del clip (también el de los archivos exportados).
            guard pastedText != nil, abs(tempoBPM - pasteOptions.bpm) > 0.001 else { return }
            pasteTempoWork?.cancel()
            let w = DispatchWorkItem { [weak self] in guard let self else { return }; self.reinterpretPaste(bpm: self.tempoBPM) }
            pasteTempoWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
        }
    }
    private var pasteTempoWork: DispatchWorkItem?
    /// Compás al inicio del clip.
    var meterLabel: String {
        if pastedText != nil { return "\(pasteOptions.numerator ?? 4)/\(pasteOptions.denominator)" }
        guard let m = doc?.tempoMap.meter(atTick: 0) else { return "4/4" }
        return "\(m.numerator)/\(m.denominator)"
    }
    private var playTimer: Timer?

    // MARK: Diálogos


    private let store = SessionStore()
    private var saveWork: DispatchWorkItem?
    weak var window: NSWindow? {
        didSet {
            updateWindow()
            applyFloating()
            // Que el foco no empiece en el campo de BPM (se tragaría ⌘V y las teclas de una letra).
            if let w = window, let v = controller.view { DispatchQueue.main.async { w.makeFirstResponder(v) } }
        }
    }

    /// Ventana por encima de las demás apps y presente en todos los Espacios, incluido Logic a pantalla completa.
    var keepAbove = UserDefaults.standard.object(forKey: "keepAbove") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepAbove, forKey: "keepAbove"); applyFloating() }
    }

    func applyFloating() {
        // macOS solo deja una ventana encima del Espacio a pantalla completa de otra app si la app no tiene icono en el Dock.
        let policy: NSApplication.ActivationPolicy = keepAbove ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        guard let w = window else { return }
        if keepAbove {
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.hidesOnDeactivate = false
            // Sin restauración de estado: si no, macOS la reabre en el Espacio donde estaba (el escritorio).
            w.isRestorable = false
            // Volver a mostrarla para que entre en el Espacio actual (p. ej. Logic a pantalla completa).
            if w.isVisible { w.orderFrontRegardless() }
        } else {
            w.level = .normal
            w.collectionBehavior = [.managed, .fullScreenPrimary]
        }
    }

    static let dawBundleIDs = ["com.apple.logic10", "com.apple.mainstage3"]

    /// Mostrar VSplit encima del DAW: si Logic está abierto, primero se pasa a su Espacio (también a pantalla
    /// completa) y la ventana aparece ahí; luego VSplit toma el foco sin cambiar de Espacio.
    func bringToFront() {
        NSApp.unhide(nil)
        let daw = Self.dawBundleIDs.lazy.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }.first
        guard keepAbove, let daw, !daw.isHidden, !daw.isActive || NSApp.isActive else { showWindow(); return }
        daw.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated { self?.showWindow() }
        }
    }

    private var placedAtLaunch = false

    /// Pantalla donde se trabaja: la de la ventana de Logic; si no, la del puntero.
    static func workScreen() -> NSScreen? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first?.processIdentifier,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            let rects = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
                .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
            if let big = rects.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                // CG: origen arriba a la izquierda de la pantalla principal; AppKit: abajo a la izquierda.
                let center = NSPoint(x: big.midX, y: primaryHeight - big.midY)
                if let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return s }
            }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    private func showWindow() {
        applyFloating()
        guard let w = window ?? NSApp.windows.first(where: { $0.contentView != nil && $0.canBecomeMain }) else { return }
        // Al abrir: pequeña, abajo a la derecha con margen, para no tapar el DAW.
        if !placedAtLaunch, let screen = Self.workScreen() {
            placedAtLaunch = true
            let v = screen.visibleFrame, margin: CGFloat = 40
            let size = NSSize(width: max(860, min(980, v.width * 0.5)), height: max(520, min(600, v.height * 0.55)))
            w.setFrame(NSRect(x: v.maxX - size.width - margin, y: v.minY + margin, width: size.width, height: size.height), display: true)
        }
        w.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "splitParams.v3"), let p = try? JSONDecoder().decode(SplitParams.self, from: data) { params = p }
        controller.model = self
        installKeyMonitor()
        audio.setMetronomeSound(metronomeSound, volume: metronomeVolume, accent: metronomeAccent)
        modeKnob = Double(SplitSection.modes.firstIndex(of: params.mode) ?? 0)
    }

    // MARK: - Abrir

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.midi, UTType(filenameExtension: "mid") ?? .midi, UTType(filenameExtension: "rmi") ?? .midi]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    /// Archivos que llegan a ~/Documents/VSplit (exportados desde Logic).
    private var watcher: FolderWatcher?
    func startWatchingFolder() {
        guard watcher == nil else { return }
        watcher = FolderWatcher { [weak self] url in self?.open(url: url, fromLogicExport: true); self?.bringToFront() }
        // Si el agente nos ha abierto por un archivo recién exportado, abrirlo ya.
        let fresh = ((try? FileManager.default.contentsOfDirectory(at: FolderWatcher.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { ["mid", "midi", "smf"].contains($0.pathExtension.lowercased()) }
            .compactMap { u -> (URL, Date)? in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (u, $0) } }
            .filter { Date().timeIntervalSince($0.1) < 90 }
            .max { $0.1 < $1.1 }
        if let (url, _) = fresh, !hasDocument { open(url: url, fromLogicExport: true) }
    }

    /// Abrir VSplit automáticamente cuando llega un MIDI a Documentos › VSplit (agente de launchd).
    var autoOpenFromFolder = WatchAgent.isInstalled {
        didSet { guard autoOpenFromFolder != oldValue else { return }; if autoOpenFromFolder { WatchAgent.install() } else { WatchAgent.uninstall() } }
    }

    // MARK: Tutorial

    var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingDone.v1") { didSet { if showOnboarding { onboardingStep = 0 } } }
    var onboardingStep = 0
    var onboardingLang: OnbLang = {
        if let saved = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first { return saved.hasPrefix("es") ? .es : .en }
        return OnbLang.system
    }()

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingDone.v1")
        showOnboarding = false
        // Si se eligió otro idioma que el de la interfaz, aplicarlo a toda la app (relanzándola).
        let current = (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("es") ? OnbLang.es : .en
        guard onboardingLang != current else { return }
        UserDefaults.standard.set([onboardingLang.rawValue], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open -b \(Bundle.main.bundleIdentifier ?? "io.github.jdevesablanco.VSplit")"]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// Compás de Logic donde empezaba el MIDI exportado a la carpeta (se abre sin el espacio vacío de delante).
    private(set) var fileOriginBar: Int?
    /// Clip recién llegado: se presenta con una pequeña animación antes de ver el editor.
    var arrival: Arrival?
    /// De dónde viene el próximo clip que se cargue (nil: recargas internas, sin animación).
    private var arrivalSource: Arrival.Source?

    func open(url: URL, fromLogicExport: Bool = false) {
        if arrivalSource == nil { arrivalSource = fromLogicExport ? .folder : .file }
        do {
            let data = try Data(contentsOf: url)
            if fromLogicExport {
                let parsed = try MIDIParser.parse(data: data)
                let (seq, bar) = LogicClipboard.trimmed(parsed)
                pastedText = nil
                fileOriginBar = bar > 1 ? bar : nil
                try openSequence(seq, url: url, hash: SessionStore.hash(data), name: url.deletingPathExtension().lastPathComponent)
                return
            }
            fileOriginBar = nil
            try open(data: data, url: url, name: url.deletingPathExtension().lastPathComponent)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            presentError(String(localized: "Can't open “\(url.lastPathComponent)”"), error.localizedDescription)
        }
    }

    func open(data: Data, url: URL?, name: String) throws {
        if arrivalSource == nil { arrivalSource = .file }
        pastedText = nil
        try openSequence(try MIDIParser.parse(data: data), url: url, hash: SessionStore.hash(data), name: name)
    }

    private func openSequence(_ seq: MIDISequence, url: URL?, hash: String, name: String) throws {
        guard !seq.notes.isEmpty else { throw MIDIError.empty }
        let withNotes = seq.tracksWithNotes
        if let saved = store.load(hash: hash), saved.notes != nil || SplitDocument(sequence: seq, tracks: saved.tracks).notes.count == saved.assignments.count {
            load(seq, tracks: saved.tracks, url: url, hash: hash, name: name, saved: saved)
        } else if withNotes.count > 1 {
            pending = PendingLoad(sequence: seq, url: url, hash: hash, name: name, choice: Dictionary(uniqueKeysWithValues: withNotes.map { ($0.index, true) }))
        } else {
            load(seq, tracks: withNotes.map(\.index), url: url, hash: hash, name: name, saved: nil)
        }
    }

    // MARK: - Copiar / cortar notas (⌘C / ⌘X)

    static let ownSelectionType = NSPasteboard.PasteboardType("io.github.jdevesablanco.vsplit.selection")

    /// Copia las notas seleccionadas como un .mid (se puede pegar en el Finder). ⌘X además las quita de su voz.
    func copySelection(cut: Bool) {
        if forwardToTextField(cut ? #selector(NSText.cut(_:)) : #selector(NSText.copy(_:))) { return }
        guard let d = doc, !selection.isEmpty else { NSSound.beep(); return }
        let notes = selection.sorted().map { d.notes[$0] }
        let conductor = Exporter.conductorTrack(d, offset: 0, name: nil)
        let data = MIDIWriter.write(format: 1, ppq: d.ppq, tracks: [conductor, MIDIWriter.Track(notes: notes, events: [.trackName(baseName)], endTick: conductor.endTick)])
        let folder = PreviewEngine.cacheDir.appendingPathComponent("Clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(Exporter.sanitize(baseName))_\(notes.count).mid")
        do { try data.write(to: url, options: .atomic) } catch { presentError(String(localized: "Can't copy"), error.localizedDescription); return }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.midi.identifier))
        item.setString("", forType: Self.ownSelectionType)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
        if cut { assign(Array(selection), to: nil, name: String(localized: "Cut")) }
    }

    // MARK: - Pegar (⌘V)

    /// Texto de Logic pegado y cómo se ha interpretado (el texto no trae compás ni tempo).
    private(set) var pastedText: String?
    var pasteOptions = LogicClipboard.Options()
    /// Compás de Logic donde empezaba el clip pegado (se pega sin el espacio vacío de delante).
    private(set) var pasteOriginBar: Int?
    /// Si el tempo y el compás se han leído de Logic.
    private(set) var pasteReadFromLogic = false

    func paste() {
        let pb = NSPasteboard.general
        // Notas copiadas desde el propio VSplit: pegarlas sustituiría el clip actual, así que no se hace nada.
        if pb.types?.contains(Self.ownSelectionType) == true, NSApp.keyWindow?.firstResponder as? NSText == nil { NSSound.beep(); return }
        let text = pb.string(forType: .string) ?? ""
        // Notas de Logic, un .mid o un archivo: siempre para VSplit, aunque haya un campo de texto con el foco.
        let hasClip = LogicClipboard.classify(text) == .notes || pb.data(forType: NSPasteboard.PasteboardType(UTType.midi.identifier)) != nil
            || (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.isEmpty == false
        if !hasClip, forwardToTextField(#selector(NSText.paste(_:))) { return }
        if hasClip, NSApp.keyWindow?.firstResponder is NSText { NSApp.keyWindow?.makeFirstResponder(controller.view) }
        if hasClip { arrivalSource = .paste }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let u = urls.first {
            open(url: u); return
        }
        if let d = pb.data(forType: NSPasteboard.PasteboardType(UTType.midi.identifier)) {
            do { try open(data: d, url: nil, name: "Clip") } catch { presentError(String(localized: "Can't paste"), error.localizedDescription) }
            return
        }
        switch LogicClipboard.classify(text) {
        case .notes:
            pasteOptions = LogicClipboard.Options(middleCOctave: middleCOctave)
            // Tempo y compás del proyecto de Logic, leídos de su barra de control.
            if let info = LogicReader.read(prompt: true) {
                if let b = info.bpm, b > 10 { pasteOptions.bpm = b }
                if let n = info.numerator { pasteOptions.numerator = n }
                if let d = info.denominator { pasteOptions.denominator = d }
                pasteReadFromLogic = true
            } else {
                pasteReadFromLogic = false
            }
            openPasted(text)
        case .regionSummary:
            presentError(String(localized: "That's the region, not its notes"),
                         String(localized: "Logic only copies a summary when you copy a whole region. Double-click the region to open the Piano Roll, press ⌘A and ⌘C there, then paste here with ⌘V."))
        case .other:
            presentError(String(localized: "Nothing to paste"),
                         String(localized: "Copy some notes first: in Logic, open the region in the Piano Roll, press ⌘A and ⌘C. You can also copy a .mid file in the Finder."))
        }
    }

    private func openPasted(_ text: String) {
        fileOriginBar = nil
        do {
            let (seq, bar) = LogicClipboard.trimmed(try LogicClipboard.parse(text, options: pasteOptions))
            pasteOriginBar = bar
            pastedText = text
            let stamp = Date().formatted(.dateTime.hour().minute())
            try openSequence(seq, url: nil, hash: SessionStore.hash(Data(text.utf8)), name: "Logic \(stamp)".replacingOccurrences(of: ":", with: "."))
            pasteOptions.numerator = seq.tempoMap.meter(atTick: 0).numerator
        } catch {
            presentError(String(localized: "Can't paste"), error.localizedDescription)
        }
    }

    /// Cambiar el compás/tempo asumidos del clip pegado: se reinterpreta manteniendo voces y asignaciones.
    func reinterpretPaste(numerator: Int? = nil, denominator: Int? = nil, bpm: Double? = nil) {
        guard let text = pastedText, let d = doc else { return }
        if let n = numerator { pasteOptions.numerator = n }
        if let dd = denominator { pasteOptions.denominator = dd }
        if let b = bpm { pasteOptions.bpm = b }
        guard let parsed = try? LogicClipboard.parse(text, options: pasteOptions) else { return }
        let (seq, bar) = LogicClipboard.trimmed(parsed)
        guard seq.notes.count == d.notes.count else { return }
        pasteOriginBar = bar
        let keep = SessionState(tracks: [1], voices: d.voices, assignments: d.notes.map(\.voiceID), params: params, export: exportOptions, activeVoice: activeVoiceID)
        let name = baseName
        arrivalSource = nil
        load(seq, tracks: [1], url: nil, hash: fileHash, name: name, saved: keep)
    }

    func confirmPending() {
        guard let p = pending else { return }
        let tracks = p.choice.filter(\.value).map(\.key).sorted()
        pending = nil
        guard !tracks.isEmpty else { return }
        load(p.sequence, tracks: tracks, url: p.url, hash: p.hash, name: p.name, saved: nil)
    }

    private func load(_ seq: MIDISequence, tracks: [Int], url: URL?, hash: String, name: String, saved: SessionState?) {
        stop()
        flushSave()
        var initialVoices = saved?.voices ?? Voice.defaults()
        if saved == nil {
            // Clip nuevo: tantas voces como líneas detectadas (Soprano, Alto, Tenor, Bajo…); el knob "Voces" lo cambia.
            let probe = SplitDocument(sequence: seq, tracks: tracks)
            if let m = defaultMode, params.mode != m { params.mode = m }
            let n = defaultVoiceCount ?? NaturalVoices.detectCount(notes: probe.notes, indices: Array(probe.notes.indices), windowMs: params.chordWindowMs, tempoMap: probe.tempoMap)
            initialVoices = NaturalVoices.defaultVoices(count: n)
            if alternates(voiceCount: n) { for i in initialVoices.indices { initialVoices[i].name = Voice.defaultName(index: i) } }
        }
        var ed = Editor(document: SplitDocument(sequence: seq, tracks: tracks, voices: initialVoices))
        if let saved {
            if let notes = saved.notes { ed.restore(notes: notes, voices: saved.voices) }
            else { ed.restore(voices: saved.voices, assignments: saved.assignments) }
            if saved.params != params { params = saved.params }
            exportOptions = saved.export
        }
        editor = ed
        fileURL = url
        baseName = name
        fileHash = hash
        warnings = seq.warnings
        showWarnings = !warnings.isEmpty
        selection = []
        isPreviewing = false
        preview = nil
        activeVoiceID = saved?.activeVoice.flatMap { id in ed.document.voices.contains { $0.id == id } ? id : nil } ?? ed.document.voices.first?.id
        tempoBPM = (ed.document.tempoMap.initialBPM * 100).rounded() / 100
        playheadTick = 0
        recomputeChords()
        if saved == nil { applyAutoSplit(selectionOnly: false, name: String(localized: "Auto-split")) }
        documentChanged()
        isDirty = false
        updateWindow()
        audio.invalidate()
        controller.fitToContent()
        if let src = arrivalSource {
            arrivalSource = nil
            arrival = Arrival(source: src, document: ed.document, name: name, originBar: pastedText != nil ? pasteOriginBar : fileOriginBar)
        }
    }

    // MARK: - Cambios

    private func perform(_ cmd: EditCommand?) {
        guard let cmd, editor != nil else { return }
        cancelPreviewIfNeeded()
        editor!.perform(cmd)
        documentChanged()
    }

    private func documentChanged() {
        guard let d = doc else { return }
        revision += 1
        recomputeChords()
        voiceKnob = Double(d.voices.count)
        selectedVoiceIDs = selectedVoiceIDs.filter { id in d.voices.contains { $0.id == id } }
        counts = d.counts()
        unassignedCount = d.notes.count - counts.values.reduce(0, +)
        if let a = activeVoiceID, d.voice(a) == nil { activeVoiceID = d.voices.first?.id }
        isDirty = true
        if isPreviewing { recomputePreview() }
        audio.invalidate()
        if isPlaying { audio.reloadWhilePlaying(model: self) }
        audio.applyMixer(voices: d.voices)
        controller.redraw()
        updateWindow()
        scheduleSave()
    }

    func undo() {
        if forwardToTextField(#selector(UndoManager.undo)) { return }
        guard editor?.canUndo == true else { return }
        cancelPreviewIfNeeded()
        editor!.undo()
        documentChanged()
    }

    func redo() {
        if forwardToTextField(#selector(UndoManager.redo)) { return }
        guard editor?.canRedo == true else { return }
        cancelPreviewIfNeeded()
        editor!.redo()
        documentChanged()
    }

    var undoTitle: String { editor?.undoName.map { String(localized: "Undo \($0)") } ?? String(localized: "Undo") }
    var redoTitle: String { editor?.redoName.map { String(localized: "Redo \($0)") } ?? String(localized: "Redo") }

    /// Si se está escribiendo en un campo de texto, ⌘Z/⌘A son suyos.
    private func forwardToTextField(_ sel: Selector) -> Bool {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable else { return false }
        if sel == #selector(UndoManager.undo) { tv.undoManager?.undo() }
        else if sel == #selector(UndoManager.redo) { tv.undoManager?.redo() }
        else { NSApp.sendAction(sel, to: tv, from: nil) }
        return true
    }

    // MARK: - Asignación

    func assign(_ indices: [Int], to voice: VoiceID?, name: String? = nil) {
        guard let d = doc else { return }
        perform(d.assignCommand(indices, to: voice, name: name ?? (voice == nil ? String(localized: "Unassign") : String(localized: "Assign"))))
    }

    func assignSelection(toVoiceAt index: Int) {
        guard index < voices.count else { return }
        activeVoiceID = voices[index].id
        if !selection.isEmpty { assign(Array(selection), to: voices[index].id) }
    }

    func unassignSelection() { assign(Array(selection), to: nil) }

    /// Tab / ⇧Tab: cada nota seleccionada pasa a la voz siguiente/anterior (las sin asignar, a la primera/última).
    func shiftSelection(by delta: Int) {
        guard let d = doc, !d.voices.isEmpty, !selection.isEmpty else { return }
        let n = d.voices.count
        let pairs: [(Int, VoiceID?)] = selection.map { i in
            let cur = d.voiceIndex(d.notes[i].voiceID)
            let next = cur.map { (($0 + delta) % n + n) % n } ?? (delta > 0 ? 0 : n - 1)
            return (i, d.voices[next].id)
        }
        perform(d.assignCommand(pairs: pairs, name: delta > 0 ? String(localized: "Next Voice") : String(localized: "Previous Voice")))
    }

    func swapVoices(_ a: VoiceID, _ b: VoiceID) {
        guard let d = doc, a != b else { return }
        var pairs: [(Int, VoiceID?)] = []
        for (i, n) in d.notes.enumerated() {
            if n.voiceID == a { pairs.append((i, b)) } else if n.voiceID == b { pairs.append((i, a)) }
        }
        perform(d.assignCommand(pairs: pairs, name: String(localized: "Swap Voices")))
    }

    // Trazos de brocha/borrador

    func beginStroke(erase: Bool) {
        guard editor != nil else { return }
        cancelPreviewIfNeeded()
        editor!.beginStroke(name: erase ? String(localized: "Erase") : String(localized: "Paint"))
    }

    func strokeAssign(_ indices: [Int], erase: Bool) {
        guard editor?.isStroking == true else { return }
        let v: VoiceID? = erase ? nil : activeVoiceID
        if !erase && v == nil { return }
        if editor!.strokeAssign(indices, to: v) { controller.redraw() }
    }

    func endStroke() {
        guard editor?.isStroking == true else { return }
        editor!.endStroke()
        documentChanged()
    }

    // MARK: - Voces

    func addVoice() {
        guard var ed = editor else { return }
        var vs = ed.document.voices
        let names = Set(vs.map(\.name))
        var k = vs.count + 1
        while names.contains(String(localized: "Voice \(k)")) { k += 1 }
        let v = Voice(id: ed.makeVoiceID(), name: String(localized: "Voice \(k)"), color: Voice.palette[vs.count % Voice.palette.count])
        vs.append(v)
        editor = ed
        perform(ed.document.voicesCommand(vs, name: String(localized: "Add Voice")))
        activeVoiceID = v.id
    }

    // MARK: Selección de voces (⌘-clic) y unir (⌘J)

    var selectedVoiceIDs: Set<VoiceID> = []

    func clickVoiceRow(_ id: VoiceID, additive: Bool) {
        if additive {
            if selectedVoiceIDs.isEmpty, let a = activeVoiceID { selectedVoiceIDs = [a] }
            if selectedVoiceIDs.contains(id) && selectedVoiceIDs.count > 1 { selectedVoiceIDs.remove(id) } else { selectedVoiceIDs.insert(id) }
        } else {
            selectedVoiceIDs = [id]
        }
        activeVoiceID = id
    }

    var canJoinVoices: Bool { selectedVoiceIDs.count >= 2 }

    func joinSelectedVoices() {
        guard let d = doc, canJoinVoices else { NSSound.beep(); return }
        let target = d.voices.first { selectedVoiceIDs.contains($0.id) }?.id
        perform(d.joinCommand(selectedVoiceIDs, name: String(localized: "Join Voices")))
        selectedVoiceIDs = target.map { [$0] } ?? []
        activeVoiceID = target
    }

    // MARK: Modo (knob)

    var modeKnob: Double = 0

    /// Con este modo y este número de voces, ¿se alterna (A/B…) en vez de separar por líneas?
    func alternates(voiceCount n: Int) -> Bool { params.mode == .fairAlternate || params.mode == .alternate || (params.mode == .auto && n == 2) }

    /// Cambia el modo de reparto y lo aplica enseguida (un paso de deshacer). Los nombres por defecto siguen al modo.
    func setMode(_ m: SplitMode) {
        if params.mode != m { params.mode = m }
        guard let d = doc else { return }
        let roles = NaturalVoices.roleNames(d.voices.count)
        let letters = d.voices.indices.map { Voice.defaultName(index: $0) }
        var vs = d.voices
        // Solo se renombran voces que tengan aún un nombre por defecto.
        if vs.map(\.name) == roles || vs.map(\.name) == letters {
            let target = alternates(voiceCount: vs.count) ? letters : roles
            for i in vs.indices { vs[i].name = target[i] }
        }
        perform(d.voicesCommand(vs, name: String(localized: "Split: \(m.title)"), reassign: computeSplit(indices: Array(d.notes.indices), voices: vs))
                ?? d.assignCommand(pairs: computeSplit(indices: Array(d.notes.indices)), name: String(localized: "Split: \(m.title)")))
    }

    // MARK: Voces y modo por defecto (menú ⋯)

    /// Con cuántas voces empieza un clip nuevo; nil: las que se detectan.
    var defaultVoiceCount: Int? = UserDefaults.standard.object(forKey: "defaultVoiceCount") as? Int {
        didSet { UserDefaults.standard.set(defaultVoiceCount, forKey: "defaultVoiceCount") }
    }
    /// Modo con el que empieza un clip nuevo; nil: el último usado.
    var defaultMode: SplitMode? = UserDefaults.standard.string(forKey: "defaultMode").flatMap(SplitMode.init(rawValue:)) {
        didSet { UserDefaults.standard.set(defaultMode?.rawValue, forKey: "defaultMode") }
    }

    func setCurrentAsDefault() {
        defaultVoiceCount = voices.count
        defaultMode = params.mode
    }

    func clearDefault() {
        defaultVoiceCount = nil
        defaultMode = nil
    }

    // MARK: Número de voces (knob)

    /// Valor del knob "Voces" (se sincroniza con el número de voces; al soltarlo se reparte de nuevo).
    var voiceKnob: Double = 2

    func setVoiceCount(_ n: Int) {
        guard var ed = editor, n >= 1, n != ed.document.voices.count else { voiceKnob = Double(voices.count); return }
        let old = ed.document.voices
        var vs = NaturalVoices.defaultVoices(count: n)
        for i in vs.indices {
            vs[i].id = i < old.count ? old[i].id : ed.makeVoiceID()
            if alternates(voiceCount: n) { vs[i].name = Voice.defaultName(index: i) }   // A, B… si se alterna
        }
        editor = ed
        isPreviewing = false; preview = nil
        perform(ed.document.voicesCommand(vs, name: String(localized: "Voices: \(n)"), reassign: computeSplit(indices: Array(ed.document.notes.indices), voices: vs)))
        if !(vs.contains { $0.id == activeVoiceID }) { activeVoiceID = vs.first?.id }
    }

    // MARK: Edición de notas (Dibujar, alargar, borrar)

    /// Duración de la última nota dibujada (la siguiente empieza igual, como en FL Studio).
    var lastDrawLength: Int?

    func replaceNotes(_ notes: [Note], name: String, select: (Note) -> Bool = { _ in false }) {
        guard let d = doc, let cmd = d.notesCommand(notes, name: name) else { return }
        perform(cmd)
        if let d2 = doc { selection = Set(d2.notes.indices.filter { select(d2.notes[$0]) }) }
    }

    func deleteNotes(_ indices: [Int]) {
        guard let d = doc, !indices.isEmpty else { return }
        let gone = Set(indices)
        replaceNotes(d.notes.enumerated().filter { !gone.contains($0.offset) }.map(\.element), name: String(localized: "Delete Notes"))
        selection = []
    }

    // MARK: Atajos de edición estilo Logic

    private func noteKey(_ n: Note) -> String { "\(n.pitch)-\(n.startTick)-\(n.channel)-\(n.durationTick)" }

    private func editSelection(name: String, _ change: (inout Note) -> Void) {
        guard let d = doc, !selection.isEmpty else { NSSound.beep(); return }
        var all = d.notes
        var keys = Set<String>()
        for i in selection { change(&all[i]); keys.insert(noteKey(all[i])) }
        replaceNotes(all, name: name) { keys.contains(self.noteKey($0)) }
    }

    func transposeSelection(_ semitones: Int) {
        guard let d = doc, !selection.isEmpty else { NSSound.beep(); return }
        let lo = selection.map { Int(d.notes[$0].pitch) }.min()!, hi = selection.map { Int(d.notes[$0].pitch) }.max()!
        guard lo + semitones >= 0, hi + semitones <= 127 else { NSSound.beep(); return }
        editSelection(name: abs(semitones) == 12 ? String(localized: "Transpose Octave") : String(localized: "Transpose")) { $0.pitch = UInt8(Int($0.pitch) + semitones) }
        if let i = selection.first, let d2 = doc { playPitch(Int(d2.notes[i].pitch)) }
    }

    /// Mover en el tiempo por la unidad de rejilla visible.
    func nudgeSelection(_ dir: Int) {
        guard let d = doc, !selection.isEmpty else { NSSound.beep(); return }
        let t = selection.map { d.notes[$0].startTick }.min()!
        let unit = controller.snapUnit(at: t)
        if dir < 0, t - unit < 0 { NSSound.beep(); return }
        editSelection(name: String(localized: "Nudge")) { $0.startTick += dir * unit }
    }

    func resizeSelection(_ dir: Int) {
        guard let d = doc, !selection.isEmpty else { NSSound.beep(); return }
        let unit = controller.snapUnit(at: selection.map { d.notes[$0].startTick }.min()!)
        editSelection(name: String(localized: "Change Length")) { $0.durationTick = max(unit, $0.durationTick + dir * unit) }
    }

    func quantizeSelection() {
        guard let d = doc, !selection.isEmpty else { NSSound.beep(); return }
        let map = d.tempoMap
        editSelection(name: String(localized: "Quantize")) { n in
            let unit = self.controller.snapUnit(at: n.startTick)
            n.startTick = Snap.snap(n.startTick, unit: unit, origin: map.barStartTick(containing: n.startTick))
        }
    }

    /// ← / →: seleccionar la nota anterior/siguiente en el tiempo.
    func selectAdjacent(_ dir: Int) {
        guard let d = doc, !d.notes.isEmpty else { return }
        let i: Int
        if selection.isEmpty { i = dir > 0 ? 0 : d.notes.count - 1 }
        else { i = dir > 0 ? min(d.notes.count - 1, selection.max()! + 1) : max(0, selection.min()! - 1) }
        selection = [i]
        controller.scrollToTick(d.notes[i].startTick)
        playPitch(Int(d.notes[i].pitch))
    }

    func deleteSelectedNotes() {
        if forwardToTextField(#selector(NSText.delete(_:))) { return }
        deleteNotes(Array(selection))
    }

    func duplicateVoice(_ id: VoiceID) {
        guard var ed = editor, let i = ed.document.voiceIndex(id) else { return }
        var vs = ed.document.voices
        var v = vs[i]
        v.id = ed.makeVoiceID()
        v.name += " 2"
        v.color = Voice.palette[(Voice.palette.firstIndex(of: vs[i].color) ?? i) + 1 < Voice.palette.count ? (Voice.palette.firstIndex(of: vs[i].color) ?? i) + 1 : 0]
        v.isMuted = false; v.isSolo = false
        vs.insert(v, at: i + 1)
        editor = ed
        perform(ed.document.voicesCommand(vs, name: String(localized: "Duplicate Voice")))
    }

    func requestDelete(_ id: VoiceID) {
        guard voices.count > 1, let v = doc?.voice(id) else { NSSound.beep(); return }
        let n = counts[id] ?? 0
        guard n > 0 else { deleteVoice(id, moveTo: nil); return }
        // Una lista desplegable con todas las voces (un diálogo de botones se queda corto con muchas voces).
        let others = voices.filter { $0.id != id }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete voice “\(v.name)” (\(n) notes)?")
        alert.informativeText = String(localized: "What should happen to its notes?")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        for o in others { popup.addItem(withTitle: String(localized: "Move notes to \(o.name)")) }
        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: String(localized: "Leave notes unassigned"))
        alert.accessoryView = popup
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let k = popup.indexOfSelectedItem
        deleteVoice(id, moveTo: k < others.count ? others[k].id : nil)
    }

    func deleteVoice(_ id: VoiceID, moveTo target: VoiceID?) {
        guard let d = doc, d.voices.count > 1 else { return }
        let moving = d.notes.indices.filter { d.notes[$0].voiceID == id }
        let index = d.voiceIndex(id) ?? 0
        let remaining = d.voices.filter { $0.id != id }
        perform(d.voicesCommand(remaining, name: String(localized: "Delete Voice"), reassign: moving.map { ($0, target) }))
        // La voz activa pasa a la vecina, no a la primera (así ⌘⌫ dos veces no borra la soprano).
        if activeVoiceID == id || activeVoiceID == nil { activeVoiceID = remaining[min(index, remaining.count - 1)].id }
    }

    func moveVoices(from: IndexSet, to: Int) {
        guard let d = doc else { return }
        var vs = d.voices
        vs.move(fromOffsets: from, toOffset: to)
        perform(d.voicesCommand(vs, name: String(localized: "Reorder Voices")))
    }

    func moveVoice(_ id: VoiceID, by delta: Int) {
        guard let i = doc?.voiceIndex(id) else { return }
        let j = i + delta
        guard j >= 0, j < voices.count else { return }
        moveVoices(from: IndexSet(integer: i), to: delta > 0 ? j + 1 : j)
    }

    /// Nombre, color, pan: deshacibles; los cambios seguidos del mismo campo cuentan como uno.
    func updateVoice(_ id: VoiceID, field: String, _ change: (inout Voice) -> Void) {
        guard let d = doc, let i = d.voiceIndex(id) else { return }
        var vs = d.voices
        change(&vs[i])
        let names = ["name": String(localized: "Rename Voice"), "color": String(localized: "Change Color"), "pan": String(localized: "Change Pan")]
        perform(d.voicesCommand(vs, name: names[field] ?? field, coalesceKey: "\(field)-\(id)"))
    }

    func endVoiceEditing() { editor?.breakCoalescing() }

    /// Voz cuyo nombre se está editando (doble clic en el nombre).
    var renamingVoiceID: VoiceID?
    func finishRenaming() {
        renamingVoiceID = nil
        endVoiceEditing()
        if let v = controller.view { window?.makeFirstResponder(v) }
    }

    /// ⌘⌫: borra la voz activa, salvo que se esté escribiendo (entonces borra el texto hasta el inicio de la línea).
    func deleteActiveVoiceCommand() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable {
            tv.deleteToBeginningOfLine(nil); return
        }
        if let v = activeVoiceID { requestDelete(v) }
    }

    func toggleMute(_ id: VoiceID) {
        guard let v = doc?.voice(id) else { return }
        editor!.setPlaybackState(voice: id, muted: !v.isMuted)
        playbackStateChanged()
    }

    func toggleSolo(_ id: VoiceID) {
        guard let v = doc?.voice(id) else { return }
        editor!.setPlaybackState(voice: id, solo: !v.isSolo)
        playbackStateChanged()
    }

    /// "Escuchar voz sola": solo exclusivo; si ya era la única en solo, se quita.
    func listenAlone(_ id: VoiceID) {
        guard let d = doc else { return }
        let only = d.voices.filter(\.isSolo).map(\.id) == [id]
        editor!.setSoloExclusive(only ? nil : id)
        playbackStateChanged()
        if !only && !isPlaying { togglePlay() }
    }

    private func playbackStateChanged() {
        audio.applyMixer(voices: voices)
        controller.redraw()
        scheduleSave()
    }

    func voiceName(_ id: VoiceID?) -> String { doc?.voice(id)?.name ?? String(localized: "Unassigned") }

    // MARK: - Selección

    func selectAll() {
        if forwardToTextField(#selector(NSText.selectAll(_:))) { return }
        guard let d = doc else { return }
        selection = Set(d.notes.indices)
    }
    func deselectAll() { selection = [] }
    func invertSelection() {
        guard let d = doc else { return }
        selection = Set(d.notes.indices).subtracting(selection)
    }
    func selectUnassigned() { selection = Set(doc?.unassignedIndices ?? []) }
    func selectVoice(_ id: VoiceID?) {
        guard let d = doc else { return }
        selection = Set(d.notes.indices.filter { d.notes[$0].voiceID == id })
    }
    func selectSamePitch() {
        guard let d = doc, !selection.isEmpty else { return }
        let pitches = Set(selection.map { d.notes[$0].pitch })
        selection = Set(d.notes.indices.filter { pitches.contains(d.notes[$0].pitch) })
    }
    func selectChords(of indices: some Sequence<Int>, add: Bool = false) {
        guard !chordInfo.chordOf.isEmpty else { return }
        var s = add ? selection : []
        for i in indices where i < chordInfo.chordOf.count { s.formUnion(chordInfo.chordOf.isEmpty ? [] : chordInfo.chords[chordInfo.chordOf[i]]) }
        selection = s
    }
    func selectChordsOfSelection() { selectChords(of: Array(selection)) }
    func selectActiveVoice() { selectVoice(activeVoiceID) }

    // MARK: - Auto-split

    private func recomputeChords() {
        guard let d = doc else { chordInfo = ([], []); return }
        chordInfo = ChordDetector.chordIndex(notes: d.notes, windowMs: params.chordWindowMs, tempoMap: d.tempoMap)
        detectVoices()
        controller.redraw()
    }

    private func computeSplit(indices: [Int], voices: [Voice]? = nil) -> [(Int, VoiceID?)] {
        guard let d = doc else { return [] }
        let vs = voices ?? d.voices
        guard !vs.isEmpty else { return [] }
        let r = AutoSplitter.assign(notes: d.notes, indices: indices, voiceCount: vs.count, params: params, tempoMap: d.tempoMap)
        return zip(indices, r).map { ($0, vs[$1].id) }
    }

    /// Voces que suenan a la vez (para el modo "voces naturales").
    private(set) var detectedVoiceCount = 2

    private func detectVoices() {
        guard let d = doc else { return }
        detectedVoiceCount = NaturalVoices.detectCount(notes: d.notes, indices: Array(d.notes.indices), windowMs: params.chordWindowMs, tempoMap: d.tempoMap)
    }

    /// Sustituye la lista de voces por una por línea detectada (Soprano, Alto…) y reparte de nuevo; un solo paso de deshacer.
    func useDetectedVoices() {
        guard var ed = editor else { return }
        let n = detectedVoiceCount
        let vs = NaturalVoices.defaultVoices(count: n).map { v -> Voice in var v = v; v.id = ed.makeVoiceID(); return v }
        editor = ed
        let pairs = computeSplit(indices: Array(ed.document.notes.indices), voices: vs)
        isPreviewing = false; preview = nil
        perform(ed.document.voicesCommand(vs, name: String(localized: "Natural Voices"), reassign: pairs))
        activeVoiceID = vs.first?.id
    }

    private func recomputePreview() {
        guard let d = doc, isPreviewing else { preview = nil; return }
        var p = d.notes.map(\.voiceID)
        var c = [Int](repeating: 0, count: d.voices.count)
        let pairs = computeSplit(indices: Array(d.notes.indices))
        for (i, v) in pairs { p[i] = v }
        for v in p { if let k = d.voiceIndex(v) { c[k] += 1 } }
        preview = p
        previewCounts = c
        controller.redraw()
    }

    func startPreview() { guard hasDocument else { return }; isPreviewing = true; recomputePreview() }

    func applyAutoSplit(selectionOnly: Bool, name: String? = nil) {
        guard let d = doc else { return }
        let indices = selectionOnly ? selection.sorted() : Array(d.notes.indices)
        guard !indices.isEmpty else { return }
        isPreviewing = false
        preview = nil
        perform(d.assignCommand(pairs: computeSplit(indices: indices), name: name ?? String(localized: "Auto-split")))
    }

    func discardPreview() { isPreviewing = false; preview = nil; controller.redraw() }
    private func cancelPreviewIfNeeded() { if isPreviewing { isPreviewing = false; preview = nil } }

    /// Puntos de corte efectivos del modo registro (para dibujarlos y arrastrarlos en el piano roll).
    var registerSplits: [Int] {
        guard let d = doc, params.mode == .register else { return [] }
        return params.registerAuto ? AutoSplitter.quantileSplits(d.notes.map { Int($0.pitch) }, bands: d.voices.count)
                                   : AutoSplitter.normalized(params.registerSplits, bands: d.voices.count, range: 0...127)
    }

    func setRegisterSplit(_ k: Int, pitch: Int) {
        var s = registerSplits
        guard k < s.count else { return }
        s[k] = max(1, min(127, pitch))
        params.registerAuto = false
        params.registerSplits = s.sorted()
    }

    private func saveParamsDefault() {
        if let data = try? JSONEncoder().encode(params) { UserDefaults.standard.set(data, forKey: "splitParams.v3") }
    }

    // MARK: - Exportar

    private func optionsAskingForUnassigned() -> ExportOptions? {
        var o = exportOptions
        guard unassignedCount > 0, case .discard = o.unassigned else { return o }
        let alert = NSAlert()
        alert.messageText = String(localized: "\(unassignedCount) notes are unassigned")
        alert.informativeText = String(localized: "Include them in a voice or leave them out of the exported files?")
        let target = doc?.voice(activeVoiceID) ?? voices.first
        alert.addButton(withTitle: String(localized: "Include in \(target?.name ?? "")"))
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: if let t = target { o.unassigned = .toVoice(t.id) }
        case .alertSecondButtonReturn: break
        default: return nil
        }
        return o
    }

    func exportAllToFolder() {
        guard let d = doc, let o = optionsAskingForUnassigned() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export Here")
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let urls = try Exporter.exportAll(d, base: baseName, to: folder, options: o)
            isDirty = false; updateWindow()
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } catch { presentError(String(localized: "Export failed"), error.localizedDescription) }
    }

    func exportMultitrack() {
        guard let d = doc, let o = optionsAskingForUnassigned() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.midi]
        panel.nameFieldStringValue = "\(Exporter.sanitize(baseName))_voices.mid"
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Exporter.multitrackFile(d, options: o, title: baseName).write(to: url, options: .atomic)
            isDirty = false; updateWindow()
        } catch { presentError(String(localized: "Export failed"), error.localizedDescription) }
    }

    /// Genera bajo demanda los .mid para arrastrar (a Logic o al Finder).
    func dragFiles(for voiceIDs: [VoiceID]) -> [URL] {
        guard let d = doc else { return [] }
        let folder = PreviewEngine.cacheDir.appendingPathComponent("Drag/\(UUID().uuidString)", isDirectory: true)
        let vs = voiceIDs.compactMap { d.voice($0) }
        do {
            let urls = try Exporter.exportAll(d, base: baseName, to: folder, options: exportOptions, voices: vs)
            isDirty = false; updateWindow()
            return urls
        } catch {
            presentError(String(localized: "Export failed"), error.localizedDescription)
            return []
        }
    }

    // MARK: - Transporte

    var rate: Double { max(0.1, tempoBPM / max(1, doc?.tempoMap.initialBPM ?? 120)) }

    func togglePlay() { isPlaying ? stop() : play() }

    func play() {
        guard let d = doc else { return }
        var start = playheadTick
        if let r = loopRange, loopEnabled, start < r.lowerBound || start >= r.upperBound { start = r.lowerBound }
        if start >= d.endTick { start = 0 }
        guard audio.play(model: self, fromTick: start) else {
            presentError(String(localized: "Audio preview is unavailable"), audio.lastError ?? "")
            return
        }
        isPlaying = true
        playTimer?.invalidate()
        playTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        guard isPlaying else { return }
        audio.stop()
        isPlaying = false
        playTimer?.invalidate(); playTimer = nil
        controller.setPlayhead(playheadTick)
    }

    func toStart() {
        let wasPlaying = isPlaying
        stop()
        playheadTick = loopEnabled ? (loopRange?.lowerBound ?? 0) : 0
        controller.setPlayhead(playheadTick)
        controller.scrollToTick(playheadTick)
        if wasPlaying { play() }
    }

    func seek(_ tick: Int) {
        playheadTick = max(0, tick)
        if isPlaying { audio.seek(toTick: playheadTick) }
        controller.setPlayhead(playheadTick)
    }

    /// Rango de loop: la selección si hay; si no, todo el clip.
    var loopRange: Range<Int>? {
        guard let d = doc else { return nil }
        if !selection.isEmpty {
            let s = selection.map { d.notes[$0].startTick }.min()!, e = selection.map { d.notes[$0].endTick }.max()!
            return e > s ? s..<e : nil
        }
        return 0..<max(1, d.endTick)
    }

    private func tick() {
        guard isPlaying, let d = doc else { return }
        var t = audio.currentTick
        if loopEnabled, let r = loopRange, t >= r.upperBound {
            audio.seek(toTick: r.lowerBound); t = r.lowerBound
        } else if t > d.endTick + d.ppq {
            stop(); playheadTick = 0; controller.setPlayhead(0); return
        }
        playheadTick = t
        controller.setPlayhead(t)
        controller.followPlayhead(t)
    }

    func playPitch(_ pitch: Int) { audio.playPreviewNote(pitch) }

    // MARK: - Sesión

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flushSave() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    func flushSave() {
        saveWork?.cancel(); saveWork = nil
        guard let d = doc, !fileHash.isEmpty else { return }
        store.save(SessionState(tracks: d.loadedTracks, voices: d.voices, assignments: d.notes.map(\.voiceID), params: params, export: exportOptions,
                                activeVoice: activeVoiceID, notes: d.notesEdited ? d.notes : nil), hash: fileHash)
    }

    // MARK: - Ventana y errores

    var title: String { hasDocument ? (fileURL?.lastPathComponent ?? baseName) : "VSplit" }

    func updateWindow() {
        guard let w = window else { return }
        w.title = title
        w.representedURL = fileURL
        w.isDocumentEdited = hasDocument && isDirty
    }

    func presentError(_ title: String, _ message: String) {
        arrivalSource = nil
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Teclado

    private var keyMonitor: Any?

    /// Atajos de una tecla (B V L E I, 1–9, espacio, Enter, Tab…). No actúan mientras se escribe en un campo de texto.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let ev = event
            let handled = MainActor.assumeIsolated { self?.handleKey(ev) ?? false }
            return handled ? nil : event
        }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        guard let w = NSApp.keyWindow, w === window, w.attachedSheet == nil else { return false }
        if w.firstResponder is NSText { return false }
        // Atajos de Logic para las notas seleccionadas: ⌥↑↓ semitono, ⇧⌥↑↓ octava, ⌥←→ mover, ⇧⌥←→ duración,
        // ←→ nota anterior/siguiente, Q cuantizar, ⌫ borrar (⌥⌫ quitar la voz).
        if hasDocument, !e.modifierFlags.contains(.command), !e.modifierFlags.contains(.control) {
            let opt = e.modifierFlags.contains(.option), sh = e.modifierFlags.contains(.shift)
            switch e.keyCode {
            case 126 where opt, 125 where opt:
                transposeSelection((e.keyCode == 126 ? 1 : -1) * (sh ? 12 : 1)); return true
            case 123, 124:
                let dir = e.keyCode == 124 ? 1 : -1
                if opt && sh { resizeSelection(dir) } else if opt { nudgeSelection(dir) } else if !sh { selectAdjacent(dir) } else { return false }
                return true
            case 51, 117:
                if opt { unassignSelection() } else { deleteSelectedNotes() }
                return true
            default: break
            }
            if !opt, e.charactersIgnoringModifiers?.lowercased() == "q" { quantizeSelection(); return true }
        }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        // ⌘= también acerca (en teclados donde "+" necesita mayúsculas).
        if mods == .command, e.charactersIgnoringModifiers == "=" { controller.zoom(horizontal: 1.4); return true }
        // ⌘Y = rehacer (por si otra app usa ⇧⌘Z como atajo global).
        if mods == .command, e.charactersIgnoringModifiers == "y", w.firstResponder as? NSText == nil { redo(); return true }
        guard mods.isEmpty, hasDocument else { return false }
        let shift = e.modifierFlags.contains(.shift)
        switch e.keyCode {
        case 49: togglePlay(); return true                          // espacio
        case 36, 76: toStart(); return true                          // Return / Enter
        case 48: shiftSelection(by: shift ? -1 : 1); return true     // Tab
        case 53:                                                      // Esc
            if isPreviewing { discardPreview() } else { deselectAll() }
            return true
        default: break
        }
        guard let ch = e.charactersIgnoringModifiers?.lowercased(), ch.count == 1 else { return false }
        if !shift, let t = Tool.allCases.first(where: { $0.key == ch }) ?? ["l": .select, "p": .draw][ch] { tool = t; return true }
        if let n = Int(ch), (1...9).contains(n) { assignSelection(toVoiceAt: n - 1); return true }
        return false
    }
}
