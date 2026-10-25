import AppKit
import ApplicationServices

/// Agente de launchd que vigila ~/Documents/VSplit y abre VSplit cuando llega un archivo, aunque la app esté cerrada.
/// (Con la app abierta, FolderWatcher ya lo detecta.)
enum WatchAgent {
    static let label = "io.github.jdevesablanco.VSplit.watch"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    @discardableResult
    static func install() -> Bool {
        try? FileManager.default.createDirectory(at: FolderWatcher.folder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-b", Bundle.main.bundleIdentifier ?? "io.github.jdevesablanco.VSplit"],
            "WatchPaths": [FolderWatcher.folder.path],
            "RunAtLoad": false,
            "ThrottleInterval": 2,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? data.write(to: plistURL, options: .atomic)) != nil else { return false }
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        return true
    }

    static func uninstall() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

/// Estado de los permisos que usa VSplit (para el tutorial).
enum Permissions {
    /// Accesibilidad: leer tempo y compás de la barra de control de Logic.
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        // Una entrada antigua (de otra versión de la app) sale activada en Ajustes pero no vale: se borra para que macOS pregunte de nuevo.
        if !AXIsProcessTrusted(), let id = Bundle.main.bundleIdentifier {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "Accessibility", id]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !AXIsProcessTrusted(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Acceso a Documentos (macOS lo pregunta la primera vez que se lee la carpeta).
    static var documents: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: FolderWatcher.folder.path)) != nil
    }

    static func requestDocuments() {
        try? FileManager.default.createDirectory(at: FolderWatcher.folder, withIntermediateDirectories: true)
        _ = try? FileManager.default.contentsOfDirectory(atPath: FolderWatcher.folder.path)
        if !documents, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }
}
