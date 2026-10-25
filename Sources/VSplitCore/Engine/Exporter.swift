import Foundation

public struct ExportOptions: Codable, Equatable, Sendable {
    public enum ChannelMode: String, Codable, CaseIterable, Sendable { case original, single, perVoice }
    public enum Unassigned: Codable, Equatable, Sendable { case discard, toVoice(VoiceID) }

    /// Copiar CC, sustain, pitch bend, aftertouch, program change y SysEx a cada voz.
    public var copyNonNoteEvents = true
    public var channelMode: ChannelMode = .original
    /// Canal 0-15 para `.single`.
    public var singleChannel = 0
    /// Recortar el silencio inicial (desplaza todo al compás de la primera nota). Por defecto se mantiene la posición absoluta.
    public var normalizeStart = false
    public var unassigned: Unassigned = .discard

    public init() {}
}

/// Genera los .mid de salida: formato 1, pista 0 = tempo map/compás originales, una pista por voz.
public enum Exporter {
    /// Nota con la voz final (aplica la opción de notas sin asignar).
    static func effectiveVoice(_ n: Note, _ o: ExportOptions) -> VoiceID? {
        if let v = n.voiceID { return v }
        if case .toVoice(let v) = o.unassigned { return v }
        return nil
    }

    static func channel(for voiceIndex: Int, original: UInt8, _ o: ExportOptions) -> UInt8 {
        switch o.channelMode {
        case .original: return original
        case .single: return UInt8(max(0, min(15, o.singleChannel)))
        case .perVoice: return UInt8(voiceIndex % 16)
        }
    }

    /// Desplazamiento aplicado a todo (0 salvo con `normalizeStart`): inicio del compás de la primera nota exportada.
    public static func startOffset(_ doc: SplitDocument, _ o: ExportOptions) -> Int {
        guard o.normalizeStart else { return 0 }
        guard let first = doc.notes.first(where: { effectiveVoice($0, o) != nil }) else { return 0 }
        return doc.tempoMap.barStartTick(containing: first.startTick)
    }

    /// Pista conductor: tempo, compás, armadura, offset SMPTE, marcadores… de todo el archivo.
    public static func conductorTrack(_ doc: SplitDocument, offset: Int, name: String?) -> MIDIWriter.Track {
        var events = doc.sequence.events.filter { $0.isConductorMeta }
        if let name { events.insert(.trackName(name), at: 0) }
        events = shift(events, by: offset, collapse: true)
        if !events.contains(where: { $0.tempoMicroseconds != nil }) { events.append(.tempo(500_000, at: 0)) }
        return MIDIWriter.Track(notes: [], events: events, endTick: max(0, doc.endTick - offset))
    }

    /// Eventos no-nota de las pistas cargadas (los meta de conductor y el nombre de pista van aparte).
    static func voiceEvents(_ doc: SplitDocument, voiceIndex: Int, offset: Int, _ o: ExportOptions) -> [MIDIEvent] {
        guard o.copyNonNoteEvents else { return [] }
        let loaded = Set(doc.loadedTracks)
        var out: [MIDIEvent] = []
        for e in doc.sequence.events where loaded.contains(e.track) {
            var e = e
            switch e.kind {
            case .meta(let t, _):
                if e.isConductorMeta || t == 0x03 || t == 0x20 { continue }  // 0x20 = channel prefix, deja de tener sentido
            case .channel(let s, let d1, let d2):
                let ch = channel(for: voiceIndex, original: s & 0x0F, o)
                e.kind = .channel(status: (s & 0xF0) | ch, data1: d1, data2: d2)
            case .sysex: break
            }
            out.append(e)
        }
        if o.channelMode != .original {
            // Varios canales colapsados en uno pueden duplicar el mismo CC en el mismo tick: quitar duplicados exactos.
            var seen = Set<MIDIEvent.Kind>()
            var lastTick = Int.min
            out = out.filter { e in
                if e.tick != lastTick { seen.removeAll(); lastTick = e.tick }
                guard e.isChannelEvent else { return true }
                return seen.insert(e.kind).inserted
            }
        }
        return shift(out, by: offset, collapse: true)
    }

