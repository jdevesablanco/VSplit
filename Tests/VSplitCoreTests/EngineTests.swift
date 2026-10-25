import XCTest
@testable import VSplitCore

final class EngineTests: XCTestCase {
    /// Documento de prueba a partir de un Builder.
    func doc(_ build: (inout SampleGenerator.Builder, Int) -> Void, voices: Int = 2, bpm: Double = 120) throws -> SplitDocument {
        var b = SampleGenerator.Builder(bpm: bpm)
        let t = b.addTrack(name: "t")
        build(&b, t)
        let seq = try MIDIParser.parse(data: b.data())
        let vs = (0..<voices).map { Voice(id: $0 + 1, name: Voice.defaultName(index: $0), color: Voice.palette[$0 % 16]) }
        return SplitDocument(sequence: seq, voices: vs)
    }

    static var alternate: SplitParams { var p = SplitParams(); p.mode = .alternate; return p }

    func split(_ d: SplitDocument, _ p: SplitParams = EngineTests.alternate, indices: [Int]? = nil) -> [Int] {
        AutoSplitter.assign(notes: d.notes, indices: indices ?? Array(d.notes.indices), voiceCount: d.voices.count, params: p, tempoMap: d.tempoMap)
    }

    func counts(_ r: [Int], _ n: Int = 2) -> [Int] { (0..<n).map { v in r.filter { $0 == v }.count } }

    // MARK: Criterio de aceptación 3

    func testFiveNoteChordWithJitterSplitsThreeAndTwo() throws {
        let d = try doc { b, t in b.chord(t, pitches: [48, 55, 60, 64, 67], tick: 960, duration: 960, offsetsMs: [0, 15, -15, 8, -6]) }
        let r = split(d)
        XCTAssertEqual(counts(r), [3, 2])
        // Alternando de grave a agudo: C, E y G a la voz A; G2 y C3… a la B.
        let byPitch = Dictionary(uniqueKeysWithValues: d.notes.indices.map { (Int(d.notes[$0].pitch), r[$0]) })
        XCTAssertEqual([48, 55, 60, 64, 67].map { byPitch[$0]! }, [0, 1, 0, 1, 0])
        XCTAssertEqual(ChordDetector.chords(notes: d.notes, indices: Array(d.notes.indices), windowMs: 35, tempoMap: d.tempoMap).count, 1)
    }

    func testEightNoteChordSplitsFourAndFour() throws {
        let d = try doc { b, t in b.chord(t, pitches: [45, 52, 57, 60, 64, 69, 72, 76], tick: 0, duration: 960, offsetsMs: [0, 12, 3, 14, 7, 1, 9, 15]) }
        XCTAssertEqual(counts(split(d)), [4, 4])
    }

    func testConsecutiveChordsBeyondWindowAreNotMerged() throws {
        // Segundo acorde 50 ms después del primero (ventana 35 ms) y un tercero solapado en duración.
        let d = try doc { b, t in
            let map = b.tempoMap
            b.chord(t, pitches: [60, 64, 67], tick: 0, duration: 2000, offsetsMs: [0, 10, 20])
            b.chord(t, pitches: [62, 65, 69], tick: map.tick(atSeconds: 0.050), duration: 900, offsetsMs: [0, 5, 10])
            b.chord(t, pitches: [59, 62, 67, 71, 74], tick: 1920, duration: 480, offsetsMs: [-15, 15, 0, 5, -5])
        }
        let chords = ChordDetector.chords(notes: d.notes, indices: Array(d.notes.indices), windowMs: 35, tempoMap: d.tempoMap)
        XCTAssertEqual(chords.map(\.count), [3, 3, 5])
        XCTAssertEqual(counts(split(d)), [2 + 2 + 3, 1 + 1 + 2])
    }

