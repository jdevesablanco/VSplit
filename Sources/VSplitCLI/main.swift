import Foundation
import VSplitCore

let usage = """
vsplit — separa un MIDI en voces sin abrir la app.

  vsplit samples <carpeta>                 Genera los MIDIs de prueba
  vsplit info <archivo.mid>                Pistas, notas, acordes, tempo
  vsplit split <archivo.mid> [opciones]    Reparte y exporta un .mid por voz
      --voices N         (2)    --mode alternate|register|voiceLeading|channel|velocity|beat
      --window MS        (35)   --order low|high   --remainder first|last   --continue
      --out <carpeta>    (junto al original)       --normalize   --no-cc
"""

func fail(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print(usage); exit(0) }
args.removeFirst()

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

switch cmd {
case "samples":
    let dir = URL(fileURLWithPath: args.first ?? "Samples")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, data) in SampleGenerator.all() {
        let url = dir.appendingPathComponent(name + ".mid")
        do { try data.write(to: url) } catch { fail("No se pudo escribir \(url.path): \(error.localizedDescription)") }
        print("✓ \(url.path)")
    }

case "info":
    guard let path = args.first else { fail(usage) }
    do {
        let seq = try MIDIParser.parse(url: URL(fileURLWithPath: path))
        let map = seq.tempoMap
        print("Formato \(seq.format), PPQ \(seq.ppq), \(seq.tracks.count) pistas, \(seq.notes.count) notas, tempo inicial \(String(format: "%.2f", map.initialBPM)) BPM")
        for t in seq.tracks { print("  pista \(t.index + 1): \(t.name ?? "—") · \(t.noteCount) notas · canales \(t.channels.map { Int($0) + 1 })") }
        let chords = ChordDetector.chords(notes: seq.notes, indices: Array(seq.notes.indices), windowMs: 35, tempoMap: map)
        print("  acordes (35 ms): \(chords.count); tamaños: \(Dictionary(grouping: chords, by: \.count).mapValues(\.count).sorted { $0.key < $1.key })")
        for w in seq.warnings { print("  ⚠︎ \(w.message)") }
    } catch { fail(error.localizedDescription) }

case "split":
    guard let path = args.first else { fail(usage) }
    let url = URL(fileURLWithPath: path)
    do {
        let seq = try MIDIParser.parse(url: url)
        guard !seq.notes.isEmpty else { fail(MIDIError.empty.localizedDescription) }
        let n = max(1, Int(value("--voices") ?? "2") ?? 2)
        var p = SplitParams()
        if let m = value("--mode") { guard let mode = SplitMode(rawValue: m) else { fail("Modo desconocido: \(m)") }; p.mode = mode }
        if let w = value("--window").flatMap(Double.init) { p.chordWindowMs = w }
        if value("--order") == "high" { p.order = .highToLow }
        if value("--remainder") == "last" { p.remainder = .last }
        p.continuePattern = args.contains("--continue")
        var voices: [Voice] = []
        for i in 0..<n {
            let pan = n == 1 ? 0 : Int((-100 + 200 * Double(i) / Double(n - 1)).rounded())
            voices.append(Voice(id: i + 1, name: Voice.defaultName(index: i), color: Voice.palette[i % 16], pan: pan))
        }
        var doc = SplitDocument(sequence: seq, voices: voices)
        let idx = Array(doc.notes.indices)
        let result = AutoSplitter.assign(notes: doc.notes, indices: idx, voiceCount: n, params: p, tempoMap: doc.tempoMap)
        if let c = doc.assignCommand(pairs: zip(idx, result).map { ($0, voices[$1].id) }, name: "split") { doc.apply(c) }
        var o = ExportOptions()
        o.normalizeStart = args.contains("--normalize")
        o.copyNonNoteEvents = !args.contains("--no-cc")
        let out = value("--out").map { URL(fileURLWithPath: $0) } ?? url.deletingLastPathComponent()
        let counts = doc.counts()
        for u in try Exporter.exportAll(doc, base: url.deletingPathExtension().lastPathComponent, to: out, options: o) {
            print("✓ \(u.path)")
        }
        print(voices.map { "\($0.name): \(counts[$0.id] ?? 0)" }.joined(separator: " · "))
    } catch { fail(error.localizedDescription) }

default:
    print(usage)
}
