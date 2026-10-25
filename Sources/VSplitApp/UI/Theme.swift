import AppKit
import SwiftUI

/// Estética de plugin: casi negro con grano, un resplandor de color detrás, placas con borde fino y tornillos,
/// rótulos grabados en mayúsculas espaciadas, potenciómetros y botones-píldora.
enum Theme {
    static let bg = Color(hex: 0x07080B)
    static let panel = Color(hex: 0x0D0F14)
    static let plate = Color.black.opacity(0.42)
    static let raised = Color(hex: 0x15181F)
    static let hover = Color(hex: 0x1C2029)
    static let line = Color.white.opacity(0.11)
    static let lineStrong = Color.white.opacity(0.22)
    static let text = Color(hex: 0xE7E9ED)
    static let muted = Color(hex: 0x8D939E)
    static let faint = Color(hex: 0x555B66)
    static let accent = Color(hex: 0xE7E9ED)
    static let red = Color(hex: 0xFF7A2E)          // acento naranja del fondo
    static let blue = Color(hex: 0x4A9BFF)
    static let playhead = NSColor(hex: 0xFF8A3A)

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy).width(.expanded) }
    /// Rotulación de panel (DIN Condensed, como en los plugins de hardware).
    static func din(_ size: CGFloat) -> Font { .custom("DIN Condensed", size: size).weight(.bold) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Fondo

/// Fondo: la imagen de luz azul/naranja (Resources/Background.jpg), oscurecida para que se lea todo encima.
struct AuroraBackground: View {
    static let image: NSImage? = Bundle.main.url(forResource: "Background", withExtension: "jpg").flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        if let img = Self.image {
            GeometryReader { g in
                ZStack {
                    Color.black
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: g.size.width, height: g.size.height).clipped()
                    LinearGradient(colors: [Color.black.opacity(0.25), Color.black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        } else {
            fallback
        }
    }

    private var fallback: some View {
        GeometryReader { g in
            ZStack {
                Theme.bg
                blob(0x2B5BD7, x: 0.12, y: 0.2, r: 0.55, g)
                blob(0xE07B2A, x: 0.85, y: 0.15, r: 0.4, g)
                blob(0xB0122C, x: 0.7, y: 0.95, r: 0.55, g)
                blob(0x1E9E9A, x: 0.3, y: 0.95, r: 0.35, g)
                Color.black.opacity(0.35)
                Grain().opacity(0.07).blendMode(.screen)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func blob(_ hex: UInt32, x: CGFloat, y: CGFloat, r: CGFloat, _ g: GeometryProxy) -> some View {
        let d = max(g.size.width, g.size.height) * r
        return Circle()
            .fill(RadialGradient(colors: [Color(hex: hex, opacity: 0.55), Color(hex: hex, opacity: 0)], center: .center, startRadius: 0, endRadius: d / 2))
            .frame(width: d, height: d)
            .position(x: g.size.width * x, y: g.size.height * y)
    }
}

/// Textura de ruido en mosaico (se genera una vez).
struct Grain: View {
    static let tile: NSImage = {
        let n = 160
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 1,
                                   hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: n, bitsPerPixel: 8)!
        var seed: UInt64 = 0x5EED
        for i in 0..<(n * n) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            rep.bitmapData![i] = UInt8(truncatingIfNeeded: seed >> 56)
        }
        let img = NSImage(size: NSSize(width: n, height: n))
        img.addRepresentation(rep)
        return img
    }()
    var body: some View { Image(nsImage: Self.tile).resizable(resizingMode: .tile) }
}

// MARK: - Placas

/// Placa: fondo oscuro translúcido, borde fino y tornillos en las esquinas.
struct PlateModifier: ViewModifier {
    var radius: CGFloat = 8
    var screws = true
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(Theme.plate))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.line))
            .overlay {
                if screws {
                    GeometryReader { g in
                        ForEach(0..<4, id: \.self) { k in
                            Circle().fill(Color.white.opacity(0.22)).frame(width: 3.5, height: 3.5)
                                .position(x: k % 2 == 0 ? 7 : g.size.width - 7, y: k < 2 ? 7 : g.size.height - 7)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func plate(radius: CGFloat = 8, screws: Bool = true) -> some View { modifier(PlateModifier(radius: radius, screws: screws)) }
}

/// Rótulo grabado: mayúsculas pequeñas muy espaciadas.
struct SectionTitle: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title)
            .font(Theme.din(12.5))
            .kerning(2.6)
            .textCase(.uppercase)
            .foregroundStyle(Theme.text.opacity(0.72))
            .padding(.top, 2)
    }
}

typealias Engraved = SectionTitle

// MARK: - Botones

/// Botón-píldora (como BYPASS / MODULATION): activo = relleno claro con texto oscuro.
struct PillStyle: ButtonStyle {
    var on = false
    var wide = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.din(12.5))
            .kerning(1.8)
            .textCase(.uppercase)
            .padding(.top, 2)
            .foregroundStyle(on ? Color.black : Theme.text.opacity(0.9))
            .padding(.horizontal, wide ? 16 : 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.accent.opacity(configuration.isPressed ? 0.8 : 1) : Color.white.opacity(configuration.isPressed ? 0.08 : 0.02)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Color.clear : Theme.lineStrong))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}

/// Compatibilidad: botones "chip" = píldoras (prominente = activa).
struct ChipStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View { PillStyle(on: prominent).makeBody(configuration: configuration) }
}