    func testWindowDependsOnTempo() throws {
        // 30 ticks a 120 BPM ≈ 31 ms (mismo acorde); a 60 BPM ≈ 62 ms (acordes distintos).
        for (bpm, expected) in [(120.0, 1), (60.0, 2)] {
            let d = try doc({ b, t in b.note(t, pitch: 60, tick: 0, duration: 480); b.note(t, pitch: 64, tick: 30, duration: 480) }, bpm: bpm)
            XCTAssertEqual(ChordDetector.chords(notes: d.notes, indices: [0, 1], windowMs: 35, tempoMap: d.tempoMap).count, expected, "\(bpm) BPM")
        }
    }

    func testRemainderToLastVoiceKeepsAlternation() throws {
        let d = try doc { b, t in b.chord(t, pitches: [48, 52, 55, 60, 64], tick: 0, duration: 480) }
        var p = EngineTests.alternate; p.remainder = .last
        let r = split(d, p)
        XCTAssertEqual(counts(r), [2, 3])
        XCTAssertEqual(r, [1, 0, 1, 0, 1])
    }

    func testHighToLowOrder() throws {
        let d = try doc { b, t in b.chord(t, pitches: [48, 52, 55, 60], tick: 0, duration: 480) }
        XCTAssertEqual(split(d), [0, 1, 0, 1])
        var p = EngineTests.alternate; p.order = .highToLow
        XCTAssertEqual(split(d, p), [1, 0, 1, 0])  // la más aguda a A
    }

    func testContinuePatternAcrossChords() throws {
        let d = try doc { b, t in
            b.chord(t, pitches: [48, 52, 55], tick: 0, duration: 400)
            b.chord(t, pitches: [50, 53, 57], tick: 480, duration: 400)
        }
        XCTAssertEqual(split(d), [0, 1, 0, 0, 1, 0])
        var p = EngineTests.alternate; p.continuePattern = true
        XCTAssertEqual(split(d, p), [0, 1, 0, 1, 0, 1])
    }

    func testSingleNotesAlternateOrFixed() throws {
        let d = try doc { b, t in for i in 0..<4 { b.note(t, pitch: 60 + i, tick: i * 480, duration: 400) } }
        XCTAssertEqual(split(d), [0, 1, 0, 1])
        var p = EngineTests.alternate; p.singles = .fixed; p.singlesVoice = 1
        XCTAssertEqual(split(d, p), [1, 1, 1, 1])
    }

    func testRegisterSplitAutoAndManual() throws {
        let d = try doc { b, t in for (i, p) in [40, 45, 50, 70, 75, 80].enumerated() { b.note(t, pitch: p, tick: i * 480, duration: 400) } }
        var p = EngineTests.alternate; p.mode = .register
        XCTAssertEqual(split(d, p), [0, 0, 0, 1, 1, 1])
        p.registerAuto = false; p.registerSplits = [48]
        XCTAssertEqual(split(d, p), [0, 0, 1, 1, 1, 1])
        p.order = .highToLow
        XCTAssertEqual(split(d, p), [1, 1, 0, 0, 0, 0])
    }

    func testVoiceLeadingFollowsLines() throws {
        // Dos líneas que se cruzan de registro poco a poco: la de arriba baja y la de abajo sube.
        let top = [72, 71, 69, 67, 66, 65], bottom = [55, 57, 59, 60, 62, 64]
        let d = try doc { b, t in for i in 0..<6 { b.chord(t, pitches: [bottom[i], top[i]], tick: i * 480, duration: 470) } }
        var p = EngineTests.alternate; p.mode = .voiceLeading
        let r = split(d, p)
        for i in d.notes.indices {
            let isTop = top.contains(Int(d.notes[i].pitch)) && !bottom.contains(Int(d.notes[i].pitch))
            XCTAssertEqual(r[i], isTop ? 1 : 0, "nota \(d.notes[i].pitch)")
        }
    }

    func testChannelVelocityAndBeatModes() throws {
        let d = try doc { b, t in
            for i in 0..<8 { b.note(t, pitch: 60, tick: i * 480 + (i == 3 ? -10 : 0), duration: 400, velocity: i < 4 ? 40 : 110, channel: i % 2 == 0 ? 3 : 7) }
        }
        var p = EngineTests.alternate; p.mode = .channel
        XCTAssertEqual(split(d, p), [0, 1, 0, 1, 0, 1, 0, 1])
        p.mode = .velocity
        XCTAssertEqual(split(d, p), [0, 0, 0, 0, 1, 1, 1, 1])
        p.mode = .beat
        XCTAssertEqual(split(d, p), [0, 1, 0, 1, 0, 1, 0, 1], "beat 4 adelantado 10 ticks sigue contando como beat 4")
        p.beatUnit = .bar
        XCTAssertEqual(split(d, p), [0, 0, 0, 0, 1, 1, 1, 1])
    }

