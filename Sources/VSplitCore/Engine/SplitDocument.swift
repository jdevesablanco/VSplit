import Foundation

public struct AssignmentChange: Hashable, Sendable {
    public var index: Int32
    public var from: VoiceID?
    public var to: VoiceID?
}

/// Comando deshacible: cambios de asignación (diff por nota) y/o cambio de la lista de voces.
public struct EditCommand: Sendable {
    public var name: String
    public var changes: [AssignmentChange]
    public var voicesBefore: [Voice]?
    public var voicesAfter: [Voice]?
    /// Edición de notas (dibujar, mover, cambiar duración, borrar): copia completa antes/después.
    public var notesBefore: [Note]?
    public var notesAfter: [Note]?
    /// Comandos consecutivos con la misma clave se funden en uno (p. ej. escribir el nombre de una voz).
    public var coalesceKey: String?

    public init(name: String, changes: [AssignmentChange] = [], voicesBefore: [Voice]? = nil, voicesAfter: [Voice]? = nil, coalesceKey: String? = nil) {
        self.name = name; self.changes = changes; self.voicesBefore = voicesBefore; self.voicesAfter = voicesAfter; self.coalesceKey = coalesceKey
    }
}

/// Estado de edición: las notas del clip cargado con su voz, y la lista de voces. Tipo valor.
public struct SplitDocument: Sendable {
    public let sequence: MIDISequence
    /// Pistas del archivo que se han cargado (sus notas y eventos de canal).
    public let loadedTracks: [Int]
    public let tempoMap: TempoMap
    public private(set) var notes: [Note]
    public private(set) var voices: [Voice]
    public private(set) var idCounter: Int
    /// Duración máxima de nota (para recortar búsquedas por rango de tiempo).
    public private(set) var maxDuration: Int
    /// Si se han dibujado/editado notas (entonces la sesión guarda las notas, no solo las voces).
    public private(set) var notesEdited = false

    public init(sequence: MIDISequence, tracks: [Int]? = nil, voices: [Voice] = Voice.defaults()) {
        let all = Set(sequence.tracks.map(\.index))
        let wanted = tracks.map { Set($0).intersection(all) } ?? all
        self.sequence = sequence
        self.loadedTracks = wanted.sorted()
        self.tempoMap = sequence.tempoMap
        var notes = sequence.notes.filter { wanted.contains($0.track) }
        for i in notes.indices { notes[i].id = i; notes[i].voiceID = nil }
        self.notes = notes
        self.voices = voices.isEmpty ? Voice.defaults() : voices
        self.idCounter = (self.voices.map(\.id).max() ?? 0) + 1
        self.maxDuration = notes.map(\.durationTick).max() ?? 0
    }

    public var ppq: Int { sequence.ppq }
    public var endTick: Int { max(notes.map(\.endTick).max() ?? 0, sequence.endTick) }

    public func voice(_ id: VoiceID?) -> Voice? { id.flatMap { id in voices.first { $0.id == id } } }
    public func voiceIndex(_ id: VoiceID?) -> Int? { id.flatMap { id in voices.firstIndex { $0.id == id } } }

    public func counts() -> [VoiceID: Int] {
        var c: [VoiceID: Int] = [:]
        for n in notes { if let v = n.voiceID { c[v, default: 0] += 1 } }
        return c
    }
    public var unassignedIndices: [Int] { notes.indices.filter { notes[$0].voiceID == nil } }

    public mutating func makeVoiceID() -> VoiceID { defer { idCounter += 1 }; return idCounter }

    // MARK: Construcción de comandos

    public func assignCommand<S: Sequence>(_ indices: S, to voice: VoiceID?, name: String) -> EditCommand? where S.Element == Int {
        assignCommand(pairs: indices.map { ($0, voice) }, name: name)
    }

    public func assignCommand(pairs: [(Int, VoiceID?)], name: String) -> EditCommand? {
        var changes: [AssignmentChange] = []
        for (i, v) in pairs where notes.indices.contains(i) && notes[i].voiceID != v {
            changes.append(AssignmentChange(index: Int32(i), from: notes[i].voiceID, to: v))
        }
        return changes.isEmpty ? nil : EditCommand(name: name, changes: changes)
    }

