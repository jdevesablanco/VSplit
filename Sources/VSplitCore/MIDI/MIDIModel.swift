import Foundation

public typealias VoiceID = Int

/// Una nota emparejada (NoteOn + NoteOff). Posiciones absolutas en ticks desde el tick 0 del archivo.
public struct Note: Identifiable, Hashable, Codable, Sendable {
    public var id: Int
    public var pitch: UInt8
    public var velocity: UInt8
    public var releaseVelocity: UInt8
    public var startTick: Int
    public var durationTick: Int
    public var channel: UInt8
    /// Pista de origen en el archivo.
    public var track: Int
    public var voiceID: VoiceID?

    public init(id: Int, pitch: UInt8, velocity: UInt8, releaseVelocity: UInt8 = 64, startTick: Int, durationTick: Int,
                channel: UInt8 = 0, track: Int = 0, voiceID: VoiceID? = nil) {
        self.id = id; self.pitch = pitch; self.velocity = velocity; self.releaseVelocity = releaseVelocity
        self.startTick = startTick; self.durationTick = durationTick; self.channel = channel; self.track = track; self.voiceID = voiceID
    }

    public var endTick: Int { startTick + durationTick }
}

/// Cualquier evento que no es nota: CC, pitch bend, aftertouch, program change, meta-eventos, SysEx.
public struct MIDIEvent: Hashable, Codable, Sendable {
    public enum Kind: Hashable, Codable, Sendable {
        /// Mensaje de canal (status incluye el canal). Para mensajes de 1 byte de datos (Cn, Dn) `data2` se ignora.
        case channel(status: UInt8, data1: UInt8, data2: UInt8)
        case meta(type: UInt8, data: [UInt8])
        /// `status` es F0 o F7; `data` es el contenido tal cual tras la longitud.
        case sysex(status: UInt8, data: [UInt8])
    }

    public var tick: Int
    public var track: Int
    /// Orden original dentro de la pista, para conservar el orden de eventos en el mismo tick.
    public var order: Int
    public var kind: Kind

    public init(tick: Int, track: Int = 0, order: Int = 0, kind: Kind) {
        self.tick = tick; self.track = track; self.order = order; self.kind = kind
    }

    public var metaType: UInt8? { if case .meta(let t, _) = kind { return t }; return nil }
    public var isChannelEvent: Bool { if case .channel = kind { return true }; return false }
    public var channel: UInt8? { if case .channel(let s, _, _) = kind { return s & 0x0F }; return nil }

    /// Meta-eventos de "conductor": tempo map, compás, armadura, offset SMPTE, marcadores, copyright, cue.
    public var isConductorMeta: Bool {
        guard let t = metaType else { return false }
        return [0x51, 0x58, 0x59, 0x54, 0x06, 0x07, 0x02].contains(t)
    }

    public var tempoMicroseconds: Int? {
        guard case .meta(0x51, let d) = kind, d.count >= 3 else { return nil }
        return Int(d[0]) << 16 | Int(d[1]) << 8 | Int(d[2])
    }

    public var timeSignature: (numerator: Int, denominator: Int)? {
        guard case .meta(0x58, let d) = kind, d.count >= 2 else { return nil }
        return (max(1, Int(d[0])), 1 << min(Int(d[1]), 6))
    }

    public var keySignature: (sharps: Int, minor: Bool)? {
        guard case .meta(0x59, let d) = kind, d.count >= 2 else { return nil }
        return (Int(Int8(bitPattern: d[0])), d[1] != 0)
    }

    public var text: String? {
        guard case .meta(let t, let d) = kind, (0x01...0x0F).contains(t) else { return nil }
        return String(bytes: d, encoding: .utf8) ?? String(bytes: d, encoding: .isoLatin1)
    }

    public static func tempo(_ us: Int, at tick: Int, track: Int = 0) -> MIDIEvent {
        MIDIEvent(tick: tick, track: track, kind: .meta(type: 0x51, data: [UInt8((us >> 16) & 0xFF), UInt8((us >> 8) & 0xFF), UInt8(us & 0xFF)]))
    }

    public static func timeSignature(_ num: Int, _ den: Int, at tick: Int, track: Int = 0) -> MIDIEvent {
        let pow = max(0, Int(log2(Double(den)).rounded()))
        return MIDIEvent(tick: tick, track: track, kind: .meta(type: 0x58, data: [UInt8(num), UInt8(pow), 24, 8]))
    }

    public static func trackName(_ name: String, track: Int = 0) -> MIDIEvent {
        MIDIEvent(tick: 0, track: track, kind: .meta(type: 0x03, data: Array(name.utf8)))
    }
}