    func testFairAlternateWithTwoVoices() throws {
        var p = SplitParams(); p.mode = .auto
        // 5 → 3/2, 8 → 4/4, como el modo de alternar.
        let five = try doc { b, t in b.chord(t, pitches: [48, 55, 60, 64, 67], tick: 0, duration: 480, offsetsMs: [0, 15, -15, 8, -6]) }
        XCTAssertEqual(counts(split(five, p)), [3, 2])
        let r5 = split(five, p)
        let byPitch = five.notes.indices.sorted { five.notes[$0].pitch < five.notes[$1].pitch }.map { r5[$0] }
        XCTAssertEqual(byPitch, [0, 1, 0, 1, 0], "alterna dentro del acorde (de grave a agudo)")
        let eight = try doc { b, t in b.chord(t, pitches: [45, 52, 57, 60, 64, 69, 72, 76], tick: 0, duration: 480) }
        XCTAssertEqual(counts(split(eight, p)), [4, 4])
        // Dos acordes impares seguidos: el sobrante va una vez a cada voz (5 y 5).
        let two = try doc { b, t in
            b.chord(t, pitches: [48, 52, 55, 60, 64], tick: 0, duration: 400)
            b.chord(t, pitches: [50, 53, 57, 62, 65], tick: 480, duration: 400)
        }
        XCTAssertEqual(counts(split(two, p)), [5, 5])
        // Notas sueltas: alterna y queda repartido.
        let mel = try doc { b, t in for i in 0..<7 { b.note(t, pitch: 60 + i, tick: i * 480, duration: 400) } }
        XCTAssertLessThanOrEqual(abs(counts(split(mel, p))[0] - counts(split(mel, p))[1]), 1)
    }

    func testAutoUsesNaturalLinesWithThreeOrMoreVoices() throws {
        var p = SplitParams(); p.mode = .auto
        let d = try doc({ b, t in for k in 0..<4 { b.chord(t, pitches: [48 + k, 60 + k, 72 + k], tick: k * 480, duration: 470) } }, voices: 3)
        // Líneas naturales: la nota de arriba siempre en la voz 0 (soprano), la de abajo en la 2.
        let r = split(d, p)
        for (i, n) in d.notes.enumerated() { XCTAssertEqual(r[i], n.pitch >= 72 ? 0 : (n.pitch >= 60 ? 1 : 2)) }
    }

    func testSixteenVoices() throws {
        let d = try doc({ b, t in b.chord(t, pitches: Array(40..<72), tick: 0, duration: 480) }, voices: 16)
        XCTAssertEqual(counts(split(d), 16), [Int](repeating: 2, count: 16))
    }

    func testReapplyOnlyToSelection() throws {
        let d = try doc { b, t in
            b.chord(t, pitches: [48, 52, 55, 60], tick: 0, duration: 400)
            b.chord(t, pitches: [50, 53, 57, 62], tick: 960, duration: 400)
        }
        let r = split(d, EngineTests.alternate, indices: [4, 5, 6, 7])
        XCTAssertEqual(r, [0, 1, 0, 1])
    }

    // MARK: Historial