    public func voicesCommand(_ newVoices: [Voice], name: String, reassign: [(Int, VoiceID?)] = [], coalesceKey: String? = nil) -> EditCommand? {
        var cmd = assignCommand(pairs: reassign, name: name) ?? EditCommand(name: name)
        if newVoices != voices { cmd.voicesBefore = voices; cmd.voicesAfter = newVoices }
        cmd.coalesceKey = coalesceKey
        return (cmd.changes.isEmpty && cmd.voicesAfter == nil) ? nil : cmd
    }

    // MARK: Aplicar

    public mutating func apply(_ c: EditCommand, reverse: Bool = false) {
        if let target = reverse ? c.voicesBefore : c.voicesAfter { setVoicesKeepingPlayback(target) }
        if let n = reverse ? c.notesBefore : c.notesAfter { setNotes(n) }
        if reverse {
            for ch in c.changes.reversed() { notes[Int(ch.index)].voiceID = ch.from }
        } else {
            for ch in c.changes { notes[Int(ch.index)].voiceID = ch.to }
        }
    }

    /// Mute/solo no forman parte del historial: al deshacer se conserva el estado de reproducción actual.
    private mutating func setVoicesKeepingPlayback(_ target: [Voice]) {
        let current = Dictionary(voices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        voices = target.map { v in
            var v = v
            if let c = current[v.id] { v.isMuted = c.isMuted; v.isSolo = c.isSolo }
            return v
        }
        idCounter = max(idCounter, (voices.map(\.id).max() ?? 0) + 1)
    }

    /// Comando que sustituye todas las notas (se ordenan y renumeran). Las voces que ya no existan quedan sin asignar.
    public func notesCommand(_ newNotes: [Note], name: String) -> EditCommand? {
        let sorted = Self.normalize(newNotes, voices: voices)
        guard sorted != notes else { return nil }
        var c = EditCommand(name: name)
        c.notesBefore = notes
        c.notesAfter = sorted
        return c
    }

    /// Une varias voces en la primera (en el orden de la lista): sus notas pasan a ella y las demás desaparecen.
    public func joinCommand(_ ids: Set<VoiceID>, name: String) -> EditCommand? {
        let ordered = voices.filter { ids.contains($0.id) }
        guard ordered.count >= 2, let target = ordered.first else { return nil }
        let gone = Set(ordered.dropFirst().map(\.id))
        let moving = notes.indices.filter { notes[$0].voiceID.map(gone.contains) ?? false }
        return voicesCommand(voices.filter { !gone.contains($0.id) }, name: name, reassign: moving.map { ($0, target.id) })
    }

    static func normalize(_ list: [Note], voices: [Voice]) -> [Note] {
        let ids = Set(voices.map(\.id))
        var n = list.map { note -> Note in
            var note = note
            note.durationTick = max(1, note.durationTick)
            note.startTick = max(0, note.startTick)
            note.pitch = min(127, note.pitch)
            if let v = note.voiceID, !ids.contains(v) { note.voiceID = nil }
            return note
        }
        n.sortCanonically()
        for i in n.indices { n[i].id = i }
        return n
    }

    private mutating func setNotes(_ n: [Note]) {
        notes = n
        maxDuration = n.map(\.durationTick).max() ?? 0
        notesEdited = true
    }

    /// Restaurar notas editadas de una sesión guardada.
    public mutating func restore(notes saved: [Note], voices: [Voice]) {
        guard !voices.isEmpty else { return }
        self.voices = voices
        setNotes(Self.normalize(saved, voices: voices))
        idCounter = max(idCounter, (voices.map(\.id).max() ?? 0) + 1)
    }

    /// Cambio sin historial (mute/solo).
    public mutating func setPlaybackState(voice id: VoiceID, muted: Bool? = nil, solo: Bool? = nil) {
        guard let i = voiceIndex(id) else { return }
        if let m = muted { voices[i].isMuted = m }
        if let s = solo { voices[i].isSolo = s }
    }

    public mutating func setSoloExclusive(_ id: VoiceID?) {
        for i in voices.indices { voices[i].isSolo = voices[i].id == id }
    }

    /// Asignación directa durante un trazo de brocha (el Editor registra el diff).
    mutating func setVoice(_ v: VoiceID?, at i: Int) { notes[i].voiceID = v }

    /// Restaurar una sesión guardada (sin historial).
    public mutating func restore(voices: [Voice], assignments: [VoiceID?]) {
        guard assignments.count == notes.count, !voices.isEmpty else { return }
        self.voices = voices
        let ids = Set(voices.map(\.id))
        for i in notes.indices { notes[i].voiceID = assignments[i].flatMap { ids.contains($0) ? $0 : nil } }
        idCounter = max(idCounter, (voices.map(\.id).max() ?? 0) + 1)
    }

    // MARK: Búsqueda

    /// Índices de las notas que intersectan [fromTick, toTick] y [lowPitch, highPitch].
    public func indices(fromTick: Int, toTick: Int, lowPitch: Int = 0, highPitch: Int = 127) -> [Int] {
        var out: [Int] = []
        var lo = 0, hi = notes.count
        let minStart = fromTick - maxDuration
        while lo < hi { let mid = (lo + hi) / 2; if notes[mid].startTick < minStart { lo = mid + 1 } else { hi = mid } }
        var i = lo
        while i < notes.count, notes[i].startTick <= toTick {
            let n = notes[i]
            if n.endTick >= fromTick, Int(n.pitch) >= lowPitch, Int(n.pitch) <= highPitch { out.append(i) }
            i += 1
        }
        return out
    }
}

/// Documento + historial ilimitado de deshacer/rehacer.
public struct Editor: Sendable {
    public private(set) var document: SplitDocument
    public private(set) var undoStack: [EditCommand] = []
    public private(set) var redoStack: [EditCommand] = []
    private var stroke: (name: String, changes: [Int32: AssignmentChange], order: [Int32])?

