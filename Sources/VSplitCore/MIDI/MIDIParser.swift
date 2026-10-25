import Foundation

/// Lector de Standard MIDI File (formatos 0, 1 y 2; también RIFF/RMID). Nunca lanza por datos raros dentro
/// de una pista: los tolera y lo anota en `warnings`. Solo lanza si el archivo no es MIDI.
public enum MIDIParser {
    public static func parse(url: URL) throws -> MIDISequence {
        try parse(data: Data(contentsOf: url))
    }

    public static func parse(data input: Data) throws -> MIDISequence {
        var bytes = [UInt8](input)
        // RIFF MIDI (.rmi): el SMF va dentro del chunk "data".
        if bytes.count >= 12, bytes[0..<4].elementsEqual(Array("RIFF".utf8)), bytes[8..<12].elementsEqual(Array("RMID".utf8)) {
            var p = 12
            var found: [UInt8]?
            while p + 8 <= bytes.count {
                let len = Int(bytes[p + 4]) | Int(bytes[p + 5]) << 8 | Int(bytes[p + 6]) << 16 | Int(bytes[p + 7]) << 24
                if bytes[p..<p + 4].elementsEqual(Array("data".utf8)) { found = Array(bytes[(p + 8)..<min(bytes.count, p + 8 + len)]); break }
                p += 8 + len + (len & 1)
            }
            guard let inner = found else { throw MIDIError.notMIDI }
            bytes = inner
        }
        var r = Reader(bytes: bytes)
        guard r.remaining >= 14, r.readTag() == "MThd" else { throw MIDIError.notMIDI }
        guard let hlen = r.readUInt32(), hlen >= 6, let format = r.readUInt16(), let ntrks = r.readUInt16(), let division = r.readUInt16() else {
            throw MIDIError.invalidHeader
        }
        r.skip(Int(hlen) - 6)

        var warnings: [MIDIWarning] = []
        var ppq = Int(division)
        var smpteScale: Double? = nil
        if division & 0x8000 != 0 {
            let fpsCode = Int(Int8(bitPattern: UInt8(division >> 8)))
            let tpf = Int(division & 0xFF)
            let fps = -fpsCode == 29 ? 29.97 : Double(-fpsCode)
            // Ticks SMPTE por segundo → PPQ 960 a 120 BPM (una negra = 0,5 s).
            let ticksPerSecond = fps * Double(max(1, tpf))
            ppq = 960
            smpteScale = 960.0 / (ticksPerSecond * 0.5)
            warnings.append(.smpteDivisionConverted(fps: fps, ticksPerFrame: tpf))
        }
        guard ppq > 0 else { throw MIDIError.invalidHeader }
        if format == 2 { warnings.append(.format2) }

        var rawTracks: [RawTrack] = []
        var unknown = 0
        while r.remaining >= 8 {
            let tag = r.readTag()
            guard let len32 = r.readUInt32() else { break }
            var len = Int(len32)
            if tag != "MTrk" {
                // Basura al final o chunks propietarios: saltar.
                if tag.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) { unknown += 1; r.skip(len); continue }
                break
            }
            var truncated = false
            if len > r.remaining { len = r.remaining; truncated = true }
            let slice = Array(r.bytes[r.pos..<(r.pos + len)])
            r.skip(len)
            var track = parseTrack(slice, index: rawTracks.count)
            if truncated || track.truncated { warnings.append(.truncatedTrack(index: rawTracks.count)); track.truncated = true }
            rawTracks.append(track)
        }
        if unknown > 0 { warnings.append(.unknownChunks(count: unknown)) }
        guard !rawTracks.isEmpty else { throw MIDIError.noTracks }
        if rawTracks.count != Int(ntrks) { warnings.append(.trackCountMismatch(declared: Int(ntrks), found: rawTracks.count)) }
        let missingStatus = rawTracks.reduce(0) { $0 + $1.missingStatus }
        if missingStatus > 0 { warnings.append(.missingRunningStatus(count: missingStatus)) }

