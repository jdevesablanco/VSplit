import SwiftUI
import VSplitCore

/// Un clip que acaba de llegar (carpeta, pegar o archivo): se presenta un momento antes de mostrar el editor.
struct Arrival: Identifiable {
    enum Source { case folder, paste, file }
    struct Bar { var x: CGFloat; var w: CGFloat; var y: CGFloat; var color: Color }

    let id = UUID()
    let source: Source
    let name: String
    let bars: [Bar]
    let noteCount: Int
    let voiceCount: Int
    let originBar: Int?

    init(source: Source, document d: SplitDocument, name: String, originBar: Int?) {
        self.source = source
        self.name = name
        self.originBar = originBar
        noteCount = d.notes.count
        voiceCount = d.voices.count
        let end = CGFloat(max(1, d.notes.map(\.endTick).max() ?? 1))
        let lo = Int(d.notes.map(\.pitch).min() ?? 60), hi = Int(d.notes.map(\.pitch).max() ?? 72)
        let range = CGFloat(max(1, hi - lo))
        // Como mucho ~220 barras: el dibujo es un resumen, no el clip entero.
        let stride = max(1, d.notes.count / 220)
        bars = Swift.stride(from: 0, to: d.notes.count, by: stride).map { i in
            let n = d.notes[i]
            return Bar(x: CGFloat(n.startTick) / end, w: max(0.004, CGFloat(n.durationTick) / end),
                       y: 1 - CGFloat(Int(n.pitch) - lo) / range,
                       color: n.voiceID.flatMap { d.voice($0)?.color.color } ?? Theme.muted)
        }
    }

    var label: String {
        switch source {
        case .folder: return String(localized: "New MIDI in Documents › VSplit")
        case .paste: return String(localized: "Pasted from Logic")
        case .file: return String(localized: "MIDI file")
        }
    }
}

/// La llegada: rótulo, nombre y un mini piano roll que aparece en gris y se reparte en los colores de las voces.
struct ArrivalOverlay: View {
    let arrival: Arrival
    let done: () -> Void
    @State private var start = Date()
    @State private var shown = false

    // Tiempos (s): las notas aparecen con el cabezal, luego se colorean por voces y al final se abre el editor.
    private let reveal = 0.15...0.85
    private let color = 0.9...1.35
    private let total = 2.0

    var body: some View {
        ZStack {
            AuroraBackground()
            Color.black.opacity(0.25)
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    PulseDot()
                    Text(arrival.label.uppercased()).font(Theme.din(13)).kerning(2).foregroundStyle(Theme.muted)
                }
                Text(arrival.name).font(Theme.display(22)).kerning(1).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 440)
                TimelineView(.animation) { tl in
                    let t = tl.date.timeIntervalSince(start)
                    VStack(spacing: 14) {
                        roll(t).frame(width: 420, height: 120)
                            .padding(12)
                            .plate(radius: 10)
                        stats.opacity(ease(t, 1.2...1.5)).offset(y: 4 * (1 - ease(t, 1.2...1.5)))
                    }
                }
            }
            .padding(.bottom, 20)
            .scaleEffect(shown ? 1 : 0.97)
            .opacity(shown ? 1 : 0)
        }
        .ignoresSafeArea()
        .foregroundStyle(Theme.text)
        .contentShape(Rectangle())
        .onTapGesture { done() }
        .onAppear {
            start = Date()
            withAnimation(.easeOut(duration: 0.25)) { shown = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + total) { done() }
        }
    }

    private var stats: some View {
        HStack(spacing: 10) {
            Text("\(arrival.noteCount) notes · \(arrival.voiceCount) voices")
            if let bar = arrival.originBar, bar > 1 {
                Text("·").foregroundStyle(Theme.faint)
                Text("from bar \(bar)")
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(Theme.muted)
    }

    private func roll(_ t: Double) -> some View {
        let head = ease(t, reveal)
        let tint = ease(t, color)
        return Canvas { ctx, size in
            // Rejilla de compases muy tenue.
            for i in 1..<8 {
                let x = size.width * CGFloat(i) / 8
                ctx.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(.white.opacity(0.06)))
            }
            let h: CGFloat = max(3, min(7, size.height / 22))
            for b in arrival.bars where b.x <= head {
                let rect = CGRect(x: b.x * size.width, y: b.y * (size.height - h), width: max(3, b.w * size.width - 1), height: h)
                // Cada nota se colorea cuando el barrido de color pasa por ella (de izquierda a derecha).
                let mine = min(1, max(0, (tint * 1.3 - b.x * 0.3)))
                let path = Path(roundedRect: rect, cornerRadius: 1.5)
                ctx.fill(path, with: .color(Color(hex: 0x8B93A3).opacity(0.75 * (1 - mine))))
                if mine > 0 { ctx.fill(path, with: .color(b.color.opacity(mine))) }
            }
            if head < 1 {
                let x = head * size.width
                ctx.fill(Path(CGRect(x: x - 0.75, y: -4, width: 1.5, height: size.height + 8)), with: .color(Color(nsColor: Theme.playhead)))
                var glow = ctx
                glow.addFilter(.blur(radius: 6))
                glow.fill(Path(CGRect(x: x - 2, y: 0, width: 4, height: size.height)), with: .color(Color(nsColor: Theme.playhead).opacity(0.6)))
            }
        }
    }

    private func ease(_ t: Double, _ r: ClosedRange<Double>) -> CGFloat {
        let p = min(1, max(0, (t - r.lowerBound) / (r.upperBound - r.lowerBound)))
        return CGFloat(1 - pow(1 - p, 3))
    }
}

/// Punto naranja que late, como el piloto de una máquina.
private struct PulseDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Theme.red).frame(width: 7, height: 7)
            .shadow(color: Theme.red.opacity(on ? 0.9 : 0.2), radius: on ? 6 : 2)
            .opacity(on ? 1 : 0.55)
            .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { on = true } }
    }
}
