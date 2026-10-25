import AppKit
import UniformTypeIdentifiers
import SwiftUI
import VSplitCore

/// Puente entre el modelo y la vista AppKit (zoom, playhead, redibujado) sin pasar por SwiftUI en cada frame.
@MainActor
final class PianoRollController {
    weak var model: AppModel?
    weak var view: PianoRollNSView? { didSet { if pendingFit { fitToContent() } } }
    private var pendingFit = false

    func redraw() { view?.needsDisplay = true }
    func toolChanged() { view?.window?.invalidateCursorRects(for: view!); redraw() }
    func fitToContent() {
        guard let v = view, v.bounds.width > 100 else { pendingFit = true; return }
        pendingFit = false
        v.fitToContent()
    }
    func zoom(horizontal: CGFloat = 1, vertical: CGFloat = 1) { view?.zoom(h: horizontal, v: vertical, around: nil) }
    func setPlayhead(_ tick: Int) { view?.setPlayhead(tick) }
    func followPlayhead(_ tick: Int) { view?.follow(tick) }
    func scrollToTick(_ tick: Int) { view?.scrollTo(tick: tick) }
    /// Unidad de rejilla visible en ese punto (para mover/alargar/cuantizar con el teclado).
    func snapUnit(at tick: Int) -> Int { view?.snapUnit(at: tick) ?? (model?.doc?.ppq ?? 480) / 4 }
}

struct PianoRollView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> PianoRollNSView {
        let v = PianoRollNSView()
        v.model = model
        model.controller.view = v
        return v
    }

    func updateNSView(_ v: PianoRollNSView, context: Context) {
        _ = model.revision
        v.needsDisplay = true
    }
}

final class PianoRollNSView: NSView {
    weak var model: AppModel?

    let keyboardWidth: CGFloat = 60
    let rulerHeight: CGFloat = 26
    private(set) var pxPerTick: CGFloat = 0.12
    private(set) var rowHeight: CGFloat = 12
    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 60 * 12
    private var needsFit = false
    /// Hasta que el usuario hace zoom o se desplaza, la vista se reencuadra sola al cambiar de tamaño.
    private var userAdjusted = false

    private let playheadLayer = CALayer()
    private var playheadTick = 0
    private var mouse: NSPoint?

    private enum Drag {
        case none, stroke(erase: Bool, lockPitch: Int?), rect(start: NSPoint, current: NSPoint, add: Bool, clickNote: Int?)
        case lasso(points: [NSPoint], add: Bool), seek, split(Int), pan(start: NSPoint, sx: CGFloat, sy: CGFloat), edit
    }
    private var drag: Drag = .none

    /// Edición de notas en curso (dibujar, alargar o mover), con su vista previa.
    private struct NoteEdit {
        enum Kind { case draw, resize, move }
        var kind: Kind
        var indices: [Int]
        var originals: [Note]
        var grabbed: Int          // posición dentro de `originals`
        var anchorTick = 0
        var anchorPitch = 0
        var magnets: [Int] = []
        var current: [Note]
    }
    private var noteEdit: NoteEdit?
    private var lastStroke: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = .clear
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        playheadLayer.backgroundColor = Theme.playhead.cgColor
        playheadLayer.zPosition = 10
        playheadLayer.isHidden = true
        layer?.addSublayer(playheadLayer)
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Piano roll"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5 || abs(newSize.height - frame.height) > 0.5
        super.setFrameSize(newSize)
        // Reencuadrar solo si el tamaño cambia de verdad (SwiftUI reaplica el mismo tamaño en cada actualización).
        if (needsFit || (!userAdjusted && changed)) && newSize.width > 100 && doc != nil { fitToContent() } else { clampScroll() }
        layoutPlayhead()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: Geometría

    var noteArea: NSRect { NSRect(x: keyboardWidth, y: rulerHeight, width: max(1, bounds.width - keyboardWidth), height: max(1, bounds.height - rulerHeight)) }
    func x(_ tick: Int) -> CGFloat { keyboardWidth + CGFloat(tick) * pxPerTick - scrollX }
    func tick(atX x: CGFloat) -> Int { Int(((x - keyboardWidth + scrollX) / pxPerTick).rounded(.down)) }
    func y(_ pitch: Int) -> CGFloat { rulerHeight + CGFloat(127 - pitch) * rowHeight - scrollY }
    func pitch(atY y: CGFloat) -> Int { max(0, min(127, 127 - Int(((y - rulerHeight + scrollY) / rowHeight).rounded(.down)))) }

    private var doc: SplitDocument? { model?.doc }
    private var contentWidth: CGFloat { CGFloat((doc?.endTick ?? 0) + (doc?.ppq ?? 480) * 8) * pxPerTick }
    private var contentHeight: CGFloat { 128 * rowHeight }

    private func clampScroll() {
        let area = noteArea
        scrollX = max(0, min(scrollX, max(0, contentWidth - area.width)))
        scrollY = max(0, min(scrollY, max(0, contentHeight - area.height)))
    }

    func fitToContent() {
        guard let d = doc, !d.notes.isEmpty else { return }
        guard bounds.width > 100 else { needsFit = true; return }
        needsFit = false
        userAdjusted = false
        let area = noteArea
        let end = max(d.endTick, d.ppq * 4)
        pxPerTick = max(0.0005, (area.width - 24) / CGFloat(end))
        let lo = Int(d.notes.map(\.pitch).min()!) - 3, hi = Int(d.notes.map(\.pitch).max()!) + 3
        rowHeight = max(5, min(26, area.height / CGFloat(hi - lo + 1)))
        scrollX = 0
        let mid = CGFloat(127 - (lo + hi) / 2) * rowHeight
        scrollY = mid - area.height / 2
        clampScroll()
        layoutPlayhead()
        needsDisplay = true
    }