        if let scale = smpteScale {
            for i in rawTracks.indices {
                for j in rawTracks[i].events.indices { rawTracks[i].events[j].tick = Int((Double(rawTracks[i].events[j].tick) * scale).rounded()) }
                rawTracks[i].endTick = Int((Double(rawTracks[i].endTick) * scale).rounded())
                // En tiempo SMPTE el tempo no significa nada: se sustituye por 120 BPM fijo.
                rawTracks[i].events.removeAll { if case .other(.meta(0x51, _)) = $0.kind { return true }; return false }
            }
            rawTracks[0].events.insert(RawEvent(tick: 0, order: -1, kind: .meta(type: 0x51, data: [0x07, 0xA1, 0x20])), at: 0)
        }

        return build(format: Int(format), ppq: ppq, rawTracks: rawTracks, warnings: warnings)
    }

    // MARK: - Pistas

    struct RawEvent {
        enum Kind { case noteOn(ch: UInt8, pitch: UInt8, vel: UInt8), noteOff(ch: UInt8, pitch: UInt8, vel: UInt8), other(MIDIEvent.Kind) }
        var tick: Int
        var order: Int
        var kind: Kind
        init(tick: Int, order: Int, kind: MIDIEvent.Kind) { self.tick = tick; self.order = order; self.kind = .other(kind) }
        init(tick: Int, order: Int, note: Kind) { self.tick = tick; self.order = order; self.kind = note }
    }

    struct RawTrack {
        var events: [RawEvent] = []
        var endTick = 0
        var truncated = false
        var missingStatus = 0
    }

    static func parseTrack(_ bytes: [UInt8], index: Int) -> RawTrack {
        var r = Reader(bytes: bytes)
        var t = RawTrack()
        var tick = 0
        var running: UInt8? = nil
        var order = 0
        while r.remaining > 0 {
            guard let delta = r.readVLQ() else { t.truncated = true; break }
            tick += delta
            guard let b = r.readByte() else { t.truncated = true; break }
            if b == 0xFF {
                guard let type = r.readByte(), let len = r.readVLQ(), let data = r.read(len) else { t.truncated = true; break }
                if type == 0x2F { break }
                t.events.append(RawEvent(tick: tick, order: order, kind: .meta(type: type, data: data)))
            } else if b == 0xF0 || b == 0xF7 {
                guard let len = r.readVLQ(), let data = r.read(len) else { t.truncated = true; break }
                t.events.append(RawEvent(tick: tick, order: order, kind: .sysex(status: b, data: data)))
            } else if b >= 0xF1 {
                // Mensajes de sistema que no deberían estar en un SMF: saltar sus bytes de datos.
                let n = b == 0xF2 ? 2 : (b == 0xF1 || b == 0xF3) ? 1 : 0
                r.skip(n)
                continue
            } else {
                var status: UInt8
                var d1: UInt8
                if b & 0x80 != 0 {
                    status = b; running = b
                    guard let x = r.readByte() else { t.truncated = true; break }
                    d1 = x
                } else {
                    guard let rs = running else { t.missingStatus += 1; continue }
                    status = rs; d1 = b
                }
                let type = status & 0xF0, ch = status & 0x0F
                var d2: UInt8 = 0
                if type != 0xC0 && type != 0xD0 {
                    guard let x = r.readByte() else { t.truncated = true; break }
                    d2 = x
                }
                d1 &= 0x7F; d2 &= 0x7F
                switch type {
                case 0x90 where d2 > 0: t.events.append(RawEvent(tick: tick, order: order, note: .noteOn(ch: ch, pitch: d1, vel: d2)))
                case 0x90, 0x80: t.events.append(RawEvent(tick: tick, order: order, note: .noteOff(ch: ch, pitch: d1, vel: type == 0x80 ? d2 : 64)))
                default: t.events.append(RawEvent(tick: tick, order: order, kind: .channel(status: status, data1: d1, data2: d2)))
                }
            }
            order += 1
        }
        t.endTick = tick
        _ = index
        return t
    }

    static func build(format: Int, ppq: Int, rawTracks: [RawTrack], warnings inWarnings: [MIDIWarning]) -> MIDISequence {
        var warnings = inWarnings
        var notes: [Note] = []
        var events: [MIDIEvent] = []
        var infos: [MIDITrackInfo] = []
        var hanging = 0, orphans = 0

        for (ti, track) in rawTracks.enumerated() {
            struct Open { var start: Int; var vel: UInt8 }
            var open: [Int: [Open]] = [:]  // clave: canal*128 + pitch; FIFO
            var name: String?
            var noteCount = 0
            var channels = Set<UInt8>()
            let endTick = max(track.endTick, track.events.last?.tick ?? 0)
            for e in track.events {
                switch e.kind {
                case .noteOn(let ch, let p, let v):
                    open[Int(ch) * 128 + Int(p), default: []].append(Open(start: e.tick, vel: v))
                case .noteOff(let ch, let p, let v):
                    let key = Int(ch) * 128 + Int(p)
                    if var q = open[key], !q.isEmpty {
                        let o = q.removeFirst()  // NoteOff cierra el NoteOn abierto más antiguo
                        open[key] = q
                        notes.append(Note(id: 0, pitch: p, velocity: o.vel, releaseVelocity: v, startTick: o.start, durationTick: e.tick - o.start, channel: ch, track: ti))
                        noteCount += 1; channels.insert(ch)
                    } else {
                        orphans += 1
                    }
                case .other(let k):
                    if case .meta(0x03, let d) = k, name == nil { name = String(bytes: d, encoding: .utf8) ?? String(bytes: d, encoding: .isoLatin1) }
                    if case .channel(let s, _, _) = k { channels.insert(s & 0x0F) }
                    events.append(MIDIEvent(tick: e.tick, track: ti, order: e.order, kind: k))
                }
            }
            for (key, q) in open {
                for o in q {
                    hanging += 1
                    notes.append(Note(id: 0, pitch: UInt8(key % 128), velocity: o.vel, releaseVelocity: 64, startTick: o.start,
                                      durationTick: max(0, endTick - o.start), channel: UInt8(key / 128), track: ti))
                    noteCount += 1; channels.insert(UInt8(key / 128))
                }
            }
            infos.append(MIDITrackInfo(index: ti, name: name, endTick: endTick, noteCount: noteCount, channels: channels.sorted()))
        }
        if hanging > 0 { warnings.append(.hangingNotes(count: hanging)) }
        if orphans > 0 { warnings.append(.orphanNoteOffs(count: orphans)) }

        notes.sortCanonically()
        for i in notes.indices { notes[i].id = i }
        events.sort { a, b in
            if a.tick != b.tick { return a.tick < b.tick }
            if a.track != b.track { return a.track < b.track }
            return a.order < b.order
        }
        return MIDISequence(format: format, ppq: ppq, tracks: infos, notes: notes, events: events, warnings: warnings)
    }
}

