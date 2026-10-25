import AppKit
import ApplicationServices

/// Lee el tempo y el compás de la barra de control de Logic por Accesibilidad (sin capturas de pantalla).
/// La primera vez macOS pide permiso de Accesibilidad para VSplit; sin permiso devuelve nil y se usan 120 BPM y 4/4.
enum LogicReader {
    struct Info { var bpm: Double?; var numerator: Int?; var denominator: Int? }

    static func read(prompt: Bool) -> Info? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first else { return nil }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var info = Info()
        var visited = 0
        func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
        func walk(_ e: AXUIElement, _ depth: Int) {
            visited += 1
            guard visited < 5000, depth < 10, info.bpm == nil || info.numerator == nil else { return }
            let desc = (attr(e, kAXDescriptionAttribute) as? String) ?? ""
            if desc == "Tempo", info.bpm == nil, let v = attr(e, kAXValueAttribute) {
                info.bpm = (v as? NSNumber)?.doubleValue ?? Double("\(v)".replacingOccurrences(of: ",", with: "."))
            }
            if desc == "Time Signature", info.numerator == nil, let v = attr(e, kAXValueAttribute) as? String {
                let p = v.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if p.count == 2 { info.numerator = p[0]; info.denominator = p[1] }
            }
            if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { walk(k, depth + 1) } }
        }
        // La ventana principal de Logic primero (la del proyecto).
        if let main = attr(root, kAXMainWindowAttribute) { walk(main as! AXUIElement, 0) }
        if info.bpm == nil || info.numerator == nil, let wins = attr(root, kAXWindowsAttribute) as? [AXUIElement] { for w in wins { walk(w, 0) } }
        return info.bpm == nil && info.numerator == nil ? nil : info
    }
}
