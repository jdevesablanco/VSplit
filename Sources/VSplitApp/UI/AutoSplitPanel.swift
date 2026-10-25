import SwiftUI
import VSplitCore

extension SplitMode {
    var title: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .fairAlternate: return String(localized: "Alternate")
        case .natural: return String(localized: "Lines")
        case .alternate: return String(localized: "Alternate (strict)")
        case .register: return String(localized: "Register")
        case .voiceLeading: return String(localized: "By melodic contour")
        case .channel: return String(localized: "Channel")
        case .velocity: return String(localized: "By velocity")
        case .beat: return String(localized: "By position in bar")
        }
    }
    var explanation: String {
        switch self {
        case .auto: return String(localized: "Two voices: alternate fairly. Three or more: natural lines (bass, middle voices, top).")
        case .fairAlternate: return String(localized: "Alternates the notes of each chord between the voices, keeping the totals as even as possible and each voice moving as little as possible.")
        case .natural: return String(localized: "Groups by line: the bass stays at the bottom, the top voice on top and the middle voices in between, with the smallest leaps.")
        case .alternate: return String(localized: "Groups notes into chords by attack time, sorts them by pitch and deals them out round-robin (1st → A, 2nd → B, 3rd → A…).")
        case .register: return String(localized: "Fixed pitch bands, one per voice, with the same number of notes in each.")
        case .voiceLeading: return String(localized: "Assigns each note to the voice whose last note is closest, minimising leaps (optimal assignment per chord).")
        case .channel: return String(localized: "Each MIDI channel goes to one voice.")
        case .velocity: return String(localized: "Soft notes to one voice, loud notes to another.")
        case .beat: return String(localized: "Alternates by beat: 1st beat → A, 2nd → B, 3rd → A…")
        }
    }
}

/// Reparto: dos knobs, número de voces y modo. Cualquier cambio se aplica al soltar el knob (se deshace con ⌘Z).
struct SplitSection: View {
    @Bindable var model: AppModel

    /// Posiciones del knob de modo.
    static let modes: [SplitMode] = [.auto, .fairAlternate, .natural, .register, .channel]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Split")
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 0)
                // Empieza en el número detectado; al soltarlo se reparte de nuevo con ese número de voces.
                Knob(value: $model.voiceKnob, range: 1...12, defaultValue: Double(model.detectedVoiceCount), label: "Voices",
                     display: "\(Int(model.voiceKnob))", size: 52, step: 1) { model.setVoiceCount(Int(model.voiceKnob)) }
                    .help("Number of voices. Double-click: back to the \(model.detectedVoiceCount) detected.")
                Spacer(minLength: 0)
                Knob(value: $model.modeKnob, range: 0...Double(Self.modes.count - 1), defaultValue: 0, label: "Mode",
                     display: Self.modes[min(Self.modes.count - 1, max(0, Int(model.modeKnob)))].title, size: 52, step: 1) {
                    model.setMode(Self.modes[min(Self.modes.count - 1, max(0, Int(model.modeKnob)))])
                }
                .help(Text(Self.modes.map { "\($0.title): \($0.explanation)" }.joined(separator: "\n")))
                Spacer(minLength: 0)
            }
        }
        .disabled(!model.hasDocument)
    }
}