struct Reader {
    let bytes: [UInt8]
    var pos = 0
    init(bytes: [UInt8]) { self.bytes = bytes }
    var remaining: Int { bytes.count - pos }

    mutating func readByte() -> UInt8? { guard pos < bytes.count else { return nil }; defer { pos += 1 }; return bytes[pos] }
    mutating func read(_ n: Int) -> [UInt8]? {
        guard n >= 0, n <= remaining else { return nil }
        defer { pos += n }
        return Array(bytes[pos..<(pos + n)])
    }
    mutating func skip(_ n: Int) { pos = min(bytes.count, pos + max(0, n)) }
    mutating func readTag() -> String { String(decoding: read(4) ?? [], as: UTF8.self) }
    mutating func readUInt16() -> UInt16? { guard let b = read(2) else { return nil }; return UInt16(b[0]) << 8 | UInt16(b[1]) }
    mutating func readUInt32() -> UInt32? {
        guard let b = read(4) else { return nil }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
    /// Cantidad de longitud variable (máx. 4 bytes, como manda el estándar).
    mutating func readVLQ() -> Int? {
        var value = 0
        for _ in 0..<4 {
            guard let b = readByte() else { return nil }
            value = value << 7 | Int(b & 0x7F)
            if b & 0x80 == 0 { return value }
        }
        return value
    }
}
