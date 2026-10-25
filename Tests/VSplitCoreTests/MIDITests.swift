import XCTest
@testable import VSplitCore

final class MIDITests: XCTestCase {
    func smf(format: Int = 0, ppq: Int = 480, tracks: [[UInt8]]) -> Data {
        var b: [UInt8] = Array("MThd".utf8) + MIDIWriter.be32(6) + MIDIWriter.be16(format) + MIDIWriter.be16(tracks.count) + MIDIWriter.be16(ppq)
        for t in tracks { b += Array("MTrk".utf8) + MIDIWriter.be32(t.count) + t }
        return Data(b)
    }

    func testVLQ() {
        for v in [0, 1, 0x7F, 0x80, 0x2000, 0x3FFF, 0x4000, 0x1F_FFFF, 0x20_0000, 0x0FFF_FFFF] {
            var r = Reader(bytes: MIDIWriter.vlq(v))
            XCTAssertEqual(r.readVLQ(), v)
        }
        XCTAssertEqual(MIDIWriter.vlq(0x80), [0x81, 0x00])
    }

    func testRunningStatusAndNoteOnZeroVelocity() throws {
        let trk: [UInt8] = [0x00, 0x90, 60, 100, 0x00, 64, 90, 0x83, 0x60, 60, 0, 0x00, 64, 0, 0x00, 0xFF, 0x2F, 0x00]
        let seq = try MIDIParser.parse(data: smf(tracks: [trk]))
        XCTAssertEqual(seq.notes.count, 2)
        XCTAssertEqual(seq.notes.map(\.pitch), [60, 64])
        XCTAssertEqual(seq.notes.map(\.durationTick), [480, 480])
        XCTAssertEqual(seq.notes.map(\.velocity), [100, 90])
        XCTAssertTrue(seq.warnings.isEmpty)
    }

    func testOverlappingSamePitchPairsOldestFirstAndHangingNotes() throws {
        let data = SampleGenerator.all().first { $0.name == "edge_overlap_hanging" }!.data
        let seq = try MIDIParser.parse(data: data)
        let c3 = seq.notes.filter { $0.pitch == 60 }
        XCTAssertEqual(c3.count, 2)
        // C3 #1 empieza en 0 y lo cierra el primer NoteOff (tick 480); C3 #2 empieza en 240 y termina en 720.
        XCTAssertEqual(c3[0].startTick, 0); XCTAssertEqual(c3[0].endTick, 480); XCTAssertEqual(c3[0].velocity, 100)
        XCTAssertEqual(c3[1].startTick, 240); XCTAssertEqual(c3[1].endTick, 720); XCTAssertEqual(c3[1].velocity, 80)
        let g = try XCTUnwrap(seq.notes.first { $0.pitch == 67 })
        XCTAssertEqual(g.startTick, 720)
        XCTAssertEqual(g.endTick, 720 + 960, "la nota colgada se cierra al final del clip")
        XCTAssertTrue(seq.warnings.contains(.hangingNotes(count: 1)))
    }

    func testMetaSysexAndChannelEventsArePreserved() throws {
        var trk: [UInt8] = []
        trk += [0x00, 0xFF, 0x03, 0x04] + Array("Coro".utf8)
        trk += [0x00, 0xFF, 0x51, 0x03, 0x09, 0x27, 0xC0]            // 100 BPM
        trk += [0x00, 0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08]      // 3/4
        trk += [0x00, 0xFF, 0x59, 0x02, 0xFE, 0x01]                  // 2 bemoles, menor
        trk += [0x00, 0xFF, 0x06, 0x05] + Array("Verse".utf8)
        trk += [0x00, 0xF0, 0x05, 0x7E, 0x7F, 0x09, 0x01, 0xF7]      // GM reset
        trk += [0x00, 0xC0, 52]                                       // program change
        trk += [0x00, 0xB0, 64, 127]                                  // sustain
        trk += [0x10, 0xE0, 0x00, 0x50]                               // pitch bend
        trk += [0x00, 0xD0, 40]                                       // channel aftertouch
        trk += [0x00, 0xA0, 60, 30]                                   // poly aftertouch
        trk += [0x00, 0x90, 60, 100, 0x83, 0x60, 0x80, 60, 40]
        trk += [0x00, 0xFF, 0x2F, 0x00]
        let seq = try MIDIParser.parse(data: smf(tracks: [trk]))
        XCTAssertEqual(seq.tracks[0].name, "Coro")
        XCTAssertEqual(seq.tempoMap.initialBPM, 100, accuracy: 0.01)
        XCTAssertEqual(seq.tempoMap.meter(atTick: 0).numerator, 3)
        XCTAssertEqual(seq.events.first { $0.keySignature != nil }?.keySignature?.sharps, -2)
        XCTAssertEqual(seq.events.first { $0.metaType == 0x06 }?.text, "Verse")
        XCTAssertTrue(seq.events.contains { if case .sysex(0xF0, [0x7E, 0x7F, 0x09, 0x01, 0xF7]) = $0.kind { return true }; return false })
        let channel = seq.events.compactMap { e -> [UInt8]? in if case .channel(let s, let a, let b) = e.kind { return [s, a, b] }; return nil }
        XCTAssertEqual(channel, [[0xC0, 52, 0], [0xB0, 64, 127], [0xE0, 0, 0x50], [0xD0, 40, 0], [0xA0, 60, 30]])
        XCTAssertEqual(seq.notes.first?.releaseVelocity, 40)

        // Releer lo escrito da exactamente los mismos eventos.
        let again = try MIDIParser.parse(data: MIDIWriter.write(seq))
        XCTAssertEqual(again.events.map(\.kind), seq.events.map(\.kind))
        XCTAssertEqual(again.events.map(\.tick), seq.events.map(\.tick))
        XCTAssertEqual(again.notes, seq.notes)
    }