    func zoom(h: CGFloat, v: CGFloat, around point: NSPoint?) {
        userAdjusted = true
        let area = noteArea
        let p = point ?? NSPoint(x: playheadVisible ? x(playheadTick) : area.midX, y: area.midY)
        let tickAt = (p.x - keyboardWidth + scrollX) / pxPerTick
        let rowAt = (p.y - rulerHeight + scrollY) / rowHeight
        let minPx = (area.width - 24) / CGFloat(max(1, (doc?.endTick ?? 1) * 2))
        pxPerTick = max(min(0.002, minPx), min(3, pxPerTick * h))
        rowHeight = max(3, min(48, rowHeight * v))
        scrollX = tickAt * pxPerTick - (p.x - keyboardWidth)
        scrollY = rowAt * rowHeight - (p.y - rulerHeight)
        clampScroll()
        layoutPlayhead()
        needsDisplay = true
    }

    func scrollTo(tick: Int) {
        scrollX = CGFloat(tick) * pxPerTick - noteArea.width * 0.1
        clampScroll(); layoutPlayhead(); needsDisplay = true
    }

    // MARK: Playhead

    private var playheadVisible: Bool { let px = x(playheadTick); return px >= keyboardWidth && px <= bounds.maxX }

    func setPlayhead(_ tick: Int) {
        playheadTick = tick
        layoutPlayhead()
    }

    func follow(_ tick: Int) {
        let px = x(tick), area = noteArea
        if px > area.maxX - 30 || px < area.minX { scrollTo(tick: tick) }
    }

