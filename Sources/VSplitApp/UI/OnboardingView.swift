import AppKit
import Combine
import SwiftUI
import VSplitCore

/// Idioma del tutorial (ES/EN). Al terminar, si se eligió otro que el del sistema, la app entera se pone en ese idioma.
enum OnbLang: String { case es, en
    static var system: OnbLang { (Locale.preferredLanguages.first ?? "en").hasPrefix("es") ? .es : .en }
}

/// Tutorial de primer uso: cuatro pasos sencillos, con los permisos dentro.
struct OnboardingView: View {
    @Bindable var model: AppModel
    private var step: Int { model.onboardingStep }
    @State private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let steps = 4

    private func tr(_ es: String, _ en: String) -> String { model.onboardingLang == .es ? es : en }

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    LangSwitch(lang: $model.onboardingLang)
                }
                .padding(.trailing, 22)   // mismo margen que el botón de Siguiente abajo
                .padding(.top, 16)
                .background(WindowDragArea())

                Group {
                    switch step {
                    case 0: welcome
                    case 1: bring
                    case 2: split
                    default: back
                    }
                }
                .frame(maxWidth: 700, maxHeight: .infinity)
                .padding(.horizontal, 28)
                .id(step)
                .transition(.opacity)

                footer
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Theme.text)
        .onReceive(timer) { _ in tick += 1 }   // refresca el estado de los permisos
    }

    // MARK: Pasos

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Text("VSPLIT").font(Theme.display(46)).kerning(3)
            Text(tr("Cada voz, por su lado.", "Voices, set apart.")).font(.system(size: 16)).foregroundStyle(Theme.text.opacity(0.85))
            SplitIllustration().frame(height: 120).padding(.vertical, 6)
            Text(tr("Pegas un clip MIDI de Logic, VSplit lo reparte en voces (bajo, voces de en medio, arriba… o alternando) y arrastras cada voz de vuelta a Logic, una pista por voz.",
                    "Paste a MIDI clip from Logic, VSplit splits it into voices (bass, inner voices, top… or alternating) and you drag each voice back into Logic, one track per voice."))
                .font(.system(size: 13)).multilineTextAlignment(.center).foregroundStyle(Theme.text.opacity(0.8))
                .frame(maxWidth: 520)
            Spacer(minLength: 0)
        }
    }

    private var bring: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 0)
            title(tr("1 · Trae el MIDI de Logic", "1 · Bring the MIDI from Logic"))
            Text(tr("Tres formas, elige una:", "Three ways, pick one:")).font(.system(size: 12.5)).foregroundStyle(Theme.text.opacity(0.8))
            HStack(alignment: .top, spacing: 12) {
                way("doc.on.clipboard", tr("Copiar y pegar", "Copy and paste"), tr("En el Piano Roll de Logic: ⌘A ⌘C. Aquí: ⌘V.", "In Logic's Piano Roll: ⌘A ⌘C. Here: ⌘V."), letter: "A")
                way("folder", tr("Exportar a una carpeta", "Export to a folder"), tr("Archivo › Exportar › Selección como archivo MIDI… en Documentos › VSplit. Se abre solo.", "File › Export › Selection as MIDI File… into Documents › VSplit. It opens by itself."), letter: "B")
                way("arrow.down.doc", tr("Soltar un .mid", "Drop a .mid"), tr("Arrástralo a la ventana o ábrelo con ⌘O.", "Drag it onto the window or open it with ⌘O."), letter: "C")
            }
            .fixedSize(horizontal: false, vertical: true)
            Engraved(title: LocalizedStringKey(tr("Permisos", "Permissions")))
                .padding(.top, 4)
            let _ = tick
            PermissionRow(icon: "metronome", title: tr("Leer tempo y compás de Logic", "Read Logic's tempo and meter"),
                          detail: tr("Accesibilidad. Así al pegar el clip llega con el tempo y el compás de tu proyecto.", "Accessibility. Pasted clips then get your project's tempo and meter."),
                          granted: Permissions.accessibility, button: tr("Dar permiso", "Allow")) { Permissions.requestAccessibility() }
            PermissionRow(icon: "folder", title: tr("Carpeta Documentos › VSplit", "Documents › VSplit folder"),
                          detail: tr("Para ver los MIDI que exportes desde Logic.", "To see the MIDI files you export from Logic."),
                          granted: Permissions.documents, button: tr("Dar acceso", "Allow")) { Permissions.requestDocuments() }
            PermissionRow(icon: "bolt", title: tr("Abrir VSplit al exportar desde Logic (opcional)", "Open VSplit when you export from Logic (optional)"),
                          detail: tr("Aunque VSplit esté cerrado: aparece encima de Logic con el archivo.", "Even if VSplit is closed: it appears over Logic with the file."),
                          granted: model.autoOpenFromFolder, button: tr("Activar", "Turn on")) { model.autoOpenFromFolder = true }
            Spacer(minLength: 0)
        }
    }

    private var split: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            title(tr("2 · Repártelo en voces", "2 · Split it into voices"))
            HStack(alignment: .top, spacing: 26) {
                Knob(value: .constant(4), range: 1...12, defaultValue: 4, label: LocalizedStringKey(tr("Voces", "Voices")), display: "4", size: 50, step: 1)
                    .allowsHitTesting(false)
                Knob(value: .constant(0), range: 0...4, defaultValue: 0, label: LocalizedStringKey(tr("Modo", "Mode")), display: "Auto", size: 50, step: 1)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("VOCES empieza en las que detecta. MODO: Auto (2 voces alternan de forma justa; 3 o más, por líneas: bajo, en medio, arriba), Alternar, Líneas, Registro, Canal.",
                            "VOICES starts at the number detected. MODE: Auto (2 voices alternate fairly; 3 or more split by lines: bass, middle, top), Alternate, Lines, Register, Channel."))
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                toolTip(.brush, tr("Pintar: todo lo que tocas pasa a la voz elegida (1–9)", "Paint: everything you touch goes to the chosen voice (1–9)"))
                toolTip(.draw, tr("Dibujar notas y alargarlas, con ajuste a la rejilla", "Draw notes and change their length, snapped to the grid"))
                toolTip(.select, tr("Seleccionar, con los atajos de Logic: ⌘A, ⌥↑↓, ⇧⌥↑↓, ⌥←→, Q, ⌫", "Select, with Logic's shortcuts: ⌘A, ⌥↑↓, ⇧⌥↑↓, ⌥←→, Q, ⌫"))
            }
            Spacer(minLength: 0)
        }
    }

    private var back: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            title(tr("3 · Devuélvelo a Logic", "3 · Send it back to Logic"))
            HStack(alignment: .top, spacing: 12) {
                way("arrow.up.doc", tr("Una voz", "One voice"), tr("Arrastra el icono de la voz a Logic: una región en el compás donde la sueltes.", "Drag a voice's icon into Logic: one region at the bar where you drop it."))
                way("square.stack.3d.up", tr("Todas", "All of them"), tr("El icono de arriba a la derecha crea una pista por voz.", "The icon at the top right makes one track per voice."))
                way("eye.slash", tr("Se aparta", "Gets out of the way"), tr("Al sacar el arrastre VSplit se oculta para ver Logic, y vuelve al soltar.", "Dragging out hides VSplit so you see Logic; it comes back when you drop."))
            }
            .fixedSize(horizontal: false, vertical: true)
            Text(tr("Suelta las voces en el compás que indica VSplit (el del clip original) y caerán en su sitio.",
                    "Drop the voices at the bar VSplit shows (where the original clip was) and they land in place."))
                .font(.system(size: 12.5)).foregroundStyle(Theme.text.opacity(0.8))
            Toggle(isOn: $model.keepAbove) {
                Text(tr("Mantener VSplit encima de Logic (también a pantalla completa)", "Keep VSplit above Logic (even in full screen)")).font(.system(size: 12.5))
            }
            .toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
            Spacer(minLength: 0)
        }
    }

    // MARK: Piezas

    private var footer: some View {
        HStack {
            if step > 0 {
                Button(tr("Atrás", "Back")) { withAnimation(.easeOut(duration: 0.2)) { model.onboardingStep -= 1 } }.buttonStyle(PillStyle())
            } else {
                Button(tr("Saltar", "Skip")) { model.finishOnboarding() }.buttonStyle(PillStyle())
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<steps, id: \.self) { i in
                    Capsule().fill(i == step ? Theme.text : Theme.text.opacity(0.25)).frame(width: i == step ? 16 : 6, height: 6)
                }
            }
            Spacer()
            if step < steps - 1 {
                let _ = tick
                let blocked = step == 1 && !(Permissions.accessibility && Permissions.documents)
                Button(tr("Siguiente", "Next")) { withAnimation(.easeOut(duration: 0.2)) { model.onboardingStep += 1 } }
                    .buttonStyle(PillStyle(on: true, wide: true))
                    .disabled(blocked)
                    .opacity(blocked ? 0.4 : 1)
                    .help(blocked ? tr("Da los permisos para seguir", "Allow the permissions to continue") : "")
            } else {
                Button(tr("Empezar", "Start")) { model.finishOnboarding() }.buttonStyle(PillStyle(on: true, wide: true))
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 58)
    }

    private func title(_ s: String) -> some View {
        Text(s.uppercased()).font(Theme.din(24)).kerning(2.5).padding(.top, 4)
    }

    private func way(_ symbol: String, _ title: String, _ detail: String, letter: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: symbol).font(.system(size: 17, weight: .light)).frame(width: 38, height: 38).plate(radius: 8, screws: false)
                Spacer()
                if let letter { Text(letter).font(Theme.display(26)).foregroundStyle(Theme.text.opacity(0.35)).padding(.trailing, 4) }
            }
            Text(title.uppercased()).font(Theme.din(13.5)).kerning(1.6).padding(.top, 2)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.text.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .plate(radius: 8)
    }

    private func toolTip(_ tool: Tool, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tool.symbol).font(.system(size: 13)).frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.lineStrong))
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.text.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Una fila de permiso: icono, explicación y botón (o ✓ si ya está concedido).
struct PermissionRow: View {
    let icon: String, title: String, detail: String
    let granted: Bool
    let button: String
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 14)).frame(width: 30, height: 30).plate(radius: 7, screws: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.text.opacity(0.7)).lineLimit(2)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(Color(hex: 0x6FD38A))
            } else {
                Button(button, action: action).buttonStyle(PillStyle())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .plate(radius: 8, screws: false)
    }
}

