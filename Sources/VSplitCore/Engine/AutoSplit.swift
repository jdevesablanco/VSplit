import Foundation

public enum SplitMode: String, Codable, CaseIterable, Sendable {
    /// auto = alternar de forma justa con 2 voces, líneas naturales con 3 o más.
    case auto, fairAlternate, natural, alternate, register, voiceLeading, channel, velocity, beat
}

public enum PitchOrder: String, Codable, CaseIterable, Sendable { case lowToHigh, highToLow }
public enum Remainder: String, Codable, CaseIterable, Sendable { case first, last }
public enum SinglesMode: String, Codable, CaseIterable, Sendable { case alternate, fixed }
public enum BeatUnit: String, Codable, CaseIterable, Sendable { case beat, halfBeat, bar }

public struct SplitParams: Codable, Equatable, Sendable {
    public var mode: SplitMode = .auto
    /// Ventana para agrupar ataques en un acorde (ms).
    public var chordWindowMs: Double = 35
    public var order: PitchOrder = .lowToHigh
    public var remainder: Remainder = .first
    public var continuePattern = false
    public var singles: SinglesMode = .alternate
    public var singlesVoice = 0
    public var registerAuto = true
    /// Puntos de corte (altura MIDI): la banda i empieza en splits[i-1].
    public var registerSplits: [Int] = []
    public var velocityAuto = true
    public var velocitySplits: [Int] = []
    public var beatUnit: BeatUnit = .beat

    public init() {}
}

