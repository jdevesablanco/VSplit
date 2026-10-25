import XCTest
@testable import VSplitCore

final class LogicClipboardTests: XCTestCase {
    /// Texto real copiado en Logic Pro (Piano Roll, ⌘A ⌘C) de la voz A que VSplit exportó de chords_3_to_8.mid.
    var fixture: String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/logic_notes_copy.txt")
        return try! String(contentsOf: url, encoding: .utf8)
    }

    func testRealLogicCopyMatchesTheExportedVoice() throws {
        XCTAssertEqual(LogicClipboard.classify(fixture), .notes)
        let seq = try LogicClipboard.parse(fixture)
        XCTAssertEqual(seq.ppq, 960)

        // Lo que se arrastró a Logic: la voz A del reparto por defecto (480 PPQ → Logic lo muestra a 960).
        let data = SampleGenerator.all().first { $0.name == "chords_3_to_8" }!.data
        var doc = SplitDocument(sequence: try MIDIParser.parse(data: data))
        let idx = Array(doc.notes.indices)
        let r = AutoSplitter.assign(notes: doc.notes, indices: idx, voiceCount: 2, params: EngineTests.alternate, tempoMap: doc.tempoMap)
        doc.apply(doc.assignCommand(pairs: zip(idx, r).map { ($0, doc.voices[$1].id) }, name: "s")!)
        let a = doc.notes.filter { $0.voiceID == doc.voices[0].id }

        XCTAssertEqual(seq.notes.count, a.count)
        func key(_ n: Note, _ k: Int) -> [Int] { [n.startTick * k, n.durationTick * k, Int(n.pitch), Int(n.velocity)] }
        XCTAssertEqual(seq.notes.map { key($0, 1) }, a.map { key($0, 2) })
        XCTAssertEqual(seq.tempoMap.meter(atTick: 0).numerator, 4)
    }

    func testTrimmedStartsAtFirstNoteBar() throws {
        let text = """
         \t  \t 25 2 1 1 \t Note\t 1\t C3\t 80\t 0 1 0 0\t
         \t  \t 26 1 1 1 \t Note\t 1\t E3\t 80\t 0 1 0 0\t
        """
        let seq = try LogicClipboard.parse(text)
        XCTAssertEqual(seq.notes.first?.startTick, 24 * 3840 + 960)
        let (t, bar) = LogicClipboard.trimmed(seq)
        XCTAssertEqual(bar, 25)
        XCTAssertEqual(t.notes.map(\.startTick), [960, 3840], "empieza en el compás 1 conservando su posición dentro del compás")
        XCTAssertEqual(t.tempoMap.initialBPM, 120, accuracy: 0.01)
    }

    func testRegionCopyIsDetected() {
        let region = " \t  \t 1 1 1 1 \t A\t 2\t 7 0 0 0"
        XCTAssertEqual(LogicClipboard.classify(region), .regionSummary)
        XCTAssertEqual(LogicClipboard.classify("hola"), .other)
        XCTAssertThrowsError(try LogicClipboard.parse(region))
    }

    func testMeterDivisionAndControllers() throws {
        let text = """
         \t  \t 1 1 1 1 \t Control\t 1\t 64\t 127\t
         \t  \t 2 3 1 1 \t Note\t 2\t C#3\t 100\t 0 1 0 0\t
        \t\t\t Rel Vel\t\t\t 30\t\t
         \t  \t 3 1 2 120 \t Note\t 2\t Bb-1\t 50\t 1 0 0 0\t
        """
        // 3/4 indicado a mano: compás = 2880 ticks.
        let seq = try LogicClipboard.parse(text, options: .init(numerator: 3))
        XCTAssertEqual(seq.notes.map(\.startTick), [2880 + 1920, 5760 + 240 + 119])
        XCTAssertEqual(seq.notes.map(\.pitch), [61, 22])
        XCTAssertEqual(seq.notes.map(\.durationTick), [960, 2880])
        XCTAssertEqual(seq.notes[0].releaseVelocity, 30)
        XCTAssertEqual(seq.notes[0].channel, 1)
        XCTAssertEqual(seq.events.filter(\.isChannelEvent).count, 1)
        XCTAssertEqual(seq.tempoMap.meter(atTick: 0).numerator, 3)
        // Sin indicarlo se asume 4/4.
        XCTAssertEqual(try LogicClipboard.parse(text).notes[0].startTick, 3840 + 1920)
    }

    func testPitchNames() {
        XCTAssertEqual(LogicClipboard.pitch("C3"), 60)
        XCTAssertEqual(LogicClipboard.pitch("C4", middleCOctave: 4), 60)
        XCTAssertEqual(LogicClipboard.pitch("C-2"), 0)
        XCTAssertEqual(LogicClipboard.pitch("G8"), 127)
        XCTAssertEqual(LogicClipboard.pitch("F♯2"), 54)
        XCTAssertNil(LogicClipboard.pitch("H3"))
    }
}
