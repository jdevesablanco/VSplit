import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Asa de arrastre: al empezar a arrastrar genera los .mid y entrega sus URLs (Logic crea una pista/región por archivo).
struct FileDragHandle: NSViewRepresentable {
    var title: String?
    var symbol: String = "arrow.up.doc"
    var help: String
    var urls: () -> [URL]

    func makeNSView(context: Context) -> DragHandleNSView {
        let v = DragHandleNSView()
        update(v)
        return v
    }

    func updateNSView(_ v: DragHandleNSView, context: Context) { update(v) }

    private func update(_ v: DragHandleNSView) {
        v.title = title
        v.symbol = symbol
        v.makeURLs = urls
        v.toolTip = help
        v.setAccessibilityLabel(title ?? help)
        v.invalidateIntrinsicContentSize()
        v.needsDisplay = true
    }
}

final class DragHandleNSView: NSView, NSDraggingSource {
    var title: String?
    var symbol = "arrow.up.doc"
    var makeURLs: () -> [URL] = { [] }
    private var downPoint: NSPoint?
    private var hovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Sin esto, con VSplit en segundo plano (p. ej. detrás de Logic) el primer clic solo activaría la ventana.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override var intrinsicContentSize: NSSize {
        guard let t = title else { return NSSize(width: 26, height: 22) }
        let w = (t.uppercased() as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .kern: 1.6]).width
        return NSSize(width: w + 40, height: 26)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        (hovering ? NSColor(hex: 0xE7E9ED) : NSColor(white: 0, alpha: 0.45)).setFill()
        path.fill()
        NSColor(white: 1, alpha: hovering ? 0 : 0.22).setStroke()
        path.lineWidth = 1
        path.stroke()
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        let tint = hovering ? NSColor.black : NSColor(hex: 0xE7E9ED)
        if let t = title?.uppercased() {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: tint, .kern: 1.6]
            let sz = (t as NSString).size(withAttributes: attrs)
            let total = 18 + sz.width
            var x = (bounds.width - total) / 2
            if let img { draw(img, tint: tint, at: NSPoint(x: x, y: (bounds.height - img.size.height) / 2)) }
            x += 18
            (t as NSString).draw(at: NSPoint(x: x, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
        } else if let img {
            draw(img, tint: tint, at: NSPoint(x: (bounds.width - img.size.width) / 2, y: (bounds.height - img.size.height) / 2))
        }
    }

    private func draw(_ img: NSImage, tint: NSColor, at p: NSPoint) {
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            tint.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(at: p, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) { downPoint = convert(event.locationInWindow, from: nil) }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
        downPoint = nil
        let urls = makeURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let icon = NSWorkspace.shared.icon(for: .midi)
        icon.size = NSSize(width: 40, height: 40)
        let items: [NSDraggingItem] = urls.enumerated().map { k, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: p.x - 20 + CGFloat(k) * 8, y: p.y - 20 - CGFloat(k) * 8, width: 40, height: 40), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    /// Al salir de la ventana con los archivos, VSplit se oculta para dejar ver el DAW entero.
    private var hidForDrag = false

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard !NSApp.isHidden else { return }
        let inside = NSApp.windows.contains { $0.isVisible && $0.frame.contains(screenPoint) }
        if !inside { hidForDrag = true; NSApp.hide(nil) }
    }

    /// Tras soltar, VSplit vuelve a aparecer (sin quitarle el foco al DAW): en modo flotante no tiene icono en el Dock.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard hidForDrag else { return }
        hidForDrag = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.unhideWithoutActivation() }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

/// Da acceso a la NSWindow de SwiftUI (título, punto de "modificado", proxy icon).
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
    }
}