    private func layoutPlayhead() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let px = x(playheadTick)
        playheadLayer.isHidden = doc == nil || px < keyboardWidth || px > bounds.maxX
        // La capa no es "flipped": y = 0 abajo; ocupa toda la altura.
        playheadLayer.frame = CGRect(x: px - 0.75, y: 0, width: 1.5, height: bounds.height)
        CATransaction.commit()
    }

    // MARK: Dibujo

    private static let bg = NSColor(hex: 0x05070C, alpha: 0.55).cgColor
    private static let rowWhite = NSColor(hex: 0x05070C, alpha: 0.35).cgColor
    private static let rowBlack = NSColor(hex: 0x020306, alpha: 0.5).cgColor
    private static let unassigned = NSColor(hex: 0x8B93A3)
    private static let gridBar = NSColor(white: 1, alpha: 0.07).cgColor
    private static let gridBeat = NSColor(white: 1, alpha: 0.03).cgColor
    private static let gridSub = NSColor(white: 1, alpha: 0.018).cgColor

    private static let logDrawTime = ProcessInfo.processInfo.environment["VSPLIT_DRAWTIME"] != nil

    override func draw(_ dirtyRect: NSRect) {
        let started = CFAbsoluteTimeGetCurrent()
        defer { if Self.logDrawTime { print(String(format: "draw %.1f ms", (CFAbsoluteTimeGetCurrent() - started) * 1000)) } }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Self.bg)
        ctx.fill(bounds)
        guard let m = model, let d = m.doc else { return }
        let area = noteArea
        let t0 = max(0, tick(atX: area.minX)), t1 = tick(atX: area.maxX) + 1
        let pTop = pitch(atY: area.minY), pBottom = pitch(atY: area.maxY - 1)
        let bars = d.tempoMap.bars(from: t0, to: t1)

        ctx.saveGState()
        ctx.clip(to: area)

        // Filas
        for p in pBottom...pTop {
            let r = CGRect(x: area.minX, y: y(p), width: area.width, height: rowHeight)
            ctx.setFillColor(NoteNames.isBlack(p) ? Self.rowBlack : Self.rowWhite)
            ctx.fill(r)
            if p % 12 == 0 {
                ctx.setFillColor(Self.gridBeat)
                ctx.fill(CGRect(x: area.minX, y: r.maxY - 1, width: area.width, height: 1))
            }
        }

        // Rango de loop
        if m.loopEnabled, let r = m.loopRange {
            ctx.setFillColor(NSColor(hex: 0xE7E9ED, alpha: 0.04).cgColor)
            ctx.fill(CGRect(x: x(r.lowerBound), y: area.minY, width: CGFloat(r.count) * pxPerTick, height: area.height))
        }

        // Cuadrícula: compases, beats y subdivisiones
        for bar in bars {
            let bx = x(bar.startTick)
            ctx.setFillColor(Self.gridBar)
            ctx.fill(CGRect(x: bx, y: area.minY, width: 1, height: area.height))
            let beatPx = CGFloat(bar.beatLength) * pxPerTick
            guard beatPx > 18 else { continue }
            let subdiv = beatPx > 220 ? 4 : beatPx > 110 ? 2 : 1
            let step = bar.beatLength / subdiv
            var t = bar.startTick + step, k = 1
            while t < bar.startTick + bar.length {
                ctx.setFillColor(k % subdiv == 0 ? Self.gridBeat : Self.gridSub)
                ctx.fill(CGRect(x: x(t), y: area.minY, width: 1, height: area.height))
                t += step; k += 1
            }
        }

        let visible = d.indices(fromTick: t0, toTick: t1, lowPitch: pBottom, highPitch: pTop)
        // Con miles de notas en pantalla: rectángulos simples, sin contornos ni recuadros de acorde.
        let dense = visible.count > 3000
        let assignment: (Int) -> VoiceID? = m.preview.map { p in { p[$0] } } ?? { d.notes[$0].voiceID }

        // Recuadros de acordes
        if m.showChords, !dense, !m.chordInfo.chords.isEmpty {
            var seen = Set<Int>()
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.22).cgColor)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.045).cgColor)
            ctx.setLineWidth(1)
            for i in visible where i < m.chordInfo.chordOf.count {
                let c = m.chordInfo.chordOf[i]
                guard seen.insert(c).inserted else { continue }
                let members = m.chordInfo.chords[c]
                guard members.count > 1 else { continue }
                let s = members.map { d.notes[$0].startTick }.min()!, e = members.map { d.notes[$0].endTick }.min()!
                let lo = members.map { Int(d.notes[$0].pitch) }.min()!, hi = members.map { Int(d.notes[$0].pitch) }.max()!
                let r = CGRect(x: x(s) - 3, y: y(hi) - 3, width: max(8, CGFloat(e - s) * pxPerTick) + 6, height: CGFloat(hi - lo + 1) * rowHeight + 6)
                let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
                ctx.addPath(path); ctx.fillPath()
                ctx.addPath(path); ctx.strokePath()
            }
        }

        // Notas, agrupadas por (voz, nivel de opacidad) para rellenar de una vez.
        var colorOf: [VoiceID: (NSColor, Bool)] = [:]
        let anySolo = d.voices.contains(where: \.isSolo)
        for v in d.voices {
            let c = NSColor(srgbRed: v.color.r, green: v.color.g, blue: v.color.b, alpha: 1)
            colorOf[v.id] = (c, v.isMuted || (anySolo && !v.isSolo))
        }
        struct Key: Hashable { var voice: Int; var level: Int }
        var paths: [Key: CGMutablePath] = [:]
        let selectedPath = CGMutablePath()
        let h = max(2, rowHeight - 1)
        let radius = min(3, h / 3)
        var labels: [(CGRect, Int)] = []
        let showLabels = m.showLabels && rowHeight >= 10
        let hidden = Set(noteEdit?.indices ?? [])
        for i in visible where !hidden.contains(i) {
            let n = d.notes[i]
            let r = CGRect(x: x(n.startTick), y: y(Int(n.pitch)) + 0.5, width: max(2, CGFloat(n.durationTick) * pxPerTick - 1), height: h)
            let v = assignment(i)
            let level = m.showVelocity ? min(7, Int(n.velocity) / 16) : 7
            let key = Key(voice: v ?? -1, level: level)
            let path = paths[key] ?? CGMutablePath()
            if r.width > 4 && !dense { path.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius) } else { path.addRect(r) }
            paths[key] = path
            if m.selection.contains(i) { selectedPath.addRect(r.insetBy(dx: -0.5, dy: -0.5)) }
            if showLabels && r.width >= 26 && labels.count < 800 { labels.append((r, Int(n.pitch))) }
        }
        for (key, path) in paths {
            var alpha = 0.35 + 0.65 * (CGFloat(key.level) + 1) / 8
            let base: NSColor
            if let (c, dimmed) = colorOf[key.voice] { base = c; if dimmed { alpha *= 0.3 } } else { base = Self.unassigned; if anySolo { alpha *= 0.3 } }
            ctx.setFillColor(base.withAlphaComponent(alpha).cgColor)
            ctx.addPath(path); ctx.fillPath()
            guard !dense else { continue }
            ctx.setStrokeColor(base.blended(withFraction: 0.35, of: .white)?.withAlphaComponent(min(1, alpha + 0.2)).cgColor ?? base.cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(path); ctx.strokePath()
        }
        if let e = noteEdit {
            for n in e.current {
                let r = CGRect(x: x(n.startTick), y: y(Int(n.pitch)) + 0.5, width: max(2, CGFloat(n.durationTick) * pxPerTick - 1), height: h)
                let c = d.voice(n.voiceID).map { NSColor(srgbRed: $0.color.r, green: $0.color.g, blue: $0.color.b, alpha: 1) } ?? Self.unassigned
                let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
                ctx.setFillColor(c.cgColor); ctx.addPath(path); ctx.fillPath()
                ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5); ctx.addPath(path); ctx.strokePath()
            }
        }
        if !selectedPath.isEmpty {
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.addPath(selectedPath); ctx.strokePath()
        }
        if !labels.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: min(11, rowHeight - 3), weight: .medium), .foregroundColor: NSColor(hex: 0x0C1118, alpha: 0.85)]
            for (r, p) in labels {
                let s = NoteNames.name(p, middleCOctave: m.middleCOctave) as NSString
                s.draw(at: NSPoint(x: r.minX + 3, y: r.minY + (r.height - min(11, rowHeight - 3)) / 2 - 2), withAttributes: attrs)
            }
        }

        // Cortes del modo registro (arrastrables)
        for (k, p) in m.registerSplits.enumerated() {
            let ly = y(p) + rowHeight
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            ctx.fill(CGRect(x: area.minX, y: ly - 1, width: area.width, height: 2))
            let label = String(localized: "Split \(k + 1): \(NoteNames.name(p, middleCOctave: m.middleCOctave))") as NSString
            label.draw(at: NSPoint(x: area.minX + 6, y: ly - 15), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white])
        }

        // Rectángulo / lazo de selección
        switch drag {
        case .rect(let a, let b, _, _):
            let r = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor); ctx.fill(r)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(1); ctx.stroke(r)
        case .lasso(let pts, _):
            guard pts.count > 1 else { break }
            ctx.beginPath(); ctx.addLines(between: pts); ctx.closePath()
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(1)
            ctx.drawPath(using: .fillStroke)
        default: break
        }

        // Brocha: la nota bajo el cursor se resalta con el color que va a recibir (como en FL Studio).
        if let p = mouse, area.contains(p), m.tool == .brush || m.tool == .eraser, let i = noteAt(p) {
            let n = d.notes[i]
            let r = CGRect(x: x(n.startTick), y: y(Int(n.pitch)) + 0.5, width: max(2, CGFloat(n.durationTick) * pxPerTick - 1), height: max(2, rowHeight - 1)).insetBy(dx: -1.5, dy: -1.5)
            let erasing = m.tool == .eraser
            let c: NSColor = erasing ? NSColor(white: 1, alpha: 0.7) : (d.voice(m.activeVoiceID).map { NSColor(srgbRed: $0.color.r, green: $0.color.g, blue: $0.color.b, alpha: 1) } ?? .white)
            ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(2)
            if erasing { ctx.setLineDash(phase: 0, lengths: [3, 2]) }
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.restoreGState()

        drawRuler(ctx, bars: bars, m: m)
        drawKeyboard(ctx, low: pBottom, high: pTop, m: m)
    }

    private func drawRuler(_ ctx: CGContext, bars: [TempoMap.Bar], m: AppModel) {
        let r = NSRect(x: keyboardWidth, y: 0, width: bounds.width - keyboardWidth, height: rulerHeight)
        ctx.setFillColor(NSColor(hex: 0x05070C, alpha: 0.55).cgColor); ctx.fill(r)
        ctx.saveGState(); ctx.clip(to: r)
        if m.loopEnabled, let lr = m.loopRange {
            ctx.setFillColor(NSColor(hex: 0xFF8A3A, alpha: 0.85).cgColor)
            ctx.fill(CGRect(x: x(lr.lowerBound), y: rulerHeight - 6, width: CGFloat(lr.count) * pxPerTick, height: 5))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor(hex: 0x6E747E)]
        var lastLabelX: CGFloat = -1000
        for bar in bars {
            let bx = x(bar.startTick)
            ctx.setFillColor(NSColor(hex: 0x2A2E35).cgColor)
            ctx.fill(CGRect(x: bx, y: 14, width: 1, height: rulerHeight - 14))
            if bx - lastLabelX >= 34 {
                ("\(bar.number + 1)" as NSString).draw(at: NSPoint(x: bx + 3, y: 2), withAttributes: attrs)
                lastLabelX = bx
            }
            let beatPx = CGFloat(bar.beatLength) * pxPerTick
            if beatPx > 18 {
                ctx.setFillColor(NSColor(hex: 0x1E2126).cgColor)
                var t = bar.startTick + bar.beatLength
                while t < bar.startTick + bar.length {
                    ctx.fill(CGRect(x: x(t), y: rulerHeight - 4, width: 1, height: 4)); t += bar.beatLength
                }
            }
        }
        ctx.restoreGState()
        ctx.setFillColor(NSColor(hex: 0x1C1F25).cgColor)
        ctx.fill(CGRect(x: 0, y: rulerHeight - 1, width: bounds.width, height: 1))
    }

    private func drawKeyboard(_ ctx: CGContext, low: Int, high: Int, m: AppModel) {
        let r = NSRect(x: 0, y: rulerHeight, width: keyboardWidth, height: bounds.height - rulerHeight)
        ctx.saveGState(); ctx.clip(to: r)
        ctx.setFillColor(NSColor(hex: 0x10141C, alpha: 0.85).cgColor); ctx.fill(r)
        let font = NSFont.systemFont(ofSize: min(10, max(7, rowHeight - 2)), weight: .medium)
        for p in low...high {
            let ky = y(p)
            if NoteNames.isBlack(p) {
                ctx.setFillColor(NSColor(hex: 0x07080A).cgColor)
                ctx.fill(CGRect(x: 0, y: ky, width: keyboardWidth * 0.6, height: rowHeight))
            }
            if p % 12 == 0 || p % 12 == 5 {
                ctx.setFillColor(NSColor(hex: 0x07080A).cgColor)
                ctx.fill(CGRect(x: 0, y: ky + rowHeight - 0.5, width: keyboardWidth, height: 0.5))
            }
            if p % 12 == 0 || (rowHeight >= 13 && !NoteNames.isBlack(p)) {
                let s = NoteNames.name(p, middleCOctave: m.middleCOctave) as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(hex: p % 12 == 0 ? 0xA3A9B3 : 0x585E68)]
                let sz = s.size(withAttributes: attrs)
                s.draw(at: NSPoint(x: keyboardWidth - sz.width - 4, y: ky + (rowHeight - sz.height) / 2), withAttributes: attrs)
            }
        }
        ctx.restoreGState()
        ctx.setFillColor(NSColor(hex: 0x1C1F25).cgColor)
        ctx.fill(CGRect(x: keyboardWidth - 1, y: rulerHeight, width: 1, height: bounds.height))
        ctx.setFillColor(NSColor(hex: 0x05070C, alpha: 0.7).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: keyboardWidth, height: rulerHeight - 1))
    }

    // MARK: Hit testing

    /// La brocha toca la fila de la nota bajo el cursor (o la fila fijada con ⇧) en un ancho de 6 px.
    private func brushRect(at p: NSPoint, lockPitch: Int? = nil) -> NSRect {
        let row = lockPitch ?? pitch(atY: p.y)
        return NSRect(x: p.x - 5, y: y(row), width: 10, height: rowHeight)
    }

    private func notes(in rect: NSRect) -> [Int] {
        guard let d = doc else { return [] }
        let r = rect.standardized
        let lo = pitch(atY: r.maxY - 0.01), hi = pitch(atY: r.minY)
        let t0 = tick(atX: r.minX), t1 = tick(atX: r.maxX)
        return d.indices(fromTick: t0, toTick: t1, lowPitch: lo, highPitch: hi).filter { i in
            let n = d.notes[i]
            let nx0 = x(n.startTick), nx1 = max(nx0 + 2, x(n.endTick))
            return nx1 >= r.minX && nx0 <= r.maxX
        }
    }

    private func noteAt(_ p: NSPoint) -> Int? {
        guard let d = doc, noteArea.contains(p) else { return nil }
        let pt = pitch(atY: p.y)
        let tol = Int(3 / pxPerTick)
        let t = tick(atX: p.x)
        let cands = d.indices(fromTick: t - tol, toTick: t + tol, lowPitch: pt, highPitch: pt).filter { i in
            let n = d.notes[i]
            return p.x >= x(n.startTick) - 2 && p.x <= max(x(n.endTick), x(n.startTick) + 3) + 2
        }
        return cands.max { d.notes[$0].startTick < d.notes[$1].startTick }
    }

    private func splitLineHit(_ p: NSPoint) -> Int? {
        guard let m = model, noteArea.contains(p) else { return nil }
        return m.registerSplits.enumerated().first { abs(y($0.element) + rowHeight - p.y) <= 4 }?.offset
    }

    // MARK: Ratón

    override func mouseMoved(with e: NSEvent) {
        mouse = convert(e.locationInWindow, from: nil)
        if model?.tool == .brush || model?.tool == .eraser { needsDisplay = true }
        if let m = model, let p = mouse, noteArea.contains(p) {
            if m.tool == .select || m.tool == .draw, let i = noteAt(p), edgeHit(i, p) { NSCursor.resizeLeftRight.set(); return }
            if m.tool != .select { cursorForTool.set() }
        }
        if let p = mouse, splitLineHit(p) != nil { NSCursor.resizeUpDown.set() } else { window?.invalidateCursorRects(for: self) }
    }

    override func mouseExited(with event: NSEvent) { mouse = nil; needsDisplay = true }

    override func resetCursorRects() {
        guard let m = model else { return }
        addCursorRect(noteArea, cursor: m.tool == .select ? .arrow : cursorForTool)
        addCursorRect(NSRect(x: keyboardWidth, y: 0, width: bounds.width, height: rulerHeight), cursor: .pointingHand)
        addCursorRect(NSRect(x: 0, y: rulerHeight, width: keyboardWidth, height: bounds.height), cursor: .pointingHand)
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        guard let m = model, let d = doc else { return }
        let p = convert(e.locationInWindow, from: nil)
        let shift = e.modifierFlags.contains(.shift), option = e.modifierFlags.contains(.option)
        if p.y < rulerHeight {
            if p.x > keyboardWidth { drag = .seek; m.seek(tick(atX: p.x)) }
            return
        }
        if p.x < keyboardWidth {
            let pt = pitch(atY: p.y)
            if shift { m.selection = Set(d.notes.indices.filter { d.notes[$0].pitch == pt }) } else { m.playPitch(pt) }
            return
        }
        // Arrastrar con el botón central o ⌥⌘ desplaza la vista.
        if e.modifierFlags.contains([.option, .command]) { drag = .pan(start: p, sx: scrollX, sy: scrollY); return }
        if let k = splitLineHit(p) { drag = .split(k); return }
        if e.clickCount == 2, let i = noteAt(p) { m.selectChords(of: [i], add: shift); drag = .none; return }

        switch m.tool {
        case .brush, .eraser:
            // ⌥-clic con la brocha = coger la voz de esa nota.
            if option, m.tool == .brush, let i = noteAt(p) { m.activeVoiceID = d.notes[i].voiceID ?? m.activeVoiceID; return }
            startStroke(at: p, erase: m.tool == .eraser, lock: shift)
        case .draw:
            if let i = noteAt(p) {
                if edgeHit(i, p) { beginResize(i) } else { beginMove(i, at: p) }
            } else {
                beginDraw(at: p)
            }
        case .select:
            if let i = noteAt(p), edgeHit(i, p) { beginResize(i); return }
            drag = option ? .lasso(points: [p], add: shift) : .rect(start: p, current: p, add: shift, clickNote: noteAt(p))
        }
    }

    // MARK: Dibujar / alargar / mover notas

    /// Borde derecho de una nota (para alargarla).
    private func edgeHit(_ i: Int, _ p: NSPoint) -> Bool {
        guard let d = doc else { return false }
        let n = d.notes[i]
        let x1 = x(n.endTick)
        return x1 - x(n.startTick) > 10 && p.x >= x1 - 6
    }

    func snapUnit(at tick: Int) -> Int {
        guard let d = doc else { return 1 }
        let m = d.tempoMap.meter(atTick: tick)
        return Snap.gridUnit(pxPerTick: Double(pxPerTick), beatTicks: d.tempoMap.beatLength(m), barTicks: d.tempoMap.barLength(m))
    }

    /// Ajuste inteligente: rejilla visible + bordes de otras notas cercanos. Con ⌘, sin ajuste.
    private func snapped(_ t: Int, magnets: [Int]) -> Int {
        guard let d = doc else { return t }
        if NSEvent.modifierFlags.contains(.command) { return max(0, t) }
        let origin = d.tempoMap.barStartTick(containing: max(0, t))
        return max(0, Snap.snap(t, unit: snapUnit(at: max(0, t)), origin: origin, magnets: magnets, tolerance: Int(6 / pxPerTick)))
    }

    private func magnets(excluding skip: Set<Int>) -> [Int] {
        guard let d = doc else { return [] }
        let area = noteArea
        return d.indices(fromTick: tick(atX: area.minX), toTick: tick(atX: area.maxX)).filter { !skip.contains($0) }.flatMap { [d.notes[$0].startTick, d.notes[$0].endTick] }
    }

    private func beginDraw(at p: NSPoint) {
        guard let m = model, let d = doc else { return }
        let raw = max(0, tick(atX: p.x))
        let unit = snapUnit(at: raw)
        let start = NSEvent.modifierFlags.contains(.command) ? raw : Snap.floor(raw, unit: unit, origin: d.tempoMap.barStartTick(containing: raw))
        let pitch = pitch(atY: p.y)
        let voice = m.activeVoiceID
        let chans = d.notes.filter { $0.voiceID == voice }.map(\.channel)
        let channel = chans.isEmpty ? (d.notes.first?.channel ?? 0) : Dictionary(grouping: chans, by: { $0 }).max { $0.value.count < $1.value.count }!.key
        let n = Note(id: -1, pitch: UInt8(pitch), velocity: 90, startTick: start, durationTick: m.lastDrawLength ?? unit, channel: channel, track: d.loadedTracks.first ?? 0, voiceID: voice)
        noteEdit = NoteEdit(kind: .draw, indices: [], originals: [n], grabbed: 0, anchorTick: start, anchorPitch: pitch, magnets: magnets(excluding: []), current: [n])
        drag = .edit
        m.playPitch(pitch)
        needsDisplay = true
    }

    private func beginResize(_ i: Int) {
        guard let m = model, let d = doc else { return }
        let idx = m.selection.contains(i) ? m.selection.sorted() : [i]
        let originals = idx.map { d.notes[$0] }
        noteEdit = NoteEdit(kind: .resize, indices: idx, originals: originals, grabbed: idx.firstIndex(of: i)!, magnets: magnets(excluding: Set(idx)), current: originals)
        drag = .edit
    }

    private func beginMove(_ i: Int, at p: NSPoint) {
        guard let m = model, let d = doc else { return }
        let idx = m.selection.contains(i) ? m.selection.sorted() : [i]
        let originals = idx.map { d.notes[$0] }
        noteEdit = NoteEdit(kind: .move, indices: idx, originals: originals, grabbed: idx.firstIndex(of: i)!,
                            anchorTick: tick(atX: p.x) - d.notes[i].startTick, anchorPitch: pitch(atY: p.y), magnets: magnets(excluding: Set(idx)), current: originals)
        drag = .edit
    }

    private func updateEdit(_ p: NSPoint) {
        guard var e = noteEdit else { return }
        let g = e.originals[e.grabbed]
        let raw = tick(atX: p.x)
        switch e.kind {
        case .draw:
            let unit = snapUnit(at: g.startTick)
            let end = snapped(raw, magnets: e.magnets)
            e.current[0].durationTick = max(NSEvent.modifierFlags.contains(.command) ? 10 : unit, end - g.startTick)
        case .resize:
            let unit = snapUnit(at: g.startTick)
            let delta = snapped(raw, magnets: e.magnets) - g.endTick
            let minLen = NSEvent.modifierFlags.contains(.command) ? 10 : unit
            e.current = e.originals.map { var n = $0; n.durationTick = max(min(minLen, $0.durationTick), $0.durationTick + delta); return n }
        case .move:
            let newStart = snapped(raw - e.anchorTick, magnets: e.magnets)
            let dt = newStart - g.startTick
            let dp = pitch(atY: p.y) - e.anchorPitch
            e.current = e.originals.map { var n = $0; n.startTick = max(0, $0.startTick + dt); n.pitch = UInt8(max(0, min(127, Int($0.pitch) + dp))); return n }
        }
        noteEdit = e
        needsDisplay = true
    }

    private func commitEdit() {
        guard let e = noteEdit, let m = model, let d = doc else { noteEdit = nil; return }
        noteEdit = nil
        var all = d.notes
        let name: String
        switch e.kind {
        case .draw:
            all.append(e.current[0])
            m.lastDrawLength = e.current[0].durationTick
            name = String(localized: "Draw Note")
        case .resize, .move:
            guard e.current != e.originals else { return }
            for (k, i) in e.indices.enumerated() { all[i] = e.current[k] }
            if e.kind == .resize, e.indices.count == 1 { m.lastDrawLength = e.current[0].durationTick }
            name = e.kind == .resize ? String(localized: "Change Length") : String(localized: "Move Notes")
        }
        let keys = Set(e.current.map { "\($0.pitch)-\($0.startTick)-\($0.channel)" })
        m.replaceNotes(all, name: name) { keys.contains("\($0.pitch)-\($0.startTick)-\($0.channel)") }
        if e.kind == .move, let n = e.current.first, n.pitch != e.originals[0].pitch { m.playPitch(Int(n.pitch)) }
    }

    override func rightMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
    override func rightMouseUp(with e: NSEvent) { mouseUp(with: e) }

    /// Cursor de brocha/borrador (icono con punta en la esquina inferior izquierda).
    private var cursorForTool: NSCursor {
        let erase = model?.tool == .eraser, pencil = model?.tool == .draw
        let key = erase ? "e" : pencil ? "d" : "b"
        if let c = Self.cursors[key] { return c }
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let sym = NSImage(systemSymbolName: erase ? "eraser.fill" : pencil ? "pencil" : "paintbrush.pointed.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return .crosshair }
        let size = NSSize(width: sym.size.width + 2, height: sym.size.height + 2)
        let img = NSImage(size: size, flipped: false) { r in
            // Contorno oscuro para que se vea sobre las notas claras.
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] as [(CGFloat, CGFloat)] {
                let t = sym.copy() as! NSImage
                t.lockFocus(); NSColor.black.set(); NSRect(origin: .zero, size: t.size).fill(using: .sourceAtop); t.unlockFocus()
                t.draw(at: NSPoint(x: 1 + dx, y: 1 + dy), from: .zero, operation: .sourceOver, fraction: 0.8)
            }
            let w = sym.copy() as! NSImage
            w.lockFocus(); NSColor.white.set(); NSRect(origin: .zero, size: w.size).fill(using: .sourceAtop); w.unlockFocus()
            w.draw(at: NSPoint(x: 1, y: 1), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        let c = NSCursor(image: img, hotSpot: NSPoint(x: 2, y: size.height - 2))
        Self.cursors[key] = c
        return c
    }
    private static var cursors: [String: NSCursor] = [:]

    override func otherMouseDown(with e: NSEvent) {
        drag = .pan(start: convert(e.locationInWindow, from: nil), sx: scrollX, sy: scrollY)
    }
    override func otherMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
    override func otherMouseUp(with e: NSEvent) { drag = .none }

    override func mouseDragged(with e: NSEvent) {
        guard let m = model else { return }
        let p = convert(e.locationInWindow, from: nil)
        mouse = p
        switch drag {
        case .stroke(let erase, let lock):
            autoscrollIfNeeded(p)
            paint(to: p, erase: erase, lock: lock)
            needsDisplay = true
        case .rect(let s, _, let add, let n):
            autoscrollIfNeeded(p)
            drag = .rect(start: s, current: p, add: add, clickNote: n)
            needsDisplay = true
        case .lasso(var pts, let add):
            pts.append(p); drag = .lasso(points: pts, add: add); needsDisplay = true
        case .seek:
            m.seek(max(0, tick(atX: p.x)))
        case .split(let k):
            m.setRegisterSplit(k, pitch: pitch(atY: p.y + rowHeight / 2))
        case .edit:
            autoscrollIfNeeded(p)
            updateEdit(p)
        case .pan(let s, let sx, let sy):
            userAdjusted = true
            scrollX = sx - (p.x - s.x); scrollY = sy - (p.y - s.y); clampScroll(); layoutPlayhead(); needsDisplay = true
        case .none: break
        }
    }

    override func mouseUp(with e: NSEvent) {
        guard let m = model else { return }
        switch drag {
        case .edit:
            commitEdit()
        case .stroke:
            m.endStroke()
        case .rect(let a, let b, let add, let clickNote):
            if hypot(a.x - b.x, a.y - b.y) < 3 {
                // Clic simple: seleccionar la nota (o vaciar la selección).
                if let i = clickNote ?? noteAt(a) {
                    if add { if m.selection.contains(i) { m.selection.remove(i) } else { m.selection.insert(i) } } else { m.selection = [i] }
                } else if !add { m.selection = [] }
            } else {
                let found = Set(notes(in: NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))))
                m.selection = add ? m.selection.union(found) : found
            }
        case .lasso(let pts, let add):
            if pts.count > 2, let d = doc {
                let path = CGMutablePath(); path.addLines(between: pts); path.closeSubpath()
                let box = path.boundingBox
                let found = Set(notes(in: box).filter { i in
                    let n = d.notes[i]
                    let x0 = max(box.minX, x(n.startTick)), x1 = min(box.maxX, max(x(n.endTick), x(n.startTick) + 2))
                    return path.contains(CGPoint(x: (x0 + x1) / 2, y: y(Int(n.pitch)) + rowHeight / 2))
                })
                m.selection = add ? m.selection.union(found) : found
            }
        default: break
        }
        drag = .none
        lastStroke = nil
        needsDisplay = true
    }

    private func startStroke(at p: NSPoint, erase: Bool, lock: Bool) {
        guard let m = model else { return }
        if !erase && m.activeVoiceID == nil { NSSound.beep(); return }
        let lockPitch = lock ? pitch(atY: p.y) : nil
        m.beginStroke(erase: erase)
        drag = .stroke(erase: erase, lockPitch: lockPitch)
        lastStroke = nil
        paint(to: p, erase: erase, lock: lockPitch)
    }

    /// Pinta todo lo que la brocha barre desde el último punto (muestreando el segmento).
    private func paint(to p: NSPoint, erase: Bool, lock: Int?) {
        guard let m = model else { return }
        let from = lastStroke ?? p
        let r = brushRect(at: p, lockPitch: lock)
        let step = max(2, min(r.width, r.height) / 2)
        let dist = hypot(p.x - from.x, p.y - from.y)
        let n = max(1, Int(dist / step))
        var hit: [Int] = []
        for k in 0...n {
            let t = CGFloat(k) / CGFloat(n)
            let q = NSPoint(x: from.x + (p.x - from.x) * t, y: from.y + (p.y - from.y) * t)
            hit += notes(in: brushRect(at: q, lockPitch: lock))
        }
        lastStroke = p
        if !hit.isEmpty { m.strokeAssign(hit, erase: erase) }
    }

    private func autoscrollIfNeeded(_ p: NSPoint) {
        let area = noteArea
        var dx: CGFloat = 0, dy: CGFloat = 0
        if p.x > area.maxX - 10 { dx = 12 } else if p.x < area.minX + 10 { dx = -12 }
        if p.y > area.maxY - 10 { dy = 8 } else if p.y < area.minY + 10 { dy = -8 }
        guard dx != 0 || dy != 0 else { return }
        scrollX += dx; scrollY += dy; clampScroll(); layoutPlayhead()
    }

    override func rightMouseDown(with e: NSEvent) {
        guard let m = model, let d = doc else { return }
        let p = convert(e.locationInWindow, from: nil)
        // Con la brocha, el botón derecho borra (quita la voz) arrastrando, como en FL Studio.
        if m.tool == .draw, noteArea.contains(p) {
            if let i = noteAt(p) { m.deleteNotes([i]) }
            return
        }
        if m.tool != .select, noteArea.contains(p) {
            startStroke(at: p, erase: true, lock: e.modifierFlags.contains(.shift))
            return
        }
        if let i = noteAt(p), !m.selection.contains(i) { m.selection = [i] }
        let menu = NSMenu()
        let assign = NSMenu()
        menu.autoenablesItems = false
        assign.autoenablesItems = false
        for (k, v) in d.voices.enumerated() {
            let item = BlockMenuItem(title: k < 9 ? "\(v.name)  (\(k + 1))" : v.name) { m.assignSelection(toVoiceAt: k) }
            item.image = swatch(v.color)
            item.isEnabled = !m.selection.isEmpty
            assign.addItem(item)
        }
        let assignItem = NSMenuItem(title: String(localized: "Assign to"), action: nil, keyEquivalent: "")
        assignItem.submenu = assign
        menu.addItem(assignItem)
        menu.addItem(BlockMenuItem(title: String(localized: "Unassign"), enabled: !m.selection.isEmpty) { m.unassignSelection() })
        menu.addItem(.separator())
        menu.addItem(BlockMenuItem(title: String(localized: "Select Whole Chord"), enabled: !m.selection.isEmpty) { m.selectChordsOfSelection() })
        menu.addItem(BlockMenuItem(title: String(localized: "Select Same Pitch"), enabled: !m.selection.isEmpty) { m.selectSamePitch() })
        if let i = m.selection.first {
            let v = d.notes[i].voiceID
            menu.addItem(BlockMenuItem(title: String(localized: "Select All Notes of “\(m.voiceName(v))”")) { m.selectVoice(v) })
        }
        menu.addItem(.separator())
        menu.addItem(BlockMenuItem(title: String(localized: "Re-apply Auto-split to Selection"), enabled: !m.selection.isEmpty) { m.applyAutoSplit(selectionOnly: true) })
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    private func swatch(_ c: RGBAColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            return true
        }
    }

    // MARK: Scroll y zoom

    override func scrollWheel(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        var dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if !e.hasPreciseScrollingDeltas { dx *= 12; dy *= 12 }
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) {
            let f = exp((dy + dx) * 0.012)
            if e.modifierFlags.contains(.option) { zoom(h: 1, v: f, around: p) } else { zoom(h: f, v: 1, around: p) }
            return
        }
        userAdjusted = true
        if e.modifierFlags.contains(.shift), dx == 0 { dx = dy; dy = 0 }
        scrollX -= dx; scrollY -= dy
        clampScroll(); layoutPlayhead(); needsDisplay = true
    }

    override func magnify(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if e.modifierFlags.contains(.option) { zoom(h: 1, v: 1 + e.magnification, around: p) } else { zoom(h: 1 + e.magnification, v: 1, around: p) }
    }

    // MARK: Soltar archivos MIDI (Finder, Logic)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingSource == nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingSource == nil, let m = model else { return false }
        return DropHandler.handle(sender.draggingPasteboard, model: m)
    }
}

