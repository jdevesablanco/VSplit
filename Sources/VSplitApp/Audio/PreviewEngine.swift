import AVFoundation
import VSplitCore

/// Sonidos de metrónomo. "Klopfgeist" imita el clic por defecto de Logic (sintetizado aquí); el resto usa la
/// percusión General MIDI del sistema.
enum MetronomeSound: String, CaseIterable, Identifiable {
    case klopfgeist, beep, woodblock, rimshot, hihat, cowbell
    var id: String { rawValue }
    var title: String {
        switch self {
        case .klopfgeist: return String(localized: "Klopfgeist (Logic)")
        case .beep: return String(localized: "Beep")
        case .woodblock: return String(localized: "Woodblock")
        case .rimshot: return String(localized: "Rimshot")
        case .hihat: return String(localized: "Hi-Hat")
        case .cowbell: return String(localized: "Cowbell")
        }
    }
    var synthesized: Bool { self == .klopfgeist || self == .beep }
    /// Nota para el primer pulso del compás y para el resto.
    var notes: (bar: UInt8, beat: UInt8) {
        switch self {
        case .klopfgeist, .beep: return (72, 60)      // muestra con raíz en 60: el acento suena una octava arriba
        case .woodblock: return (76, 77)
        case .rimshot: return (37, 37)
        case .hihat: return (46, 42)
        case .cowbell: return (56, 56)
        }
    }
}