public struct MIDITrackInfo: Hashable, Codable, Sendable {
    public var index: Int
    public var name: String?
    public var endTick: Int
    public var noteCount: Int
    public var channels: [UInt8]
}

public enum MIDIWarning: Hashable, Sendable {
    case smpteDivisionConverted(fps: Double, ticksPerFrame: Int)
    case hangingNotes(count: Int)
    case orphanNoteOffs(count: Int)
    case truncatedTrack(index: Int)
    case unknownChunks(count: Int)
    case missingRunningStatus(count: Int)
    case trackCountMismatch(declared: Int, found: Int)
    case format2

    public var message: String {
        switch self {
        case .smpteDivisionConverted(let fps, let tpf):
            return String(format: String(localized: "The file uses SMPTE time (%.2f fps, %d ticks/frame). It was converted to 960 PPQ at 120 BPM."), fps, tpf)
        case .hangingNotes(let n):
            return String(format: String(localized: "%d notes had no Note Off and were closed at the end of the clip."), n)
        case .orphanNoteOffs(let n):
            return String(format: String(localized: "%d Note Off events without a matching Note On were ignored."), n)
        case .truncatedTrack(let i):
            return String(format: String(localized: "Track %d is truncated; the readable part was loaded."), i + 1)
        case .unknownChunks(let n):
            return String(format: String(localized: "%d unknown chunks were skipped."), n)
        case .missingRunningStatus(let n):
            return String(format: String(localized: "%d data bytes without status were skipped."), n)
        case .trackCountMismatch(let d, let f):
            return String(format: String(localized: "The header declares %d tracks but %d were found."), d, f)
        case .format2:
            return String(localized: "Format 2 file (independent sequences): tracks are treated as simultaneous.")
        }
    }
}

public enum MIDIError: LocalizedError, Equatable {
    case notMIDI
    case invalidHeader
    case noTracks
    case empty

    public var errorDescription: String? {
        switch self {
        case .notMIDI: return String(localized: "This file is not a Standard MIDI File.")
        case .invalidHeader: return String(localized: "The MIDI header is corrupt.")
        case .noTracks: return String(localized: "The MIDI file has no readable tracks.")
        case .empty: return String(localized: "The MIDI file contains no notes.")
        }
    }
}

/// Contenido completo de un Standard MIDI File, con las notas ya emparejadas.
public struct MIDISequence: Sendable {
    public var format: Int
    public var ppq: Int
    public var tracks: [MIDITrackInfo]
    /// Ordenadas por (startTick, pitch, track). `id` = índice en este array.
    public var notes: [Note]
    /// Eventos no-nota, ordenados por (tick, track, order).
    public var events: [MIDIEvent]
    public var warnings: [MIDIWarning]

    public init(format: Int = 1, ppq: Int = 480, tracks: [MIDITrackInfo] = [], notes: [Note] = [], events: [MIDIEvent] = [], warnings: [MIDIWarning] = []) {
        self.format = format; self.ppq = ppq; self.tracks = tracks; self.notes = notes; self.events = events; self.warnings = warnings
    }

    public var tempoMap: TempoMap { TempoMap(ppq: ppq, events: events) }
    public var endTick: Int { max(tracks.map(\.endTick).max() ?? 0, notes.map(\.endTick).max() ?? 0, events.last?.tick ?? 0) }
    public var tracksWithNotes: [MIDITrackInfo] { tracks.filter { $0.noteCount > 0 } }
}

extension Array where Element == Note {
    /// Orden canónico de notas: por inicio, luego altura, luego pista/canal.
    public mutating func sortCanonically() {
        sort { a, b in
            if a.startTick != b.startTick { return a.startTick < b.startTick }
            if a.pitch != b.pitch { return a.pitch < b.pitch }
            if a.track != b.track { return a.track < b.track }
            return a.channel < b.channel
        }
    }
}

public enum NoteNames {
    static let sharps = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    /// `middleCOctave` = octava que se muestra para la nota 60 (Logic: 3, General MIDI/Yamaha: 4).
    public static func name(_ pitch: Int, middleCOctave: Int = 3) -> String {
        let octave = pitch / 12 - (5 - middleCOctave)
        return sharps[((pitch % 12) + 12) % 12] + String(octave)
    }
    public static func isBlack(_ pitch: Int) -> Bool { [1, 3, 6, 8, 10].contains(((pitch % 12) + 12) % 12) }

    public static func keyName(sharps: Int, minor: Bool) -> String {
        let majors = ["Cb", "Gb", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#"]
        let minors = ["Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#", "G#", "D#", "A#"]
        let i = Swift.max(0, Swift.min(14, sharps + 7))
        return minor ? minors[i] + "m" : majors[i]
    }
}
