import Foundation

/// Escritor de Standard MIDI File. Las notas se convierten en NoteOn/NoteOff (0x80 con su velocity de release).
/// Orden dentro de un mismo tick: nombre de pista, meta-eventos, NoteOff, CC/PB/SysEx, NoteOn y por último los
/// NoteOff de notas de duración 0, para que al releer se emparejen igual.
public enum MIDIWriter {
    public struct Track {
        public var notes: [Note]
        public var events: [MIDIEvent]
        /// Tick mínimo para el End of Track (conserva la longitud original del clip).
        public var endTick: Int
        public init(notes: [Note] = [], events: [MIDIEvent] = [], endTick: Int = 0) { self.notes = notes; self.events = events; self.endTick = endTick }
    }

    public static func write(format: Int, ppq: Int, tracks: [Track]) -> Data {
        var out: [UInt8] = Array("MThd".utf8)
        out += be32(6) + be16(format) + be16(tracks.count) + be16(max(1, min(0x7FFF, ppq)))
        for t in tracks {
            let body = encodeTrack(t)
            out += Array("MTrk".utf8) + be32(body.count) + body
        }
        return Data(out)
    }

    /// Reescribe una secuencia conservando su estructura de pistas (para round-trip).
    public static func write(_ seq: MIDISequence) -> Data {
        var tracks = seq.tracks.map { Track(notes: [], events: [], endTick: $0.endTick) }
        if tracks.isEmpty { tracks = [Track()] }
        for n in seq.notes { tracks[min(max(0, n.track), tracks.count - 1)].notes.append(n) }
        for e in seq.events { tracks[min(max(0, e.track), tracks.count - 1)].events.append(e) }
        return write(format: tracks.count == 1 ? seq.format : max(1, seq.format), ppq: seq.ppq, tracks: tracks)
    }

    private struct Timed { var tick: Int; var priority: Int; var order: Int; var bytes: [UInt8] }

    static func encodeTrack(_ t: Track) -> [UInt8] {
        var items: [Timed] = []
        items.reserveCapacity(t.notes.count * 2 + t.events.count)
        for e in t.events {
            switch e.kind {
            case .meta(let type, let data):
                if type == 0x2F { continue }
                items.append(Timed(tick: e.tick, priority: type == 0x03 ? -1 : 0, order: e.order, bytes: [0xFF, type] + vlq(data.count) + data))
            case .sysex(let status, let data):
                items.append(Timed(tick: e.tick, priority: 2, order: e.order, bytes: [status] + vlq(data.count) + data))
            case .channel(let status, let d1, let d2):
                let type = status & 0xF0
                let b: [UInt8] = (type == 0xC0 || type == 0xD0) ? [status, d1 & 0x7F] : [status, d1 & 0x7F, d2 & 0x7F]
                items.append(Timed(tick: e.tick, priority: 2, order: e.order, bytes: b))
            }
        }
        for n in t.notes {
            let ch = n.channel & 0x0F
            items.append(Timed(tick: n.startTick, priority: 3, order: Int(n.pitch), bytes: [0x90 | ch, n.pitch & 0x7F, max(1, n.velocity & 0x7F)]))
            items.append(Timed(tick: n.endTick, priority: n.durationTick == 0 ? 4 : 1, order: Int(n.pitch), bytes: [0x80 | ch, n.pitch & 0x7F, n.releaseVelocity & 0x7F]))
        }
        items.sort { a, b in
            if a.tick != b.tick { return a.tick < b.tick }
            if a.priority != b.priority { return a.priority < b.priority }
            return a.order < b.order
        }
        var out: [UInt8] = []
        out.reserveCapacity(items.count * 4 + 8)
        var last = 0
        for it in items {
            let tick = max(0, it.tick)
            out += vlq(tick - last)
            out += it.bytes
            last = tick
        }
        let end = max(last, t.endTick)
        out += vlq(end - last) + [0xFF, 0x2F, 0x00]
        return out
    }

    static func vlq(_ value: Int) -> [UInt8] {
        var v = max(0, min(value, 0x0FFF_FFFF))
        var bytes: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 { bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
        return bytes
    }
    static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
}
