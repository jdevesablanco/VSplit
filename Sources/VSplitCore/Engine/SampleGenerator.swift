import Foundation

/// Genera MIDIs de prueba (los usan los tests y `vsplit samples`).
public enum SampleGenerator {
    public struct RNG {
        var state: UInt64
        public init(seed: UInt64) { state = seed }
        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        public mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53) }
        public mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
    }

    /// Construye un archivo formato 1: pista 0 conductor (tempo/compás), pistas 1… con notas.
    public struct Builder {
        public var ppq: Int
        public var conductor: [MIDIEvent] = []
        public var tracks: [MIDIWriter.Track] = []
        public init(ppq: Int = 480, bpm: Double = 120, numerator: Int = 4, denominator: Int = 4) {
            self.ppq = ppq
            conductor = [.tempo(Int(60_000_000 / bpm), at: 0), .timeSignature(numerator, denominator, at: 0)]
        }
        public var tempoMap: TempoMap { TempoMap(ppq: ppq, events: conductor) }

        public mutating func addTrack(name: String) -> Int { tracks.append(MIDIWriter.Track(events: [.trackName(name)])); return tracks.count - 1 }
        public mutating func note(_ track: Int, pitch: Int, tick: Int, duration: Int, velocity: Int = 90, channel: Int = 0) {
            tracks[track].notes.append(Note(id: 0, pitch: UInt8(pitch), velocity: UInt8(velocity), startTick: max(0, tick), durationTick: max(1, duration), channel: UInt8(channel)))
        }
        public mutating func cc(_ track: Int, _ number: Int, _ value: Int, tick: Int, channel: Int = 0) {
            tracks[track].events.append(MIDIEvent(tick: tick, kind: .channel(status: 0xB0 | UInt8(channel), data1: UInt8(number), data2: UInt8(value))))
        }
        /// Acorde con ataques desfasados `offsetsMs` (uno por nota, en ms) respecto a `tick`.
        public mutating func chord(_ track: Int, pitches: [Int], tick: Int, duration: Int, offsetsMs: [Double] = [], velocity: Int = 90, channel: Int = 0) {
            let map = tempoMap
            for (k, p) in pitches.enumerated() {
                let off = k < offsetsMs.count ? offsetsMs[k] : 0
                let t = map.tick(atSeconds: map.seconds(atTick: tick) + off / 1000)
                note(track, pitch: p, tick: t, duration: duration - (t - tick), velocity: velocity, channel: channel)
            }
        }
        public func data() -> Data {
            let end = tracks.flatMap { $0.notes.map(\.endTick) }.max() ?? 0
            let bar = tempoMap.barLength(tempoMap.meter(atTick: end))
            let endTick = (end / bar + 1) * bar
            return MIDIWriter.write(format: 1, ppq: ppq, tracks: [MIDIWriter.Track(events: conductor, endTick: endTick)] + tracks.map { var t = $0; t.endTick = endTick; return t })
        }
    }

    /// Voicings de coro de 3 a 8 notas (alturas MIDI) sobre Do mayor.
    static let voicings: [[Int]] = [
        [60, 64, 67], [57, 60, 64, 69], [53, 57, 60, 65, 69], [55, 59, 62, 67, 71, 74],
        [48, 55, 60, 64, 67, 72, 76], [45, 52, 57, 60, 64, 69, 72, 76], [50, 57, 62, 65, 69, 74, 77, 81],
    ]

    public static func all() -> [(name: String, data: Data)] {
        var rng = RNG(seed: 42)
        var out: [(String, Data)] = []

        // 1. Acordes de 3 a 8 notas, uno por compás, desfases de ±15 ms.
        do {
            var b = Builder(bpm: 100)
            let t = b.addTrack(name: "Coros 3-8")
            for (bar, v) in voicings.enumerated() {
                b.chord(t, pitches: v, tick: bar * 4 * b.ppq, duration: 4 * b.ppq - 60, offsetsMs: v.map { _ in rng.uniform(-15, 15) }, velocity: rng.int(70...100))
            }
            out.append(("chords_3_to_8", b.data()))
        }
        // 2. Acordes impares (3, 5, 7) en negras con desfases de hasta 25 ms.
        do {
            var b = Builder(bpm: 120)
            let t = b.addTrack(name: "Impares")
            let odd = [voicings[0], voicings[2], voicings[4], [62, 65, 69], [48, 52, 55, 60, 64], [41, 48, 53, 57, 60, 65, 69]]
            for i in 0..<24 {
                let v = odd[i % odd.count]
                b.chord(t, pitches: v, tick: i * b.ppq, duration: b.ppq - 40, offsetsMs: v.map { _ in rng.uniform(0, 25) }, velocity: rng.int(60...110))
            }
            out.append(("odd_chords", b.data()))
        }
        // 3. Progresión de coro a 8 voces, 90 BPM, con pedal de sustain.
        do {
            var b = Builder(bpm: 90)
            let t = b.addTrack(name: "Choir pad")
            let prog: [[Int]] = [[48, 55, 60, 64, 67, 72, 76, 79], [45, 52, 57, 60, 64, 69, 72, 76], [41, 48, 53, 57, 60, 65, 69, 72], [43, 50, 55, 59, 62, 67, 71, 74]]
            for bar in 0..<16 {
                let tick = bar * 4 * b.ppq
                b.cc(t, 64, 127, tick: tick + 10)
                b.chord(t, pitches: prog[bar % 4], tick: tick, duration: 2 * b.ppq, offsetsMs: (0..<8).map { _ in rng.uniform(-15, 15) }, velocity: rng.int(64...96))
                b.chord(t, pitches: prog[bar % 4].map { $0 + (bar % 2 == 0 ? 0 : 2) }, tick: tick + 2 * b.ppq, duration: 2 * b.ppq - 30, offsetsMs: (0..<8).map { _ in rng.uniform(-15, 15) }, velocity: rng.int(64...96))
                b.cc(t, 64, 0, tick: tick + 4 * b.ppq - 20)
            }
            out.append(("choir_8_voices", b.data()))
        }
        // 4. Cambios de tempo y de compás (3/4 → 6/8) con acordes de 4 y 5.
        do {
            var b = Builder(bpm: 80, numerator: 3, denominator: 4)
            let t = b.addTrack(name: "Tempo changes")
            b.conductor.append(.tempo(Int(60_000_000 / 140.0), at: 4 * 3 * b.ppq))
            b.conductor.append(.timeSignature(6, 8, at: 8 * 3 * b.ppq))
            for i in 0..<36 {
                let v = i % 2 == 0 ? voicings[1] : voicings[2]
                b.chord(t, pitches: v, tick: i * b.ppq, duration: b.ppq - 30, offsetsMs: v.map { _ in rng.uniform(-10, 10) })
            }
            out.append(("tempo_and_meter_changes", b.data()))
        }
        // 5. Multipista: acordes (canal 1), bajo (canal 2), melodía (canal 3).
        do {
            var b = Builder(bpm: 110)
            let chords = b.addTrack(name: "Piano"), bass = b.addTrack(name: "Bass"), mel = b.addTrack(name: "Lead")
            let prog = [voicings[1], voicings[2], voicings[1], voicings[3]]
            for bar in 0..<8 {
                let tick = bar * 4 * b.ppq
                b.chord(chords, pitches: prog[bar % 4], tick: tick, duration: 4 * b.ppq - 40, offsetsMs: prog[bar % 4].map { _ in rng.uniform(-12, 12) }, channel: 0)
                b.note(bass, pitch: prog[bar % 4][0] - 12, tick: tick, duration: 2 * b.ppq, channel: 1)
                b.note(bass, pitch: prog[bar % 4][0] - 5, tick: tick + 2 * b.ppq, duration: 2 * b.ppq, channel: 1)
                for k in 0..<8 { b.note(mel, pitch: 72 + [0, 2, 4, 7, 9, 7, 4, 2][k], tick: tick + k * b.ppq / 2, duration: b.ppq / 2 - 20, channel: 2) }
            }
            out.append(("multitrack", b.data()))
        }
        // 6. Rendimiento: 20 000 notas.
        do {
            var b = Builder(bpm: 120)
            let t = b.addTrack(name: "Stress 20000")
            var count = 0, beat = 0
            while count < 20_000 {
                let v = voicings[beat % voicings.count]
                let size = min(v.count, 20_000 - count)
                b.chord(t, pitches: Array(v.prefix(size)).map { $0 + (beat / 7) % 12 }, tick: beat * b.ppq / 2, duration: b.ppq / 2 - 10, offsetsMs: v.map { _ in rng.uniform(-15, 15) }, velocity: rng.int(40...120))
                count += size; beat += 1
            }
            out.append(("stress_20000_notes", b.data()))
        }
        // 7. Casos raros: notas solapadas del mismo pitch y una nota colgada (sin NoteOff).
        do {
            var bytes: [UInt8] = Array("MThd".utf8) + MIDIWriter.be32(6) + MIDIWriter.be16(0) + MIDIWriter.be16(1) + MIDIWriter.be16(480)
            var trk: [UInt8] = []
            trk += [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]
            trk += [0x00, 0x90, 60, 100]          // C3 #1
            trk += MIDIWriter.vlq(240) + [62, 90] // running status: D3
            trk += MIDIWriter.vlq(0) + [60, 80]   // C3 #2 solapada
            trk += MIDIWriter.vlq(240) + [60, 0]  // NoteOn vel 0 → cierra C3 #1 (el más antiguo)
            trk += MIDIWriter.vlq(240) + [0x80, 60, 64, 0x00, 0x80, 62, 64]
            trk += MIDIWriter.vlq(0) + [0x90, 67, 100]  // G3 colgada
            trk += MIDIWriter.vlq(960) + [0xFF, 0x2F, 0x00]
            bytes += Array("MTrk".utf8) + MIDIWriter.be32(trk.count) + trk
            out.append(("edge_overlap_hanging", Data(bytes)))
        }
        return out
    }
}