    func testRawRoundTripIsStable() throws {
        for (name, data) in SampleGenerator.all() {
            let a = try MIDIParser.parse(data: data)
            let written = MIDIWriter.write(a)
            let b = try MIDIParser.parse(data: written)
            XCTAssertEqual(a.ppq, b.ppq, name)
            XCTAssertEqual(a.notes, b.notes, name)
            XCTAssertEqual(a.events.map(\.kind), b.events.map(\.kind), name)
            XCTAssertEqual(a.events.map(\.tick), b.events.map(\.tick), name)
            XCTAssertEqual(a.tracks.map(\.endTick), b.tracks.map(\.endTick), name)
            XCTAssertEqual(MIDIWriter.write(b), written, "escribir dos veces da los mismos bytes: \(name)")
        }
    }

    /// Criterio de aceptación 2: cargar y exportar con una sola voz da un MIDI equivalente.
    func testSingleVoiceExportIsEquivalent() throws {
        for (name, data) in SampleGenerator.all() {
            let seq = try MIDIParser.parse(data: data)
            var doc = SplitDocument(sequence: seq, voices: [Voice(id: 1, name: "Todo", color: Voice.palette[0])])
            doc.apply(doc.assignCommand(doc.notes.indices, to: 1, name: "all")!)
            let out = try MIDIParser.parse(data: Exporter.voiceFile(doc, voice: doc.voices[0], options: ExportOptions()))
            XCTAssertEqual(out.format, 1, name)
            XCTAssertEqual(out.ppq, seq.ppq, name)
            XCTAssertEqual(out.tempoMap, seq.tempoMap, name)
            func key(_ n: Note) -> [Int] { [n.startTick, n.durationTick, Int(n.pitch), Int(n.velocity), Int(n.channel)] }
            XCTAssertEqual(out.notes.map(key), seq.notes.map(key), name)
            let cc = { (s: MIDISequence) in s.events.filter(\.isChannelEvent).map { [$0.tick] + { if case .channel(let a, let b, let c) = $0 { return [Int(a), Int(b), Int(c)] }; return [] }($0.kind) } }
            XCTAssertEqual(cc(out), cc(seq), name)
            XCTAssertGreaterThanOrEqual(out.endTick, seq.notes.map(\.endTick).max() ?? 0)
        }
    }

    func testSMPTEDivisionIsConverted() throws {
        // 25 fps × 40 ticks/frame = 1000 ticks/s. Nota de 500 ticks = 0,5 s = una negra a 120 BPM = 960 PPQ.
        var b: [UInt8] = Array("MThd".utf8) + MIDIWriter.be32(6) + MIDIWriter.be16(0) + MIDIWriter.be16(1) + [0xE7, 40]
        let trk: [UInt8] = [0x00, 0x90, 60, 100] + MIDIWriter.vlq(500) + [0x80, 60, 0, 0x00, 0xFF, 0x2F, 0x00]
        b += Array("MTrk".utf8) + MIDIWriter.be32(trk.count) + trk
        let seq = try MIDIParser.parse(data: Data(b))
        XCTAssertEqual(seq.ppq, 960)
        XCTAssertEqual(seq.notes.first?.durationTick, 960)
        XCTAssertEqual(seq.tempoMap.initialBPM, 120, accuracy: 0.001)
        XCTAssertTrue(seq.warnings.contains { if case .smpteDivisionConverted = $0 { return true }; return false })
    }