/// Preview con AVAudioEngine: un AVAudioUnitSampler por voz (con su pan, mute y solo), otro para las notas sin asignar
/// y otro para el metrónomo. La secuencia se genera con el mismo writer MIDI que la exportación y la reproduce
/// AVAudioSequencer (respeta el tempo map). Si algo falla, la app sigue sin audio.
@MainActor
final class PreviewEngine {
    static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("VSplit", isDirectory: true)
    }()

    static let soundBank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

    private let engine = AVAudioEngine()
    private var samplers: [Int: AVAudioUnitSampler] = [:]   // clave: VoiceID; -1 = sin asignar; -2/-4 = metrónomo (acento/pulso); -3 = teclado
    private static let clickKeys = [-2, -4]
    private var sequencer: AVAudioSequencer?
    private var trackKeys: [Int] = []
    private var ppq = 480
    private var loadedRevision = -1
    private var program = 0
    private var metronomeOn = false
    private var metronomeSound: MetronomeSound = .klopfgeist
    private var metronomeVolume: Float = 0.7
    private var metronomeAccent = true
    private var rate: Double = 1
    private(set) var lastError: String?
    private var reloadWork: DispatchWorkItem?

    init() {
        try? FileManager.default.removeItem(at: Self.cacheDir.appendingPathComponent("Drag"))
        try? FileManager.default.removeItem(at: Self.cacheDir.appendingPathComponent("Incoming"))
    }

    private func sampler(_ key: Int) -> AVAudioUnitSampler {
        if let s = samplers[key] { return s }
        let s = AVAudioUnitSampler()
        engine.attach(s)
        engine.connect(s, to: engine.mainMixerNode, format: nil)
        loadInstrument(s, key: key)
        samplers[key] = s
        return s
    }

    private func loadInstrument(_ s: AVAudioUnitSampler, key: Int) {
        guard Self.clickKeys.contains(key) || FileManager.default.fileExists(atPath: Self.soundBank.path) else { return }  // sin DLS: onda por defecto
        do {
            if Self.clickKeys.contains(key) {
                if metronomeSound.synthesized {
                    try s.loadAudioFiles(at: [Self.clickSample(metronomeSound, accent: key == -2)])
                } else {
                    try s.loadSoundBankInstrument(at: Self.soundBank, program: 0, bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))
                }
            } else {
                try s.loadSoundBankInstrument(at: Self.soundBank, program: UInt8(program), bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func startEngine() -> Bool {
        if engine.isRunning { return true }
        _ = sampler(-3)
        do { try engine.start(); return true } catch { lastError = error.localizedDescription; return false }
    }

    func setInstrument(_ p: Int) {
        program = p
        for (k, s) in samplers where !Self.clickKeys.contains(k) { loadInstrument(s, key: k) }
        if ProcessInfo.processInfo.environment["VSPLIT_AUDIODEBUG"] != nil { print("audio: instrument \(p) on \(samplers.count - 1) samplers") }
    }

    func setMetronome(_ on: Bool) {
        metronomeOn = on
        for k in Self.clickKeys { samplers[k]?.volume = on ? metronomeVolume : 0 }
    }

    func setMetronomeSound(_ sound: MetronomeSound, volume: Double, accent: Bool) {
        let changed = sound != metronomeSound || accent != metronomeAccent
        metronomeSound = sound
        metronomeVolume = Float(volume)
        metronomeAccent = accent
        for k in Self.clickKeys {
            if let s = samplers[k], changed { loadInstrument(s, key: k) }
            samplers[k]?.volume = metronomeOn ? metronomeVolume : 0
        }
        if changed { invalidate() }
    }

    /// Clic sintetizado (se genera una vez): Klopfgeist = golpe corto con tono y un poco de ruido; Beep = seno puro.
    static func clickSample(_ sound: MetronomeSound, accent: Bool) -> URL {
        let url = cacheDir.appendingPathComponent("Click-\(sound.rawValue)\(accent ? "-accent" : "").caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let sr = 44100.0
        let frames = Int(sr * 0.09)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let d = buf.floatChannelData![0]
        // Frecuencia con la raíz en la nota 60: el sampler la transpone para el acento.
        // Acento: más agudo (como el primer pulso del clic de Logic).
        let f = (sound == .beep ? 1046.5 : 1318.5) * (accent ? 1.5 : 1)
        var noise: UInt32 = 12345
        for i in 0..<frames {
            let t = Double(i) / sr
            var v: Double
            if sound == .beep {
                v = sin(2 * .pi * f * t) * exp(-t * 35) * 0.8
            } else {
                noise = noise &* 1664525 &+ 1013904223
                let n = Double(Int32(bitPattern: noise)) / Double(Int32.max)
                v = (sin(2 * .pi * f * t) * 0.75 + sin(2 * .pi * f * 2.01 * t) * 0.18) * exp(-t * 60) + n * 0.35 * exp(-t * 900)
            }
            let attack = min(1, t / 0.0008)
            d[i] = Float(v * attack)
        }
        if let file = try? AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false) {
            try? file.write(from: buf)
        }
        return url
    }

    func setRate(_ r: Double) {
        rate = r
        sequencer?.rate = Float(r)
    }

    /// Marca la secuencia como obsoleta (se regenera al darle a play).
    func invalidate() { loadedRevision = -1 }

    // MARK: Secuencia

    private func build(_ d: SplitDocument) -> (Data, [Int]) {
        var o = ExportOptions(); o.copyNonNoteEvents = true
        let conductor = Exporter.conductorTrack(d, offset: 0, name: nil)
        var tracks = [conductor]
        var keys: [Int] = []
        // CC/pitch bend sí; program change y SysEx no (cambiarían el instrumento del sampler).
        let shared = d.sequence.events.filter { e in
            guard d.loadedTracks.contains(e.track), case .channel(let s, _, _) = e.kind else { return false }
            return s & 0xF0 != 0xC0
        }
        var groups: [Int: [Note]] = [:]
        for n in d.notes { groups[n.voiceID ?? -1, default: []].append(n) }
        // Solo pistas con notas: AVAudioSequencer descarta las vacías y desplazaría el enrutado.
        for key in d.voices.map(\.id) + [-1] {
            guard let notes = groups[key], !notes.isEmpty else { continue }
            tracks.append(MIDIWriter.Track(notes: notes, events: shared, endTick: conductor.endTick))
            keys.append(key)
        }
        // Metrónomo: un clic por pulso; el primero del compás, acentuado (otra pista y otro sampler, canal 10).
        var clicks: [Note] = [], accents: [Note] = []
        let notes = metronomeSound.notes
        for bar in d.tempoMap.bars(from: 0, to: d.endTick + d.ppq) {
            var t = bar.startTick, k = 0
            while t < bar.startTick + bar.length {
                let accent = k == 0 && metronomeAccent
                let n = Note(id: 0, pitch: accent ? notes.bar : notes.beat, velocity: accent ? 127 : 100, startTick: t, durationTick: max(1, d.ppq / 8), channel: 9)
                if accent { accents.append(n) } else { clicks.append(n) }
                t += bar.beatLength; k += 1
            }
        }
        if !accents.isEmpty { tracks.append(MIDIWriter.Track(notes: accents, endTick: conductor.endTick)); keys.append(-2) }
        if !clicks.isEmpty { tracks.append(MIDIWriter.Track(notes: clicks, endTick: conductor.endTick)); keys.append(-4) }
        return (MIDIWriter.write(format: 1, ppq: d.ppq, tracks: tracks), keys)
    }

    private func prepare(_ model: AppModel) -> Bool {
        guard let d = model.doc else { return false }
        guard startEngine() else { return false }
        if loadedRevision == model.revision, sequencer != nil { applyMixer(voices: d.voices); return true }
        let (data, keys) = build(d)
        let seq = AVAudioSequencer(audioEngine: engine)
        do { try seq.load(from: data, options: []) } catch { lastError = error.localizedDescription; return false }
        // La pista conductor se convierte en tempoTrack; si llegara como pista normal, se salta.
        let offset = seq.tracks.count == keys.count + 1 ? 1 : 0
        if seq.tracks.count - offset != keys.count { lastError = "track routing mismatch (\(seq.tracks.count) vs \(keys.count))" }
        if ProcessInfo.processInfo.environment["VSPLIT_AUDIODEBUG"] != nil {
            print("audio: sequencer tracks \(seq.tracks.count), keys \(keys.count) \(keys), offset \(offset)")
            for (i, t) in seq.tracks.enumerated() { print("  track \(i): length \(t.lengthInBeats) beats") }
        }
        for (k, key) in keys.enumerated() where k + offset < seq.tracks.count {
            seq.tracks[k + offset].destinationAudioUnit = sampler(key)
        }
        sequencer?.stop()
        sequencer = seq
        trackKeys = keys
        ppq = d.ppq
        loadedRevision = model.revision
        seq.rate = Float(rate)
        seq.prepareToPlay()
        applyMixer(voices: d.voices)
        return true
    }

    // MARK: Transporte

    func play(model: AppModel, fromTick tick: Int) -> Bool {
        rate = model.rate
        guard prepare(model), let seq = sequencer else { return false }
        allNotesOff()
        seq.currentPositionInBeats = Double(tick) / Double(ppq)
        do { try seq.start(); return true } catch { lastError = error.localizedDescription; return false }
    }

    func stop() {
        sequencer?.stop()
        allNotesOff()
    }

    func seek(toTick tick: Int) {
        guard let seq = sequencer else { return }
        allNotesOff()
        seq.currentPositionInBeats = Double(tick) / Double(ppq)
    }

    var currentTick: Int { Int(((sequencer?.currentPositionInBeats ?? 0) * Double(ppq)).rounded()) }

    /// Tras editar durante la reproducción: regenerar y seguir desde el mismo punto (con un pequeño retardo para agrupar cambios).
    func reloadWhilePlaying(model: AppModel) {
        reloadWork?.cancel()
        let w = DispatchWorkItem { [weak self, weak model] in
            MainActor.assumeIsolated {
                guard let self, let model, model.isPlaying else { return }
                let t = self.currentTick
                self.sequencer?.stop()
                _ = self.play(model: model, fromTick: t)
            }
        }
        reloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    func applyMixer(voices: [Voice]) {
        let anySolo = voices.contains(where: \.isSolo)
        for v in voices {
            guard let s = samplers[v.id] else { continue }
            s.pan = Float(v.pan) / 100
            s.volume = v.isMuted || (anySolo && !v.isSolo) ? 0 : 1
        }
        samplers[-1]?.volume = anySolo ? 0 : 0.8
        for k in Self.clickKeys { samplers[k]?.volume = metronomeOn ? metronomeVolume : 0 }
    }

    private func allNotesOff() {
        for s in samplers.values {
            for ch: UInt8 in 0..<16 {
                s.sendController(64, withValue: 0, onChannel: ch)
                s.sendController(123, withValue: 0, onChannel: ch)
            }
        }
    }

    /// Clic en el teclado del piano roll.
    func playPreviewNote(_ pitch: Int) {
        guard startEngine() else { return }
        let s = sampler(-3)
        let p = UInt8(max(0, min(127, pitch)))
        s.startNote(p, withVelocity: 96, onChannel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { s.stopNote(p, onChannel: 0) }
    }
}