    func testUndoRedoAndBrushStrokeIsOneStep() throws {
        let d = try doc { b, t in b.chord(t, pitches: [48, 52, 55, 60, 64], tick: 0, duration: 480) }
        var ed = Editor(document: d)
        XCTAssertTrue(ed.perform(ed.document.assignCommand(0..<5, to: 1, name: "all A")))
        // Criterio 4: el trazo de brocha asigna y es deshacible en un paso.
        ed.beginStroke(name: "Paint")
        ed.strokeAssign([1], to: 2)
        ed.strokeAssign([1, 3], to: 2)
        ed.strokeAssign([4], to: 2)
        ed.endStroke()
        XCTAssertEqual(ed.document.notes.map(\.voiceID), [1, 2, 1, 2, 2])
        XCTAssertEqual(ed.undoStack.count, 2)
        ed.undo()
        XCTAssertEqual(ed.document.notes.map(\.voiceID), [1, 1, 1, 1, 1])
        ed.redo()
        XCTAssertEqual(ed.document.notes.map(\.voiceID), [1, 2, 1, 2, 2])
        ed.undo(); ed.undo()
        XCTAssertEqual(ed.document.notes.map(\.voiceID), [nil, nil, nil, nil, nil])
        XCTAssertFalse(ed.canUndo)
        // Un trazo que no cambia nada no deja paso en el historial.
        ed.beginStroke(name: "Erase"); ed.strokeAssign([0], to: nil); ed.endStroke()
        XCTAssertFalse(ed.canUndo)
        XCTAssertTrue(ed.canRedo)
    }

    func testDeleteVoiceMovesNotesAndUndoRestores() throws {
        let d = try doc { b, t in b.chord(t, pitches: [48, 52, 55, 60], tick: 0, duration: 480) }
        var ed = Editor(document: d)
        let idx = Array(d.notes.indices)
        let r = split(d)
        ed.perform(ed.document.assignCommand(pairs: zip(idx, r).map { ($0, d.voices[$1].id) }, name: "split"))
        let b = ed.document.voices[1].id
        let moving = ed.document.notes.indices.filter { ed.document.notes[$0].voiceID == b }
        ed.perform(ed.document.voicesCommand(ed.document.voices.filter { $0.id != b }, name: "Delete", reassign: moving.map { ($0, ed.document.voices[0].id) }))
        XCTAssertEqual(ed.document.voices.count, 1)
        XCTAssertEqual(ed.document.counts()[1], 4)
        ed.undo()
        XCTAssertEqual(ed.document.voices.count, 2)
        XCTAssertEqual(ed.document.counts()[b], 2)
    }

    func testCoalescedRenameIsOneUndoStep() throws {
        var ed = Editor(document: try doc { b, t in b.note(t, pitch: 60, tick: 0, duration: 10) })
        for name in ["S", "So", "Sop"] {
            var vs = ed.document.voices; vs[0].name = name
            ed.perform(ed.document.voicesCommand(vs, name: "Rename", coalesceKey: "name-1"))
        }
        XCTAssertEqual(ed.undoStack.count, 1)
        ed.undo()
        XCTAssertEqual(ed.document.voices[0].name, "A")
    }

    func testMuteSoloAreNotUndone() throws {
        var ed = Editor(document: try doc { b, t in b.note(t, pitch: 60, tick: 0, duration: 10) })
        var vs = ed.document.voices; vs[0].pan = -50
        ed.perform(ed.document.voicesCommand(vs, name: "Pan"))
        ed.setPlaybackState(voice: 1, muted: true)
        ed.undo()
        XCTAssertEqual(ed.document.voices[0].pan, 0)
        XCTAssertTrue(ed.document.voices[0].isMuted)
    }

    // MARK: Exportación

