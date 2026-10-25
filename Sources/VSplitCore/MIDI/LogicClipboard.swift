import Foundation

/// Lee el texto que Logic Pro deja en el portapapeles al copiar notas en el Piano Roll / Event List (⌘A, ⌘C):
///
///     \t  \t 1 1 1 13 \t Note\t 1\t C3\t 83\t 0 3 3 108\t
///     \t\t\t Rel Vel\t\t\t 64\t\t
///
/// Posición = compás, pulso, división, tick (1-based); duración = compases, pulsos, divisiones, ticks.
/// Logic trabaja a 960 ticks por negra. El texto no trae ni el tempo ni el compás: se asumen (4/4, 120 BPM)
/// y se pueden cambiar. Copiar la *región* (no sus notas) solo deja un resumen sin notas.
public enum LogicClipboard {
    public static let ppq = 960

    public struct Options: Equatable, Sendable {
        /// nil = deducir (4, o más si aparecen pulsos mayores).
        public var numerator: Int?
        public var denominator = 4
        public var bpm = 120.0
        /// Octava con la que Logic nombra la nota 60 (por defecto C3).
        public var middleCOctave = 3
        public init(numerator: Int? = nil, denominator: Int = 4, bpm: Double = 120, middleCOctave: Int = 3) {
            self.numerator = numerator; self.denominator = denominator; self.bpm = bpm; self.middleCOctave = middleCOctave
        }
    }

    public enum Content: Equatable { case notes, regionSummary, other }

    struct Row {
        var position: [Int]
        var status: String
        var fields: [String]   // canal, num/nota, valor, duración/info
    }

    /// Filas de evento (con posición de 4 números) y la velocity de release que va en la línea siguiente.
    static func rows(_ text: String) -> [(Row, Int?)] {
        var out: [(Row, Int?)] = []
        for raw in text.components(separatedBy: CharacterSet.newlines) {
            let cols = raw.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !cols.isEmpty else { continue }
            if cols[0].lowercased().hasPrefix("rel vel"), let v = cols.dropFirst().first.flatMap({ Int($0) }), !out.isEmpty {
                out[out.count - 1].1 = v
                continue
            }
            guard let pos = ints(cols[0]), pos.count == 4, cols.count >= 2 else { continue }
            out.append((Row(position: pos, status: cols[1], fields: Array(cols.dropFirst(2))), nil))
        }
        return out
    }

    static func ints(_ s: String) -> [Int]? {
        let parts = s.split(whereSeparator: { $0 == " " })
        let v = parts.compactMap { Int($0) }
        return v.count == parts.count && !v.isEmpty ? v : nil
    }

    public static func classify(_ text: String) -> Content {
        let r = rows(text)
        if r.contains(where: { $0.0.status.lowercased() == "note" }) { return .notes }
        return r.isEmpty ? .other : .regionSummary
    }

