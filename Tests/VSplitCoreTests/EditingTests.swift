import XCTest
@testable import VSplitCore

final class EditingTests: XCTestCase {
    func doc() throws -> SplitDocument {
        var b = SampleGenerator.Builder()
        let t = b.addTrack(name: "t")
        b.chord(t, pitches: [48, 55, 60, 64], tick: 0, duration: 480)
        b.chord(t, pitches: [50, 57, 62, 65], tick: 480, duration: 480)
        var d = SplitDocument(sequence: try MIDIParser.parse(data: b.data()), voices: NaturalVoices.defaultVoices(count: 4))
        let idx = Array(d.notes.indices)
        let r = AutoSplitter.assign(notes: d.notes, indices: idx, voiceCount: 4, params: SplitParams(), tempoMap: d.tempoMap)
        d.apply(d.assignCommand(pairs: zip(idx, r).map { ($0, d.voices[$1].id) }, name: "s")!)
        return d
    }

    func testJoinVoicesMovesNotesAndUndoes() throws {
        var ed = Editor(document: try doc())
        let alto = ed.document.voices[1].id, tenor = ed.document.voices[2].id
        XCTAssertTrue(ed.perform(ed.document.joinCommand([tenor, alto], name: "Join")))
        XCTAssertEqual(ed.document.voices.map(\.name), ["Soprano", "Alto", "Bass"])
        XCTAssertEqual(ed.document.counts()[alto], 4)
        XCTAssertNil(ed.document.counts()[tenor])
        ed.undo()
        XCTAssertEqual(ed.document.voices.count, 4)
        XCTAssertEqual(ed.document.counts()[tenor], 2)
        XCTAssertNil(ed.document.joinCommand([alto], name: "Join"), "hacen falta dos voces")
    }

    func testDrawResizeAndDeleteNotesAreUndoable() throws {
        var ed = Editor(document: try doc())
        let original = ed.document.notes
        let sop = ed.document.voices[0].id
        // Dibujar una nota nueva en medio: se ordena y renumera.
        var n = ed.document.notes
        n.append(Note(id: -1, pitch: 72, velocity: 90, startTick: 240, durationTick: 120, voiceID: sop))
        XCTAssertTrue(ed.perform(ed.document.notesCommand(n, name: "Draw")))
        XCTAssertEqual(ed.document.notes.count, 9)
        XCTAssertEqual(ed.document.notes.map(\.id), Array(0..<9))
        XCTAssertEqual(ed.document.notes.first { $0.pitch == 72 }?.voiceID, sop)
        XCTAssertTrue(ed.document.notesEdited)
        // Alargar la primera nota y borrar otra.
        n = ed.document.notes
        n[0].durationTick = 960
        n.remove(at: 3)
        XCTAssertTrue(ed.perform(ed.document.notesCommand(n, name: "Edit")))
        XCTAssertEqual(ed.document.notes.count, 8)
        XCTAssertEqual(ed.document.maxDuration, 960)
        XCTAssertNotNil(ed.document.indices(fromTick: 900, toTick: 950).first, "búsqueda por rango con la nueva duración")
        ed.undo(); ed.undo()
        XCTAssertEqual(ed.document.notes, original)
        ed.redo()
        XCTAssertEqual(ed.document.notes.count, 9)
        // Sin cambios no hay comando.
        XCTAssertNil(ed.document.notesCommand(ed.document.notes, name: "noop"))
    }

    func testSessionKeepsEditedNotes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var d = try doc()
        var n = d.notes; n.append(Note(id: 0, pitch: 80, velocity: 70, startTick: 0, durationTick: 60, voiceID: d.voices[0].id))
        d.apply(d.notesCommand(n, name: "Draw")!)
        let store = SessionStore(root: dir)
        store.save(SessionState(tracks: [1], voices: d.voices, assignments: d.notes.map(\.voiceID), params: SplitParams(), export: ExportOptions(), activeVoice: nil, notes: d.notes), hash: "x")
        let s = try XCTUnwrap(store.load(hash: "x"))
        var fresh = try doc()
        fresh.restore(notes: s.notes!, voices: s.voices)
        XCTAssertEqual(fresh.notes, d.notes)
    }

    func testSmartSnap() {
        // 480 ticks por negra; zoom alto → 1/16 (120), medio → 1/8, bajo → negra, muy bajo → compás.
        XCTAssertEqual(Snap.gridUnit(pxPerTick: 0.5, beatTicks: 480, barTicks: 1920), 120)
        XCTAssertEqual(Snap.gridUnit(pxPerTick: 0.3, beatTicks: 480, barTicks: 1920), 240)
        XCTAssertEqual(Snap.gridUnit(pxPerTick: 0.1, beatTicks: 480, barTicks: 1920), 480)
        XCTAssertEqual(Snap.gridUnit(pxPerTick: 0.01, beatTicks: 480, barTicks: 1920), 1920)
        XCTAssertEqual(Snap.snap(500, unit: 480), 480)
        XCTAssertEqual(Snap.snap(730, unit: 480), 960)
        XCTAssertEqual(Snap.snap(500, unit: 480, magnets: [515], tolerance: 20), 515, "el borde de otra nota gana si está cerca")
        XCTAssertEqual(Snap.snap(500, unit: 480, magnets: [600], tolerance: 20), 480)
        XCTAssertEqual(Snap.floor(470, unit: 120), 360)
        XCTAssertEqual(Snap.snap(1000, unit: 1), 1000)
    }
}
