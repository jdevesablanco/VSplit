import Foundation

/// Vigila ~/Documents/VSplit: cuando aparece un .mid nuevo (p. ej. Logic › Archivo › Exportar › Selección como
/// archivo MIDI…), avisa cuando el archivo ha terminado de escribirse.
@MainActor
final class FolderWatcher {
    nonisolated static let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("VSplit", isDirectory: true)

    private var source: DispatchSourceFileSystemObject?
    private var known: [String: Date] = [:]
    private let onNewFile: (URL) -> Void
    private var pending: DispatchWorkItem?

    init(onNewFile: @escaping (URL) -> Void) {
        self.onNewFile = onNewFile
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        known = snapshot()
        start()
    }

    private func midiFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        return urls.filter { ["mid", "midi", "smf"].contains($0.pathExtension.lowercased()) }
    }

    private func snapshot() -> [String: Date] {
        Dictionary(uniqueKeysWithValues: midiFiles().map { ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) })
    }

    private func start() {
        let fd = open(Self.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleScan() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    /// Espera a que el archivo deje de crecer (Logic lo escribe en varias pasadas) antes de abrirlo.
    private func scheduleScan() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.scan() } }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    private func scan() {
        let now = snapshot()
        let fresh = now.filter { name, date in known[name].map { date > $0 } ?? true }
        known = now
        guard let newest = fresh.max(by: { $0.value < $1.value }) else { return }
        let url = Self.folder.appendingPathComponent(newest.key)
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 { onNewFile(url) }
    }
}
