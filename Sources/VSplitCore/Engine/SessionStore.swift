import CryptoKit
import Foundation

/// Estado de una sesión, guardado por archivo en `~/Library/Application Support/VSplit/Sessions/<sha256>.json`.
public struct SessionState: Codable, Equatable, Sendable {
    public var version = 1
    public var tracks: [Int]
    public var voices: [Voice]
    /// Voz de cada nota, en el orden canónico de notas.
    public var assignments: [VoiceID?]
    public var params: SplitParams
    public var export: ExportOptions
    public var activeVoice: VoiceID?
    /// Solo si se han dibujado o editado notas: la lista completa (con su voz).
    public var notes: [Note]?

    public init(tracks: [Int], voices: [Voice], assignments: [VoiceID?], params: SplitParams, export: ExportOptions, activeVoice: VoiceID?, notes: [Note]? = nil) {
        self.tracks = tracks; self.voices = voices; self.assignments = assignments; self.params = params; self.export = export; self.activeVoice = activeVoice; self.notes = notes
    }
}

public struct VoicePreset: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var voices: [Voice]
    public init(name: String, voices: [Voice]) { self.name = name; self.voices = voices }
}

public struct SplitPreset: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var params: SplitParams
    public init(name: String, params: SplitParams) { self.name = name; self.params = params }
}

public struct PresetLibrary: Codable, Equatable, Sendable {
    public var voicePresets: [VoicePreset] = []
    public var splitPresets: [SplitPreset] = []
    public init() {}
}

public struct SessionStore: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        if let root { self.root = root }
        else if let env = ProcessInfo.processInfo.environment["VSPLIT_SUPPORT_DIR"] { self.root = URL(fileURLWithPath: env) }
        else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.root = base.appendingPathComponent("VSplit", isDirectory: true)
            // Sesiones de cuando la app se llamaba VoiceSplit.
            let old = base.appendingPathComponent("VoiceSplit", isDirectory: true)
            if !FileManager.default.fileExists(atPath: self.root.path), FileManager.default.fileExists(atPath: old.path) {
                try? FileManager.default.moveItem(at: old, to: self.root)
            }
        }
    }

    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private var sessions: URL { root.appendingPathComponent("Sessions", isDirectory: true) }
    private var presetsURL: URL { root.appendingPathComponent("Presets.json") }

    public func load(hash: String) -> SessionState? {
        guard let data = try? Data(contentsOf: sessions.appendingPathComponent("\(hash).json")) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    public func save(_ s: SessionState, hash: String) {
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: sessions.appendingPathComponent("\(hash).json"), options: .atomic) }
    }

    public func loadPresets() -> PresetLibrary {
        guard let data = try? Data(contentsOf: presetsURL), let lib = try? JSONDecoder().decode(PresetLibrary.self, from: data) else { return PresetLibrary() }
        return lib
    }

    public func savePresets(_ lib: PresetLibrary) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(lib) { try? data.write(to: presetsURL, options: .atomic) }
    }
}