    /// "C3", "C#3", "Db-1", "F♯2" → número MIDI.
    public static func pitch(_ name: String, middleCOctave: Int = 3) -> Int? {
        var s = Substring(name.trimmingCharacters(in: .whitespaces))
        guard let letter = s.first?.uppercased(), let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][letter] else { return Int(name) }
        s = s.dropFirst()
        var acc = 0
        while let c = s.first, "#♯b♭".contains(c) { acc += (c == "#" || c == "♯") ? 1 : -1; s = s.dropFirst() }
        guard let octave = Int(s) else { return nil }
        let p = (octave + 5 - middleCOctave) * 12 + base + acc
        return (0...127).contains(p) ? p : nil
    }

    /// Ticks por división: Logic usa 1/16 por defecto, pero se ajusta a lo que aparezca en el texto.
    static func divisionTicks(_ rows: [Row], beatTicks: Int) -> Int {
        let lengths = rows.compactMap { $0.status.lowercased() == "note" ? $0.fields.last.flatMap(ints) : nil }.filter { $0.count == 4 }
        for cand in [240, 120, 480, 60, 960] where beatTicks % cand == 0 {
            let divs = beatTicks / cand
            let posOK = rows.allSatisfy { $0.position[3] <= cand && $0.position[2] <= divs }
            let lenOK = lengths.allSatisfy { $0[3] < cand && $0[2] < divs }
            if posOK && lenOK { return cand }
        }
        return 240
    }

    /// Quita el espacio vacío de delante: el compás de la primera nota pasa a ser el compás 1.
    /// Devuelve la secuencia desplazada y el compás de Logic (1-based) donde empezaba.
    public static func trimmed(_ seq: MIDISequence) -> (sequence: MIDISequence, originBar: Int) {
        guard let first = seq.notes.map(\.startTick).min() else { return (seq, 1) }
        let map = seq.tempoMap
        let offset = map.barStartTick(containing: first)
        let bar = map.position(atTick: first).bar + 1
        guard offset > 0 else { return (seq, bar) }
        var s = seq
        s.notes = seq.notes.map { var n = $0; n.startTick -= offset; return n }
        s.events = seq.events.map { e in
            // Tempo y compás iniciales se quedan en 0; el resto se desplaza (lo anterior al inicio se descarta).
            var e = e
            if e.tick == 0 && (e.tempoMicroseconds != nil || e.timeSignature != nil) { return e }
            e.tick -= offset
            return e
        }.filter { $0.tick >= 0 }
        s.tracks = seq.tracks.map { var t = $0; t.endTick = max(0, t.endTick - offset); return t }
        return (s, bar)
    }

    public static func parse(_ text: String, options o: Options = Options()) throws -> MIDISequence {
        let all = rows(text)
        guard all.contains(where: { $0.0.status.lowercased() == "note" }) else { throw MIDIError.empty }
        let den = [1, 2, 4, 8, 16].contains(o.denominator) ? o.denominator : 4
        let beatTicks = ppq * 4 / den
        let maxBeat = all.map { $0.0.position[1] }.max() ?? 4
        let num = max(1, o.numerator ?? max(4, maxBeat))
        let barTicks = num * beatTicks
        let divTicks = divisionTicks(all.map(\.0), beatTicks: beatTicks)

        func tick(_ p: [Int]) -> Int { (p[0] - 1) * barTicks + (p[1] - 1) * beatTicks + (p[2] - 1) * divTicks + (p[3] - 1) }
        func length(_ l: [Int]) -> Int { l[0] * barTicks + l[1] * beatTicks + l[2] * divTicks + l[3] }

        var notes: [Note] = []
        var events: [MIDIEvent] = [.tempo(Int((60_000_000 / max(10, o.bpm)).rounded()), at: 0), .timeSignature(num, den, at: 0)]
        var channels = Set<UInt8>()
        for (k, (row, rel)) in all.enumerated() {
            let t = max(0, tick(row.position))
            let ch = UInt8(max(1, min(16, row.fields.first.flatMap { Int($0) } ?? 1)) - 1)
            let f = row.fields
            switch row.status.lowercased() {
            case "note":
                guard f.count >= 4, let p = pitch(f[1], middleCOctave: o.middleCOctave), let v = Int(f[2]), let l = ints(f[3]), l.count == 4 else { continue }
                notes.append(Note(id: 0, pitch: UInt8(p), velocity: UInt8(max(1, min(127, v))), releaseVelocity: UInt8(max(0, min(127, rel ?? 64))),
                                  startTick: t, durationTick: max(1, length(l)), channel: ch, track: 1))
                channels.insert(ch)
            case let s where s.hasPrefix("control"):
                guard f.count >= 3, let n = Int(f[1]), let v = Int(f[2]) else { continue }
                events.append(MIDIEvent(tick: t, track: 1, order: k, kind: .channel(status: 0xB0 | ch, data1: UInt8(max(0, min(127, n))), data2: UInt8(max(0, min(127, v))))))
            case let s where s.hasPrefix("pitch"):
                guard f.count >= 3, let lsb = Int(f[1]), let msb = Int(f[2]) else { continue }
                events.append(MIDIEvent(tick: t, track: 1, order: k, kind: .channel(status: 0xE0 | ch, data1: UInt8(max(0, min(127, lsb))), data2: UInt8(max(0, min(127, msb))))))
            case let s where s.hasPrefix("c-press"):
                guard f.count >= 2, let v = Int(f.count >= 3 ? f[2] : f[1]) else { continue }
                events.append(MIDIEvent(tick: t, track: 1, order: k, kind: .channel(status: 0xD0 | ch, data1: UInt8(max(0, min(127, v))), data2: 0)))
            default:
                continue
            }
        }
        notes.sortCanonically()
        for i in notes.indices { notes[i].id = i }
        events.sort { $0.tick != $1.tick ? $0.tick < $1.tick : $0.order < $1.order }
        let end = max(notes.map(\.endTick).max() ?? 0, events.last?.tick ?? 0)
        let tracks = [MIDITrackInfo(index: 0, name: nil, endTick: end, noteCount: 0, channels: []),
                      MIDITrackInfo(index: 1, name: "Logic", endTick: end, noteCount: notes.count, channels: channels.sorted())]
        return MIDISequence(format: 1, ppq: ppq, tracks: tracks, notes: notes, events: events, warnings: [])
    }
}