/// Botón de icono sin fondo; `on` lo enciende.
struct IconStyle: ButtonStyle {
    var on = false
    var size: CGFloat = 28
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(on ? Theme.text : Theme.muted)
            .frame(width: size, height: size - 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.white.opacity(0.09) : (configuration.isPressed ? Color.white.opacity(0.06) : Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Theme.line : Color.clear))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}

// MARK: - Potenciómetro

/// Knob estilo hardware (como Oracle): marcas alrededor, aro negro moleteado, tapa de metal cepillado y punto blanco.
/// Arrastra en vertical para girarlo, doble clic para el valor por defecto. `step` redondea (p. ej. 1 para enteros).
struct Knob: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var defaultValue: Double
    var label: LocalizedStringKey
    var display: String
    var size: CGFloat = 46
    var step: Double = 0
    var onEnd: () -> Void = {}
    @GestureState private var start: Double?

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, sz in draw(ctx, sz) }
                .frame(width: size, height: size)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($start) { _, s, _ in if s == nil { s = value } }
                        .onChanged { g in
                            let span = range.upperBound - range.lowerBound
                            let moved = Double(g.translation.height - g.translation.width * 0.3)
                            // Con pasos (voces, modo): un paso cada 22 px, para no pasarse.
                            var v = step > 0 ? (start ?? value) - (moved / 22).rounded() * step : (start ?? value) - moved * span / 180
                            if step > 0 { v = (v / step).rounded() * step }
                            value = min(range.upperBound, max(range.lowerBound, v))
                        }
                        .onEnded { _ in onEnd() }
                )
                .onTapGesture(count: 2) { value = defaultValue; onEnd() }
                .accessibilityElement()
                .accessibilityLabel(Text(label))
                .accessibilityValue(Text(display))
                .accessibilityAdjustableAction { dir in
                    let st = step > 0 ? step : (range.upperBound - range.lowerBound) / 40
                    value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? st : -st)))
                    onEnd()
                }
            Text(display).font(Theme.din(13)).padding(.top, 2).foregroundStyle(Theme.text.opacity(0.9))
            Engraved(title: label)
        }
    }

    private func draw(_ ctx: GraphicsContext, _ sz: CGSize) {
        let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
        let R = min(sz.width, sz.height) / 2
        // Marcas (270°) y la actual más clara.
        let ticks = 11
        for k in 0..<ticks {
            let f = Double(k) / Double(ticks - 1)
            let a = Angle.degrees(135 + 270 * f).radians
            var p = Path()
            p.move(to: CGPoint(x: c.x + cos(a) * R * 0.86, y: c.y + sin(a) * R * 0.86))
            p.addLine(to: CGPoint(x: c.x + cos(a) * R * 0.99, y: c.y + sin(a) * R * 0.99))
            ctx.stroke(p, with: .color(.white.opacity(f <= fraction + 0.001 ? 0.55 : 0.18)), lineWidth: 1.3)
        }
        // Aro negro moleteado.
        let ring = R * 0.8
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - ring, y: c.y - ring + 1.5, width: ring * 2, height: ring * 2)), with: .color(.black.opacity(0.6)))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2)),
                 with: .radialGradient(Gradient(colors: [Color(hex: 0x2B2D31), Color(hex: 0x050506)]), center: CGPoint(x: c.x - ring * 0.3, y: c.y - ring * 0.4), startRadius: 0, endRadius: ring * 1.3))
        for k in 0..<36 {
            let a = Double(k) / 36 * 2 * .pi
            var p = Path()
            p.move(to: CGPoint(x: c.x + cos(a) * ring * 0.86, y: c.y + sin(a) * ring * 0.86))
            p.addLine(to: CGPoint(x: c.x + cos(a) * ring * 0.99, y: c.y + sin(a) * ring * 0.99))
            ctx.stroke(p, with: .color(.white.opacity(k % 2 == 0 ? 0.10 : 0.03)), lineWidth: 1)
        }
        // Tapa de metal cepillado (degradado cónico) con brillo arriba a la izquierda.
        let cap = ring * 0.66
        let capRect = CGRect(x: c.x - cap, y: c.y - cap, width: cap * 2, height: cap * 2)
        let metal = Gradient(colors: [Color(hex: 0xF4F4F4), Color(hex: 0x8E9095), Color(hex: 0xE6E6E6), Color(hex: 0x6B6D72), Color(hex: 0xF0F0F0), Color(hex: 0x8A8C90), Color(hex: 0xF4F4F4)])
        ctx.fill(Path(ellipseIn: capRect), with: .conicGradient(metal, center: c, angle: .degrees(-20)))
        ctx.fill(Path(ellipseIn: capRect), with: .radialGradient(Gradient(colors: [.white.opacity(0.35), .clear]), center: CGPoint(x: c.x - cap * 0.35, y: c.y - cap * 0.45), startRadius: 0, endRadius: cap))
        ctx.stroke(Path(ellipseIn: capRect), with: .color(.black.opacity(0.5)), lineWidth: 0.8)
        // Punto indicador en el aro.
        let a = Angle.degrees(135 + 270 * fraction).radians
        let dot = CGPoint(x: c.x + cos(a) * ring * 0.79, y: c.y + sin(a) * ring * 0.79)
        ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 2, y: dot.y - 2, width: 4, height: 4)), with: .color(.white))
    }
}

/// Zona que arrastra la ventana (la barra de título está oculta).
struct WindowDragArea: NSViewRepresentable {
    final class V: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
