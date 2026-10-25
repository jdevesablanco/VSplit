import XCTest
@testable import VSplitCore

/// Cada caso se escribe como líneas (de aguda a grave); el reparto natural debe devolver exactamente esas líneas.
final class NaturalVoicesTests: XCTestCase {
    typealias Event = (pitch: Int, beat: Double, length: Double)

    /// Construye el clip a partir de las líneas, con desfases humanos de ±15 ms, y comprueba que cada nota cae en su línea.
    func check(_ lines: [[Event]], voices: Int? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        var b = SampleGenerator.Builder(bpm: 90)
        let t = b.addTrack(name: "t")
        var rng = SampleGenerator.RNG(seed: 11)
        var expected: [String: Int] = [:]
        let map = b.tempoMap
        for (v, l) in lines.enumerated() {
            for e in l {
                let base = Int(e.beat * Double(b.ppq))
                let tick = max(0, map.tick(atSeconds: map.seconds(atTick: base) + rng.uniform(-0.015, 0.015)))
                b.note(t, pitch: e.pitch, tick: tick, duration: Int(e.length * Double(b.ppq)) - 20, velocity: 80 + v)
                expected["\(e.pitch)@\(tick)"] = v
            }
        }
        let seq = try MIDIParser.parse(data: b.data())
        let n = voices ?? lines.count
        let r = NaturalVoices.assign(notes: seq.notes, indices: Array(seq.notes.indices), voices: n, windowMs: 35, tempoMap: seq.tempoMap)
        var wrong: [String] = []
        for (i, note) in seq.notes.enumerated() {
            let want = expected["\(note.pitch)@\(note.startTick)"]!
            if r[i] != want { wrong.append("\(NoteNames.name(Int(note.pitch))) beat \(Double(note.startTick) / 480): voz \(r[i]) (esperada \(want))") }
        }
        XCTAssertTrue(wrong.isEmpty, "\n" + wrong.joined(separator: "\n"), file: file, line: line)
    }

    /// Acordes en negras: cada array son las alturas de arriba abajo.
    func blocks(_ chords: [[Int]], length: Double = 1) -> [[Event]] {
        let n = chords[0].count
        return (0..<n).map { v in chords.enumerated().compactMap { k, c in v < c.count ? (c[v], Double(k) * length, length) : nil } }
    }

    func testFourPartChorale() throws {
        // Coral a 4 voces en Do: S A T B (alturas MIDI, C3 = 60 en Logic).
        try check(blocks([
            [76, 72, 67, 48], [77, 72, 69, 53], [79, 74, 71, 55], [76, 72, 67, 60],
            [74, 71, 67, 55], [72, 69, 64, 57], [74, 69, 65, 50], [72, 67, 64, 48],
        ]))
    }

    func testCloseInnerVoicesMovingInParallel() throws {
        // Contralto y tenor a una 3.ª, subiendo y bajando juntos; un reparto por turnos los mezclaría.
        try check(blocks([
            [79, 67, 64, 48], [79, 69, 65, 48], [79, 71, 67, 48], [79, 72, 69, 48],
            [79, 71, 67, 48], [79, 69, 65, 48], [79, 67, 64, 48],
        ]))
    }

    func testBassRestsAndComesBack() throws {
        // El bajo calla dos pulsos: soprano, contralto y tenor no deben "bajar" una voz.
        let s: [Event] = (0..<6).map { (76 - [0, 1, 3, 1, 0, 0][$0], Double($0), 1) }
        let a: [Event] = (0..<6).map { (72 - [0, 0, 1, 0, 0, 0][$0], Double($0), 1) }
        let t: [Event] = (0..<6).map { (67 - [0, 0, 2, 0, 0, 0][$0], Double($0), 1) }
        let bass: [Event] = [(48, 0, 1), (50, 1, 1), (48, 4, 1), (43, 5, 1)]
        try check([s, a, t, bass])
    }