    public init(document: SplitDocument) { self.document = document }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    @discardableResult
    public mutating func perform(_ c: EditCommand?) -> Bool {
        guard let c else { return false }
        endStroke()
        document.apply(c)
        if let key = c.coalesceKey, var top = undoStack.last, top.coalesceKey == key, top.changes.isEmpty, c.changes.isEmpty {
            top.voicesAfter = c.voicesAfter
            undoStack[undoStack.count - 1] = top
        } else {
            undoStack.append(c)
        }
        redoStack.removeAll()
        return true
    }

    /// Corta la fusión de comandos (al terminar de editar un campo).
    public mutating func breakCoalescing() {
        if var top = undoStack.last { top.coalesceKey = nil; undoStack[undoStack.count - 1] = top }
    }

    @discardableResult
    public mutating func undo() -> String? {
        endStroke()
        guard let c = undoStack.popLast() else { return nil }
        document.apply(c, reverse: true)
        redoStack.append(c)
        return c.name
    }

    @discardableResult
    public mutating func redo() -> String? {
        endStroke()
        guard let c = redoStack.popLast() else { return nil }
        document.apply(c)
        undoStack.append(c)
        return c.name
    }

    public mutating func setPlaybackState(voice id: VoiceID, muted: Bool? = nil, solo: Bool? = nil) { document.setPlaybackState(voice: id, muted: muted, solo: solo) }
    public mutating func setSoloExclusive(_ id: VoiceID?) { document.setSoloExclusive(id) }
    public mutating func makeVoiceID() -> VoiceID { document.makeVoiceID() }
    public mutating func restore(voices: [Voice], assignments: [VoiceID?]) { document.restore(voices: voices, assignments: assignments) }
    public mutating func restore(notes: [Note], voices: [Voice]) { document.restore(notes: notes, voices: voices) }

    // MARK: Trazos (brocha/borrador): todo el arrastre es un solo paso de deshacer.

    public mutating func beginStroke(name: String) {
        endStroke()
        stroke = (name, [:], [])
    }

    /// Devuelve true si cambió alguna nota.
    @discardableResult
    public mutating func strokeAssign(_ indices: [Int], to v: VoiceID?) -> Bool {
        guard stroke != nil else { return false }
        var changed = false
        for i in indices where document.notes.indices.contains(i) && document.notes[i].voiceID != v {
            let key = Int32(i)
            if var existing = stroke!.changes[key] { existing.to = v; stroke!.changes[key] = existing }
            else { stroke!.changes[key] = AssignmentChange(index: key, from: document.notes[i].voiceID, to: v); stroke!.order.append(key) }
            document.setVoice(v, at: i)
            changed = true
        }
        return changed
    }

    public var isStroking: Bool { stroke != nil }

    public mutating func endStroke() {
        guard let s = stroke else { return }
        stroke = nil
        let changes = s.order.compactMap { s.changes[$0] }.filter { $0.from != $0.to }
        guard !changes.isEmpty else { return }
        undoStack.append(EditCommand(name: s.name, changes: changes))
        redoStack.removeAll()
    }
}