    func testExportPerVoiceFilesChannelsAndNormalize() throws {
        let d0 = try doc { b, t in
            b.cc(t, 64, 127, tick: 1920)
            b.chord(t, pitches: [48, 52, 55, 60, 64], tick: 1920 + 480, duration: 480)
        }
        var d = d0
        let idx = Array(d.notes.indices)
        d.apply(d.assignCommand(pairs: zip(idx, split(d)).map { ($0, d.voices[$1].id) }, name: "s")!)
        var vs = d.voices; vs[0].pan = -100; vs[1].pan = 100
        d.apply(d.voicesCommand(vs, name: "pan")!)

        XCTAssertEqual(Exporter.filename(base: "coros", voice: d.voices[0]), "coros_A.mid")
        XCTAssertEqual(Exporter.filename(base: "coros", voice: d.voices[1]), "coros_B.mid")

        var o = ExportOptions()
        let a = try MIDIParser.parse(data: Exporter.voiceFile(d, voice: d.voices[0], options: o))
        XCTAssertEqual(a.tracks.count, 2)
        XCTAssertEqual(a.tracks[1].name, "A")
        XCTAssertEqual(a.notes.count, 3)
        XCTAssertEqual(a.notes.map(\.startTick).min(), 1920 + 480, "posición absoluta por defecto")
        XCTAssertEqual(a.events.filter(\.isChannelEvent).count, 1, "el sustain se copia a cada voz")

        o.channelMode = .perVoice; o.normalizeStart = true; o.copyNonNoteEvents = false
        let bFile = try MIDIParser.parse(data: Exporter.voiceFile(d, voice: d.voices[1], options: o))
        XCTAssertEqual(bFile.notes.count, 2)
        XCTAssertTrue(bFile.notes.allSatisfy { $0.channel == 1 })
        XCTAssertEqual(bFile.notes.map(\.startTick).min(), 480, "normalizado al compás de la primera nota")
        XCTAssertFalse(bFile.events.contains(where: \.isChannelEvent))
        XCTAssertNotNil(bFile.events.first { $0.tempoMicroseconds != nil })

        let multi = try MIDIParser.parse(data: Exporter.multitrackFile(d, options: ExportOptions(), title: "coros"))
        XCTAssertEqual(multi.tracks.map(\.name), ["coros", "A", "B"])
        XCTAssertEqual(multi.notes.count, 5)
    }

    func testUnassignedNotesOption() throws {
        var d = try doc { b, t in b.chord(t, pitches: [48, 52, 55], tick: 0, duration: 480) }
        d.apply(d.assignCommand([0], to: 1, name: "one")!)
        var o = ExportOptions()
        XCTAssertEqual(try MIDIParser.parse(data: Exporter.voiceFile(d, voice: d.voices[0], options: o)).notes.count, 1)
        o.unassigned = .toVoice(1)
        XCTAssertEqual(try MIDIParser.parse(data: Exporter.voiceFile(d, voice: d.voices[0], options: o)).notes.count, 3)
    }

    func testTempoMapIsPreservedInExport() throws {
        let data = SampleGenerator.all().first { $0.name == "tempo_and_meter_changes" }!.data
        let seq = try MIDIParser.parse(data: data)
        var d = SplitDocument(sequence: seq)
        d.apply(d.assignCommand(d.notes.indices, to: d.voices[1].id, name: "all")!)
        let out = try MIDIParser.parse(data: Exporter.voiceFile(d, voice: d.voices[1], options: ExportOptions()))
        XCTAssertEqual(out.tempoMap, seq.tempoMap)
    }

    func testSessionStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(root: dir)
        let hash = SessionStore.hash(Data([1, 2, 3]))
        XCTAssertEqual(hash.count, 64)
        let s = SessionState(tracks: [1], voices: Voice.defaults(), assignments: [1, nil, 2], params: SplitParams(), export: ExportOptions(), activeVoice: 2)
        store.save(s, hash: hash)
        XCTAssertEqual(store.load(hash: hash), s)
        var lib = PresetLibrary(); lib.splitPresets.append(SplitPreset(name: "x", params: SplitParams()))
        store.savePresets(lib)
        XCTAssertEqual(store.loadPresets(), lib)
    }

    func testHungarianIsOptimal() {
        let cost: [[Double]] = [[4, 1, 3], [2, 0, 5], [3, 2, 2]]
        let m = Hungarian.solve(cost)
        XCTAssertEqual(m.enumerated().map { cost[$0][$1] }.reduce(0, +), 5)
        XCTAssertEqual(Set(m).count, 3)
    }

    func testVoiceNames() {
        XCTAssertEqual((0..<3).map(Voice.defaultName), ["A", "B", "C"])
        XCTAssertEqual(Voice.defaultName(index: 26), "AA")
        XCTAssertEqual(Voice(id: 1, name: "x", color: Voice.palette[0], pan: 35).panLabel, "R35")
    }
}