/// Selector ES / EN (arriba a la derecha, como en las otras apps).
struct LangSwitch: View {
    @Binding var lang: OnbLang
    var body: some View {
        HStack(spacing: 0) {
            ForEach([OnbLang.es, .en], id: \.self) { l in
                Button { lang = l } label: {
                    Text(l.rawValue.uppercased()).font(Theme.din(12.5)).kerning(1.4).padding(.top, 2)
                        .frame(width: 34, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(lang == l ? Theme.accent : Color.clear))
                        .foregroundStyle(lang == l ? Color.black : Theme.text.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.lineStrong))
        .help("Español / English")
    }
}

/// Dibujo del primer paso: un acorde gris que se reparte en dos voces de color.
struct SplitIllustration: View {
    var body: some View {
        Canvas { ctx, size in
            let rows = [0.15, 0.32, 0.5, 0.68, 0.85]
            let left = CGRect(x: size.width * 0.12, y: 0, width: size.width * 0.28, height: size.height)
            let right = CGRect(x: size.width * 0.6, y: 0, width: size.width * 0.28, height: size.height)
            for (k, r) in rows.enumerated() {
                let y = size.height * r
                ctx.fill(Path(roundedRect: CGRect(x: left.minX + CGFloat(k % 2) * 12, y: y - 6, width: left.width - 12, height: 12), cornerRadius: 3), with: .color(Color(hex: 0x8B93A3)))
                let c = k % 2 == 0 ? Color(hex: 0x4A9BFF) : Color(hex: 0xFF8C38)
                ctx.fill(Path(roundedRect: CGRect(x: right.minX + CGFloat(k % 2) * 12, y: y - 6, width: right.width - 12, height: 12), cornerRadius: 3), with: .color(c))
            }
            var arrow = Path()
            arrow.move(to: CGPoint(x: size.width * 0.44, y: size.height / 2)); arrow.addLine(to: CGPoint(x: size.width * 0.56, y: size.height / 2))
            arrow.move(to: CGPoint(x: size.width * 0.54, y: size.height / 2 - 6)); arrow.addLine(to: CGPoint(x: size.width * 0.56, y: size.height / 2)); arrow.addLine(to: CGPoint(x: size.width * 0.54, y: size.height / 2 + 6))
            ctx.stroke(arrow, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
    }
}