    /// Mueve eventos `offset` ticks hacia atrás. Con `collapse`, los anteriores al nuevo cero se agrupan en el tick 0
    /// quedándose solo con el último valor de cada tipo (tempo, compás, CC n.º x…).
    static func shift(_ events: [MIDIEvent], by offset: Int, collapse: Bool) -> [MIDIEvent] {
        guard offset > 0 else { return events }
        var before: [String: MIDIEvent] = [:]
        var keepOrder: [String] = []
        var after: [MIDIEvent] = []
        for e in events {
            if e.tick >= offset { var e = e; e.tick -= offset; after.append(e); continue }
            guard collapse else { continue }
            let key: String
            switch e.kind {
            case .meta(let t, _): key = t == 0x06 || t == 0x07 ? "" : "m\(t)"   // marcadores anteriores se descartan
            case .channel(let s, let d1, _): key = (s & 0xF0) == 0xB0 ? "c\(s)-\(d1)" : "c\(s)"
            case .sysex: key = ""
            }
            guard !key.isEmpty else { continue }
            if before[key] == nil { keepOrder.append(key) }
            var e = e; e.tick = 0
            before[key] = e
        }
        return keepOrder.compactMap { before[$0] } + after
    }

    static func voiceNotes(_ doc: SplitDocument, voice: Voice, voiceIndex: Int, offset: Int, _ o: ExportOptions) -> [Note] {
        doc.notes.compactMap { n in
            guard effectiveVoice(n, o) == voice.id else { return nil }
            var n = n
            n.startTick -= offset
            if n.startTick < 0 { return nil }
            n.channel = channel(for: voiceIndex, original: n.channel, o)
            return n
        }
    }

    /// Un .mid formato 1 con la voz indicada.
    public static func voiceFile(_ doc: SplitDocument, voice: Voice, options o: ExportOptions) -> Data {
        let idx = doc.voiceIndex(voice.id) ?? 0
        let offset = startOffset(doc, o)
        let conductor = conductorTrack(doc, offset: offset, name: nil)
        let track = MIDIWriter.Track(notes: voiceNotes(doc, voice: voice, voiceIndex: idx, offset: offset, o),
                                     events: [.trackName(voice.name)] + voiceEvents(doc, voiceIndex: idx, offset: offset, o),
                                     endTick: conductor.endTick)
        return MIDIWriter.write(format: 1, ppq: doc.ppq, tracks: [conductor, track])
    }

    /// Un solo .mid con una pista por voz (más la pista conductor).
    public static func multitrackFile(_ doc: SplitDocument, options o: ExportOptions, title: String?) -> Data {
        let offset = startOffset(doc, o)
        let conductor = conductorTrack(doc, offset: offset, name: title)
        var tracks = [conductor]
        for (idx, v) in doc.voices.enumerated() {
            tracks.append(MIDIWriter.Track(notes: voiceNotes(doc, voice: v, voiceIndex: idx, offset: offset, o),
                                           events: [.trackName(v.name)] + voiceEvents(doc, voiceIndex: idx, offset: offset, o),
                                           endTick: conductor.endTick))
        }
        return MIDIWriter.write(format: 1, ppq: doc.ppq, tracks: tracks)
    }

    /// `<nombre-original>_<voz>.mid`, p. ej. `coros_Soprano.mid`.
    public static func filename(base: String, voice: Voice) -> String {
        "\(sanitize(base))_\(sanitize(voice.name)).mid"
    }

    public static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "voice" : String(cleaned.prefix(80))
    }

    /// Escribe una voz por archivo en `folder`. Devuelve las URLs creadas.
    @discardableResult
    public static func exportAll(_ doc: SplitDocument, base: String, to folder: URL, options o: ExportOptions, voices: [Voice]? = nil) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        var used = Set<String>()
        for v in voices ?? doc.voices {
            var name = filename(base: base, voice: v)
            var k = 2
            while used.contains(name.lowercased()) { name = filename(base: base, voice: v).replacingOccurrences(of: ".mid", with: "-\(k).mid"); k += 1 }
            used.insert(name.lowercased())
            let url = folder.appendingPathComponent(name)
            try voiceFile(doc, voice: v, options: o).write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }
}