    func testFormat1MultipleTracks() throws {
        let data = SampleGenerator.all().first { $0.name == "multitrack" }!.data
        let seq = try MIDIParser.parse(data: data)
        XCTAssertEqual(seq.format, 1)
        XCTAssertEqual(seq.tracks.count, 4)
        XCTAssertEqual(seq.tracksWithNotes.map(\.name), ["Piano", "Bass", "Lead"])
        let doc = SplitDocument(sequence: seq, tracks: [2])
        XCTAssertEqual(doc.notes.count, 16)
        XCTAssertTrue(doc.notes.allSatisfy { $0.track == 2 })
        XCTAssertEqual(doc.notes.map(\.id), Array(0..<16))
    }

    func testGarbageNeverCrashes() {
        XCTAssertThrowsError(try MIDIParser.parse(data: Data("hola".utf8))) { XCTAssertEqual($0 as? MIDIError, .notMIDI) }
        XCTAssertThrowsError(try MIDIParser.parse(data: Data()))
        let good = SampleGenerator.all()[0].data
        // Truncar en cualquier punto no debe romper nada.
        for cut in stride(from: 0, to: good.count, by: 7) { _ = try? MIDIParser.parse(data: good.prefix(cut)) }
        var rng = SampleGenerator.RNG(seed: 7)
        for _ in 0..<300 {
            var bytes = [UInt8](good)
            for _ in 0..<20 { bytes[rng.int(14...(bytes.count - 1))] = UInt8(rng.next() & 0xFF) }
            _ = try? MIDIParser.parse(data: Data(bytes))
            let random = (0..<rng.int(0...200)).map { _ in UInt8(rng.next() & 0xFF) }
            _ = try? MIDIParser.parse(data: smf(tracks: [random]))
        }
    }

    func testTruncatedTrackWarns() throws {
        let trk: [UInt8] = [0x00, 0x90, 60, 100, 0x83, 0x60, 0x80, 60, 0, 0x00, 0xFF, 0x2F, 0x00]
        var data = smf(tracks: [trk])
        data = data.prefix(data.count - 5)
        let seq = try MIDIParser.parse(data: data)
        XCTAssertEqual(seq.notes.count, 1)
        XCTAssertTrue(seq.warnings.contains(.truncatedTrack(index: 0)))
    }

    func testRMIDWrapper() throws {
        let inner = [UInt8](SampleGenerator.all()[0].data)
        var riff: [UInt8] = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("RMID".utf8) + Array("data".utf8)
        riff += [UInt8(inner.count & 0xFF), UInt8((inner.count >> 8) & 0xFF), UInt8((inner.count >> 16) & 0xFF), 0] + inner
        XCTAssertEqual(try MIDIParser.parse(data: Data(riff)).notes.count, try MIDIParser.parse(data: Data(inner)).notes.count)
    }

    func testTempoMapConversions() {
        let map = TempoMap(ppq: 480, events: [.tempo(500_000, at: 0), .tempo(1_000_000, at: 960), .timeSignature(3, 4, at: 0), .timeSignature(6, 8, at: 1440 * 2)])
        XCTAssertEqual(map.seconds(atTick: 960), 1.0, accuracy: 1e-9)
        XCTAssertEqual(map.seconds(atTick: 1440), 2.0, accuracy: 1e-9)
        XCTAssertEqual(map.tick(atSeconds: 2.0), 1440)
        XCTAssertEqual(map.ticks(forMilliseconds: 35, from: 0), 34)    // 120 BPM: 960 ticks/s
        XCTAssertEqual(map.ticks(forMilliseconds: 35, from: 1000), 17) // 60 BPM: 480 ticks/s
        XCTAssertEqual(map.position(atTick: 1440).bar, 1)
        XCTAssertEqual(map.position(atTick: 2880).bar, 2)
        XCTAssertEqual(map.position(atTick: 2880 + 1440).bar, 3)  // 6/8 = 1440 ticks
        XCTAssertEqual(map.bars(from: 0, to: 5000).map(\.length), [1440, 1440, 1440, 1440])
    }

    func testNoteNames() {
        XCTAssertEqual(NoteNames.name(60), "C3")
        XCTAssertEqual(NoteNames.name(60, middleCOctave: 4), "C4")
        XCTAssertEqual(NoteNames.name(0), "C-2")
        XCTAssertEqual(NoteNames.name(69), "A3")
        XCTAssertEqual(NoteNames.keyName(sharps: -2, minor: true), "Gm")
    }
}
