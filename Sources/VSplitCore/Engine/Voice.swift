import Foundation

public struct RGBAColor: Hashable, Codable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init(hex: UInt32) { self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255) }
}

public struct Voice: Identifiable, Hashable, Codable, Sendable {
    public var id: VoiceID
    public var name: String
    public var color: RGBAColor
    public var pan: Int          // −100 … +100
    public var isMuted: Bool
    public var isSolo: Bool

    public init(id: VoiceID, name: String, color: RGBAColor, pan: Int = 0, isMuted: Bool = false, isSolo: Bool = false) {
        self.id = id; self.name = name; self.color = color; self.pan = max(-100, min(100, pan)); self.isMuted = isMuted; self.isSolo = isSolo
    }

    /// "L100", "R35", "C".
    public var panLabel: String { pan == 0 ? "C" : (pan < 0 ? "L\(-pan)" : "R\(pan)") }

    /// Paleta por defecto: 16 tonos distinguibles sobre fondo oscuro (ordenados para que los vecinos contrasten).
    public static let palette: [RGBAColor] = [
        0x4A9BFF, 0xFF8C38, 0x9FD0FF, 0xFFC35C, 0x3A63E8, 0xFF6A4A, 0x5ED1E6, 0xFFE0B5,
        0x8A8CFF, 0xE8642A, 0xC4E4FF, 0xF2A65A, 0x2E8FD6, 0xFFAE8C, 0x6FA8FF, 0xD98A3D,
    ].map { RGBAColor(hex: $0) }

    /// A, B, … Z, AA, AB…
    public static func defaultName(index: Int) -> String {
        var i = index, s = ""
        repeat { s = String(UnicodeScalar(UInt8(65 + i % 26))) + s; i = i / 26 - 1 } while i >= 0
        return s
    }

    public static func defaults() -> [Voice] {
        [Voice(id: 1, name: "A", color: palette[0], pan: -100), Voice(id: 2, name: "B", color: palette[1], pan: 100)]
    }
}