/// Recibe .mid como URL de archivo o como file promise (lo que entrega Logic al arrastrar una región).
@MainActor
enum DropHandler {
    static func handle(_ pb: NSPasteboard, model: AppModel) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let u = urls.first {
            model.open(url: u)
            return true
        }
        let receivers = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        if !receivers.isEmpty, !receivers.contains(where: { $0.fileTypes.contains { UTType($0)?.conforms(to: .midi) ?? false } }) {
            // Logic, al arrastrar una región a otra app, solo ofrece renderizarla a audio (WAV): no pedimos ese archivo.
            DispatchQueue.main.async {
                model.presentError(String(localized: "Logic sends audio when you drag a region"),
                                   String(localized: "To bring the MIDI notes: double-click the region in Logic, press ⌘A and ⌘C in the Piano Roll, then press ⌘V here."))
            }
            return true
        }
        if let r = receivers.first(where: { $0.fileTypes.contains { UTType($0)?.conforms(to: .midi) ?? false } }) {
            let dest = PreviewEngine.cacheDir.appendingPathComponent("Incoming/\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            var opened = false
            r.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: .main) { url, error in
                MainActor.assumeIsolated {
                    guard !opened else { return }
                    if let error { model.presentError(String(localized: "Can't receive the dropped file"), error.localizedDescription); return }
                    opened = true
                    model.open(url: url)
                }
            }
            return true
        }
        return false
    }
}

final class BlockMenuItem: NSMenuItem {
    private let block: () -> Void
    init(title: String, enabled: Bool = true, block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { block() }
}