public enum ChordDetector {
    /// Agrupa las notas (índices ordenados por inicio) en acordes: una nota entra en el acorde actual si su ataque
    /// cae dentro de la ventana contada desde el primer ataque del acorde (sin encadenar, para no fundir arpegios).
    public static func chords(notes: [Note], indices: [Int], windowMs: Double, tempoMap: TempoMap) -> [[Int]] {
        var out: [[Int]] = []
        var current: [Int] = []
        var limit = Int.min
        for i in indices {
            let t = notes[i].startTick
            if !current.isEmpty && t <= limit {
                current.append(i)
            } else {
                if !current.isEmpty { out.append(current) }
                current = [i]
                limit = t + tempoMap.ticks(forMilliseconds: max(0, windowMs), from: t)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Índice de acorde por nota (para seleccionar "acorde completo" y dibujar los recuadros).
    public static func chordIndex(notes: [Note], windowMs: Double, tempoMap: TempoMap) -> (chords: [[Int]], chordOf: [Int]) {
        let chords = chords(notes: notes, indices: Array(notes.indices), windowMs: windowMs, tempoMap: tempoMap)
        var of = [Int](repeating: 0, count: notes.count)
        for (c, members) in chords.enumerated() { for i in members { of[i] = c } }
        return (chords, of)
    }
}

public enum AutoSplitter {
    /// Calcula la voz (índice 0..<voiceCount) de cada nota de `indices` (deben ir ordenados por inicio).
    /// Devuelve un array paralelo a `indices`.
    public static func assign(notes: [Note], indices: [Int], voiceCount: Int, params p: SplitParams, tempoMap: TempoMap) -> [Int] {
        let n = max(1, voiceCount)
        guard !indices.isEmpty else { return [] }
        var result = [Int](repeating: 0, count: indices.count)
        var pos: [Int: Int] = [:]
        for (k, i) in indices.enumerated() { pos[i] = k }
        func flip(_ v: Int) -> Int { p.order == .lowToHigh ? v : n - 1 - v }

        switch p.mode {
        case .auto:
            var q = p
            q.mode = n == 2 ? .fairAlternate : .natural
            return assign(notes: notes, indices: indices, voiceCount: n, params: q, tempoMap: tempoMap)

        case .fairAlternate:
            result = fairAlternate(notes: notes, indices: indices, voices: n, windowMs: p.chordWindowMs, tempoMap: tempoMap, pos: pos)

        case .natural:
            result = NaturalVoices.assign(notes: notes, indices: indices, voices: n, windowMs: p.chordWindowMs, tempoMap: tempoMap)

        case .alternate:
            let chords = ChordDetector.chords(notes: notes, indices: indices, windowMs: p.chordWindowMs, tempoMap: tempoMap)
            var counter = 0        // patrón continuo entre acordes
            var singleCounter = 0  // notas sueltas alternando
            for chord in chords {
                let sorted = sortByPitch(chord, notes: notes, order: p.order)
                if sorted.count == 1 {
                    let v: Int
                    switch p.singles {
                    case .fixed: v = min(max(0, p.singlesVoice), n - 1)
                    case .alternate: v = (p.continuePattern ? counter : singleCounter) % n
                    }
                    singleCounter += 1
                    if p.continuePattern { counter += 1 }
                    result[pos[sorted[0]]!] = v
                    continue
                }
                var start = 0
                if p.continuePattern {
                    start = counter % n
                } else if p.remainder == .last, sorted.count % n != 0 {
                    // Rotar para que las notas sobrantes caigan en las últimas voces sin romper la alternancia.
                    start = n - sorted.count % n
                }
                for (k, i) in sorted.enumerated() { result[pos[i]!] = (start + k) % n }
                counter += sorted.count
            }

        case .register:
            let splits = p.registerAuto ? quantileSplits(indices.map { Int(notes[$0].pitch) }, bands: n) : normalized(p.registerSplits, bands: n, range: 0...127)
            for (k, i) in indices.enumerated() { result[k] = flip(band(Int(notes[i].pitch), splits: splits)) }

        case .velocity:
            let splits = p.velocityAuto ? quantileSplits(indices.map { Int(notes[$0].velocity) }, bands: n) : normalized(p.velocitySplits, bands: n, range: 1...127)
            for (k, i) in indices.enumerated() { result[k] = flip(band(Int(notes[i].velocity), splits: splits)) }

        case .channel:
            let chans = Array(Set(indices.map { notes[$0].channel })).sorted()
            let rank = Dictionary(uniqueKeysWithValues: chans.enumerated().map { ($1, $0) })
            for (k, i) in indices.enumerated() { result[k] = rank[notes[i].channel]! % n }

        case .beat:
            for (k, i) in indices.enumerated() {
                // Una nota que entra un poco antes del pulso (dentro de la ventana de acorde) cuenta para ese pulso.
                let t0 = notes[i].startTick
                let t = t0 + tempoMap.ticks(forMilliseconds: p.chordWindowMs, from: t0)
                let pos = tempoMap.position(atTick: t)
                let idx: Int
                switch p.beatUnit {
                case .bar: idx = pos.bar
                case .beat: idx = pos.beat
                case .halfBeat: idx = (t - pos.barStart) / max(1, tempoMap.beatLength(tempoMap.meter(atTick: t)) / 2)
                }
                result[k] = idx % n
            }

        case .voiceLeading:
            result = voiceLeading(notes: notes, indices: indices, voices: n, params: p, tempoMap: tempoMap, pos: pos)
        }
        return result
    }

    /// Alterna las notas de cada acorde (grave → agudo) entre las voces, eligiendo por qué voz empieza para que
    /// el total quede lo más repartido posible y cada voz se mueva lo menos posible respecto a su acorde anterior.
    static func fairAlternate(notes: [Note], indices: [Int], voices n: Int, windowMs: Double, tempoMap: TempoMap, pos: [Int: Int]) -> [Int] {
        var result = [Int](repeating: 0, count: indices.count)
        var counts = [Int](repeating: 0, count: n)
        var last = [Double?](repeating: nil, count: n)
        for chord in ChordDetector.chords(notes: notes, indices: indices, windowMs: windowMs, tempoMap: tempoMap) {
            let sorted = sortByPitch(chord, notes: notes, order: .lowToHigh)
            var best = (cost: Double.greatestFiniteMagnitude, r: 0)
            for r in 0..<n {
                var c = counts
                var sum = [Double](repeating: 0, count: n), cnt = [Int](repeating: 0, count: n)
                for (j, i) in sorted.enumerated() {
                    let v = (r + j) % n
                    c[v] += 1; sum[v] += Double(notes[i].pitch); cnt[v] += 1
                }
                var cost = Double(c.max()! - c.min()!) * 4
                for v in 0..<n where cnt[v] > 0 { if let l = last[v] { cost += abs(sum[v] / Double(cnt[v]) - l) * 0.35 } }
                cost += Double(r) * 0.01
                if cost < best.cost { best = (cost, r) }
            }
            var sum = [Double](repeating: 0, count: n), cnt = [Int](repeating: 0, count: n)
            for (j, i) in sorted.enumerated() {
                let v = (best.r + j) % n
                result[pos[i]!] = v
                counts[v] += 1; sum[v] += Double(notes[i].pitch); cnt[v] += 1
            }
            for v in 0..<n where cnt[v] > 0 { last[v] = sum[v] / Double(cnt[v]) }
        }
        return result
    }

    static func sortByPitch(_ chord: [Int], notes: [Note], order: PitchOrder) -> [Int] {
        chord.sorted { a, b in
            let pa = notes[a].pitch, pb = notes[b].pitch
            if pa != pb { return order == .lowToHigh ? pa < pb : pa > pb }
            return notes[a].startTick != notes[b].startTick ? notes[a].startTick < notes[b].startTick : a < b
        }
    }

    /// Cortes que reparten los valores en `bands` grupos de tamaño parecido.
    public static func quantileSplits(_ values: [Int], bands: Int) -> [Int] {
        guard bands > 1, !values.isEmpty else { return [] }
        let s = values.sorted()
        var splits: [Int] = []
        for b in 1..<bands {
            let idx = min(s.count - 1, Int((Double(s.count) * Double(b) / Double(bands)).rounded()))
            var v = s[idx]
            if let last = splits.last, v <= last { v = last + 1 }
            splits.append(v)
        }
        return splits
    }

    /// Cortes manuales: tantos como bandas−1, ordenados; si faltan se reparten por el rango.
    public static func normalized(_ splits: [Int], bands: Int, range: ClosedRange<Int>) -> [Int] {
        guard bands > 1 else { return [] }
        var s = splits.sorted()
        if s.count > bands - 1 { s = Array(s.prefix(bands - 1)) }
        if s.count < bands - 1 {
            let span = Double(range.upperBound - range.lowerBound)
            s = (1..<bands).map { range.lowerBound + Int(span * Double($0) / Double(bands)) }
        }
        return s
    }

    static func band(_ value: Int, splits: [Int]) -> Int { splits.reduce(0) { $0 + (value >= $1 ? 1 : 0) } }

    /// Cada acorde se asigna minimizando la suma de saltos respecto a la última nota de cada voz
    /// (asignación óptima con el algoritmo húngaro), penalizando usar una voz que aún está sonando.
    static func voiceLeading(notes: [Note], indices: [Int], voices n: Int, params p: SplitParams, tempoMap: TempoMap, pos: [Int: Int]) -> [Int] {
        var result = [Int](repeating: 0, count: indices.count)
        let pitches = indices.map { Double(notes[$0].pitch) }.sorted()
        // Posición inicial de cada voz: cuantiles del registro (voz 0 = grave si el orden es grave→agudo).
        var last: [Double] = (0..<n).map { v in
            let q = (Double(v) + 0.5) / Double(n)
            let x = pitches[min(pitches.count - 1, Int(q * Double(pitches.count)))]
            return x
        }
        if p.order == .highToLow { last.reverse() }
        var lastEnd = [Int](repeating: Int.min, count: n)
        let chords = ChordDetector.chords(notes: notes, indices: indices, windowMs: p.chordWindowMs, tempoMap: tempoMap)
        for chord in chords {
            let sorted = sortByPitch(chord, notes: notes, order: .lowToHigh)
            let k = sorted.count
            let copies = (k + n - 1) / n
            let cols = n * copies
            var cost = [[Double]](repeating: [Double](repeating: 0, count: cols), count: k)
            for (r, i) in sorted.enumerated() {
                let nt = notes[i]
                for c in 0..<cols {
                    let v = c % n
                    var x = abs(Double(nt.pitch) - last[v])
                    if lastEnd[v] > nt.startTick + p.ppqTolerance(tempoMap) { x += 12 }
                    // Pequeña preferencia por mantener el orden de voces (evita cruces).
                    x += Double(c / n) * 0.01
                    cost[r][c] = x
                }
            }
            let match = Hungarian.solve(cost)
            var sums = [Double](repeating: 0, count: n), cnt = [Int](repeating: 0, count: n)
            for (r, i) in sorted.enumerated() {
                let v = match[r] % n
                result[pos[i]!] = v
                sums[v] += Double(notes[i].pitch); cnt[v] += 1
                lastEnd[v] = max(lastEnd[v], notes[i].endTick)
            }
            for v in 0..<n where cnt[v] > 0 { last[v] = sums[v] / Double(cnt[v]) }
        }
        return result
    }
}

extension SplitParams {
    /// Solape tolerado antes de considerar que una voz "sigue sonando" (legato humano ≈ 1/16 de negra).
    func ppqTolerance(_ map: TempoMap) -> Int { map.ppq / 16 }
}

/// Algoritmo húngaro (Kuhn–Munkres) para matrices filas ≤ columnas. Devuelve la columna asignada a cada fila.
public enum Hungarian {
    public static func solve(_ cost: [[Double]]) -> [Int] {
        let rows = cost.count
        guard rows > 0 else { return [] }
        let cols = cost[0].count
        precondition(cols >= rows)
        let inf = Double.greatestFiniteMagnitude / 4
        var u = [Double](repeating: 0, count: rows + 1), v = [Double](repeating: 0, count: cols + 1)
        var p = [Int](repeating: 0, count: cols + 1), way = [Int](repeating: 0, count: cols + 1)
        for i in 1...rows {
            p[0] = i
            var j0 = 0
            var minv = [Double](repeating: inf, count: cols + 1)
            var used = [Bool](repeating: false, count: cols + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = inf, j1 = 0
                for j in 1...cols where !used[j] {
                    let cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...cols {
                    if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
                }
                j0 = j1
            } while p[j0] != 0
            repeat { let j1 = way[j0]; p[j0] = p[j1]; j0 = j1 } while j0 != 0
        }
        var ans = [Int](repeating: 0, count: rows)
        for j in 1...cols where p[j] != 0 { ans[p[j] - 1] = j - 1 }
        return ans
    }
}