    func testMovingAltoOverHeldVoices() throws {
        // Notas de paso en corcheas en la contralto mientras las demás sostienen blancas.
        let s: [Event] = [(76, 0, 2), (77, 2, 2)]
        let a: [Event] = [(67, 0, 0.5), (69, 0.5, 0.5), (71, 1, 0.5), (72, 1.5, 0.5), (72, 2, 0.5), (71, 2.5, 0.5), (69, 3, 0.5), (69, 3.5, 0.5)]
        let t: [Event] = [(64, 0, 2), (65, 2, 2)]
        let bass: [Event] = [(48, 0, 2), (53, 2, 2)]
        try check([s, a, t, bass])
    }

    func testMelodyOverSustainedPad() throws {
        // Melodía en corcheas por encima de un pad de 3 notas que cambia cada compás.
        let mel: [Event] = (0..<16).map { (79 + [0, 2, 4, 2, 0, -1, 0, 2, 4, 5, 4, 2, 0, -1, -3, -5][$0], Double($0) * 0.5, 0.5) }
        let pad1: [Event] = [(72, 0, 4), (74, 4, 4)]
        let pad2: [Event] = [(67, 0, 4), (69, 4, 4)]
        let pad3: [Event] = [(60, 0, 4), (62, 4, 4)]
        try check([mel, pad1, pad2, pad3])
    }

    func testOctaveLeapInBassStaysBass() throws {
        try check(blocks([
            [76, 72, 67, 60], [76, 72, 67, 48], [77, 72, 69, 53], [79, 74, 71, 43], [76, 72, 67, 48],
        ]))
    }

    func testContraryMotionOuterVoices() throws {
        // La soprano sube mientras el bajo baja, con las voces interiores quietas.
        try check(blocks([
            [72, 67, 64, 48], [74, 67, 64, 47], [76, 67, 64, 45], [77, 67, 64, 43], [79, 67, 64, 41],
        ]))
    }

    func testDetectsVoiceCount() throws {
        func count(_ lines: [[Event]]) throws -> Int {
            var b = SampleGenerator.Builder()
            let t = b.addTrack(name: "t")
            for l in lines { for e in l { b.note(t, pitch: e.pitch, tick: Int(e.beat * 480), duration: Int(e.length * 480) - 20) } }
            let seq = try MIDIParser.parse(data: b.data())
            return NaturalVoices.detectCount(notes: seq.notes, indices: Array(seq.notes.indices), windowMs: 35, tempoMap: seq.tempoMap)
        }
        XCTAssertEqual(try count(blocks([[76, 72, 67, 48], [77, 72, 69, 53], [79, 74, 71, 55]])), 4)
        XCTAssertEqual(try count([[(60, 0, 1), (62, 1, 1), (64, 2, 1)]]), 1)
        // Pad sostenido + melodía: 4 aunque los ataques de la melodía vayan solos.
        let mel: [Event] = (0..<8).map { (79 + $0 % 3, Double($0) * 0.5, 0.5) }
        XCTAssertEqual(try count([mel, [(72, 0, 4)], [(67, 0, 4)], [(60, 0, 4)]]), 4)
        let choir = try MIDIParser.parse(data: SampleGenerator.all().first { $0.name == "choir_8_voices" }!.data)
        XCTAssertEqual(NaturalVoices.detectCount(notes: choir.notes, indices: Array(choir.notes.indices), windowMs: 35, tempoMap: choir.tempoMap), 8)
    }

    func testRoleNames() {
        XCTAssertEqual(NaturalVoices.roleNames(4), ["Soprano", "Alto", "Tenor", "Bass"])
        XCTAssertEqual(NaturalVoices.defaultVoices(count: 4).map(\.pan), [-60, -20, 20, 60])
    }

    /// Sin saltos raros: en el coro de 8 voces de muestra, ninguna voz salta más de una 5.ª entre notas seguidas.
    func testChoirSampleHasSmoothLines() throws {
        let seq = try MIDIParser.parse(data: SampleGenerator.all().first { $0.name == "choir_8_voices" }!.data)
        let r = NaturalVoices.assign(notes: seq.notes, indices: Array(seq.notes.indices), voices: 8, windowMs: 35, tempoMap: seq.tempoMap)
        for v in 0..<8 {
            let line = seq.notes.indices.filter { r[$0] == v }.map { Int(seq.notes[$0].pitch) }
            XCTAssertEqual(line.count, 32, "voz \(v)")
            let maxLeap = zip(line, line.dropFirst()).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThanOrEqual(maxLeap, 7, "voz \(v): \(line)")
        }
    }
}

extension NaturalVoicesTests {
    /// Corales aleatorios: 4 líneas por grados conjuntos (con algún salto), sin cruces, cada voz con su ritmo,
    /// silencios, notas sostenidas y desfases humanos. Mide qué porcentaje de notas acaba en su línea.
    func randomChorale(seed: UInt64, voices n: Int = 4) -> [[Event]] {
        var rng = SampleGenerator.RNG(seed: seed)
        let start = [79, 72, 64, 52, 45, 40].prefix(n)
        var cur = Array(start)
        var lines = [[Event]](repeating: [], count: n)
        var beat = 0.0
        while beat < 32 {
            // Cada voz decide si ataca en este pulso (las exteriores casi siempre).
            for v in 0..<n {
                if let last = lines[v].last, last.beat + last.length > beat + 0.01 { continue }   // aún sostiene
                if v != 0 && v != n - 1 && rng.uniform(0, 1) < 0.1 { continue }            // silencio interior
                var step = [-2, -1, -1, 0, 1, 1, 2][rng.int(0...6)]
                if rng.uniform(0, 1) < 0.08 { step = [-7, -5, 5, 7, -12, 12][rng.int(0...5)] * (v == n - 1 ? 1 : 0) + step }
                var p = cur[v] + step
                // Sin cruces y con al menos una 2.ª entre vecinas; cada voz en su tesitura.
                let hi = v == 0 ? 84 : cur[v - 1] - 2, lo = v == n - 1 ? 36 : cur[v + 1] + 2
                p = min(max(p, start[v] - 9), start[v] + 9)
                p = min(max(p, lo), hi)
                cur[v] = p
                let len = [1.0, 1, 2, 0.5, 1.5][rng.int(0...4)]
                lines[v].append((p, beat, len))
            }
            beat += [0.5, 1][rng.int(0...1)]
        }
        // Evitar notas con el mismo pitch sonando a la vez en dos voces (en MIDI se fundirían).
        return lines
    }

    func testRandomChoralesAccuracy() throws {
        var total = 0, ok = 0
        for seed in 1...40 {
            let lines = randomChorale(seed: UInt64(seed))
            var b = SampleGenerator.Builder(bpm: 100)
            let t = b.addTrack(name: "t")
            var rng = SampleGenerator.RNG(seed: UInt64(seed) &* 7)
            let map = b.tempoMap
            var expected: [String: Int] = [:]
            for (v, l) in lines.enumerated() {
                for e in l {
                    let base = Int(e.beat * 480)
                    let tick = max(0, map.tick(atSeconds: map.seconds(atTick: base) + rng.uniform(-0.015, 0.015)))
                    let key = "\(e.pitch)@\(tick)"
                    guard expected[key] == nil else { continue }
                    b.note(t, pitch: e.pitch, tick: tick, duration: Int(e.length * 480) - 25)
                    expected[key] = v
                }
            }
            let seq = try MIDIParser.parse(data: b.data())
            let r = NaturalVoices.assign(notes: seq.notes, indices: Array(seq.notes.indices), voices: 4, windowMs: 35, tempoMap: seq.tempoMap)
            for (i, note) in seq.notes.enumerated() {
                guard let want = expected["\(note.pitch)@\(note.startTick)"] else { continue }
                total += 1
                if r[i] == want { ok += 1 }
            }
        }
        let acc = Double(ok) / Double(total)
        print(String(format: "Corales aleatorios: %d/%d notas en su línea (%.2f %%)", ok, total, acc * 100))
        XCTAssertGreaterThanOrEqual(acc, 0.98)
    }
}
