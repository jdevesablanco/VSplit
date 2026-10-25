import Foundation

/// Separación en voces "naturales": cada voz es una línea que podría tocar/cantar un solo instrumento.
/// La voz 0 es la más aguda (soprano) y la última la más grave (bajo).
///
/// Para cada acorde (ataques dentro de la ventana) se busca, con programación dinámica, el reparto de sus notas
/// entre las voces que respeta el orden agudo → grave (sin cruces) y minimiza:
///   - el salto de cada voz respecto a su nota anterior (los saltos grandes cuestan mucho más),
///   - meter una nota en una voz que todavía está sonando (una voz canta una nota cada vez),
///   - cruzarse con una nota sostenida de otra voz,
///   - meter varias notas en la misma voz (solo si hay más notas que voces).
/// El registro inicial de cada voz sale de los acordes completos (la nota más grave de cada uno ancla el bajo,
/// la más aguda la soprano…). Se hace una segunda pasada con los registros aprendidos en la primera.
public enum NaturalVoices {
    struct Line {
        var pitch: Double
        var end = Int.min
        var started = false
    }

    // MARK: Número de voces

    /// Cuántas voces hay: notas que suenan a la vez en cada ataque (contando las sostenidas), percentil 90.
    public static func detectCount(notes: [Note], indices: [Int], windowMs: Double, tempoMap: TempoMap) -> Int {
        guard !indices.isEmpty else { return 1 }
        let chords = ChordDetector.chords(notes: notes, indices: indices, windowMs: windowMs, tempoMap: tempoMap)
        let tol = tempoMap.ppq / 16
        var counts: [Int] = []
        var active: [Int] = []   // índices sonando
        var k = 0
        let order = indices
        for chord in chords {
            let t = chord.map { notes[$0].startTick }.max()!
            while k < order.count, notes[order[k]].startTick <= t { active.append(order[k]); k += 1 }
            active.removeAll { notes[$0].endTick <= t + tol }
            // Notas iguales (unísonos de distinto canal) cuentan una vez.
            counts.append(Set(active.map { notes[$0].pitch }).count)
        }
        counts.sort()
        let p90 = counts[min(counts.count - 1, Int(Double(counts.count) * 0.9))]
        return max(1, min(12, p90))
    }

    /// Nombres por papel según el número de voces (de agudo a grave).
    public static func roleNames(_ n: Int) -> [String] {
        let S = String(localized: "Soprano"), A = String(localized: "Alto"), T = String(localized: "Tenor"),
            Bar = String(localized: "Baritone"), B = String(localized: "Bass"), M = String(localized: "Middle")
        switch n {
        case 1: return [String(localized: "Voice")]
        case 2: return [S, B]
        case 3: return [S, M, B]
        case 4: return [S, A, T, B]
        case 5: return [S, A, T, Bar, B]
        case 6: return [S + " 1", S + " 2", A, T, Bar, B]
        case 7: return [S + " 1", S + " 2", A + " 1", A + " 2", T, Bar, B]
        case 8: return [S + " 1", S + " 2", A + " 1", A + " 2", T + " 1", T + " 2", B + " 1", B + " 2"]
        default: return [S] + (1..<(n - 1)).map { String(localized: "Voice \($0 + 1)") } + [B]
        }
    }

    /// Voces por papel con colores de la paleta y pan repartido (agudo a la izquierda).
    public static func defaultVoices(count n: Int, firstID: VoiceID = 1) -> [Voice] {
        roleNames(n).enumerated().map { i, name in
            let pan = n == 1 ? 0 : Int((-60 + 120 * Double(i) / Double(n - 1)).rounded())
            return Voice(id: firstID + i, name: name, color: Voice.palette[i % Voice.palette.count], pan: pan)
        }
    }

    // MARK: Reparto

    public static func assign(notes: [Note], indices: [Int], voices n: Int, windowMs: Double, tempoMap: TempoMap) -> [Int] {
        guard !indices.isEmpty else { return [] }
        let chords = ChordDetector.chords(notes: notes, indices: indices, windowMs: windowMs, tempoMap: tempoMap)
        var registers = initialRegisters(notes: notes, chords: chords, voices: n)
        var result: [Int: Int] = [:]
        for pass in 0..<2 {
            result = run(notes: notes, chords: chords, voices: n, registers: registers, tempoMap: tempoMap)
            guard pass == 0 else { break }
            // Registro aprendido: mediana de las notas de cada voz.
            var byVoice = [[Double]](repeating: [], count: n)
            for (i, v) in result { byVoice[v].append(Double(notes[i].pitch)) }
            for v in 0..<n where !byVoice[v].isEmpty { registers[v] = median(byVoice[v]) }
            registers = enforceOrder(registers)
        }
        return indices.map { result[$0] ?? 0 }
    }

    static func median(_ a: [Double]) -> Double {
        let s = a.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Registros estrictamente descendentes (agudo → grave), al menos un semitono de separación.
    static func enforceOrder(_ r: [Double]) -> [Double] {
        var r = r
        for v in 1..<max(1, r.count) where r[v] >= r[v - 1] { r[v] = r[v - 1] - 1 }
        return r
    }

    /// Ancla cada voz en la mediana de la j-ésima nota (de arriba abajo) de los acordes que tienen ≥ n notas;
    /// el bajo, en la mediana de la nota más grave de todos los acordes de varias notas.
    static func initialRegisters(notes: [Note], chords: [[Int]], voices n: Int) -> [Double] {
        var cols = [[Double]](repeating: [], count: n)
        var lows: [Double] = [], highs: [Double] = []
        for c in chords {
            let p = c.map { Double(notes[$0].pitch) }.sorted(by: >)
            if p.count >= 2 { highs.append(p.first!); lows.append(p.last!) }
            guard p.count >= n else { continue }
            // Con más notas que voces, la j-ésima voz toma la nota proporcional.
            for j in 0..<n { cols[j].append(p[n == 1 ? 0 : Int((Double(j) * Double(p.count - 1) / Double(n - 1)).rounded())]) }
        }
        var r: [Double]
        if cols.allSatisfy({ !$0.isEmpty }) {
            r = cols.map(median)
        } else {
            let all = chords.flatMap { $0 }.map { Double(notes[$0].pitch) }.sorted(by: >)
            r = (0..<n).map { j in all[min(all.count - 1, Int((Double(j) + 0.5) / Double(n) * Double(all.count)))] }
            if n > 1, !highs.isEmpty { r[0] = median(highs); r[n - 1] = median(lows) }
        }
        return enforceOrder(r)
    }

    static func leapCost(_ d: Double) -> Double {
        // Grados conjuntos casi gratis; a partir de una 5.ª y de la octava, cada semitono pesa más.
        d + max(0, d - 7) * 1.5 + max(0, d - 12) * 3
    }

    static func run(notes: [Note], chords: [[Int]], voices n: Int, registers: [Double], tempoMap: TempoMap) -> [Int: Int] {
        var lines = registers.map { Line(pitch: $0) }
        var result: [Int: Int] = [:]
        let tol = tempoMap.ppq / 16
        let longRest = tempoMap.ppq * 8
        for chord in chords {
            let sorted = chord.sorted { notes[$0].pitch != notes[$1].pitch ? notes[$0].pitch > notes[$1].pitch : $0 < $1 }
            let t = chord.map { notes[$0].startTick }.min()!
            let busy = lines.map { $0.started && $0.end > t + tol }
            let k = sorted.count

            func groupCost(_ v: Int, _ lo: Int, _ hi: Int) -> Double {
                if lo == hi {
                    // Voz sin nota en este acorde: natural si está sosteniendo; las extremas prefieren no callar.
                    if busy[v] { return 0 }
                    // Soprano y bajo libres casi siempre llevan la nota extrema: si no, todo el acorde se "corre" una voz.
                    return (v == 0 || v == n - 1) && n > 1 ? 12 : 1
                }
                var c = 0.0
                let line = lines[v]
                // Tras un silencio largo, la voz puede volver en otro sitio: el salto pesa menos, y tira de su registro.
                let rested = !line.started || t - line.end > longRest
                for idx in lo..<hi {
                    let p = Double(notes[sorted[idx]].pitch)
                    let ref = line.started ? line.pitch : registers[v]
                    c += rested ? 0.4 * leapCost(abs(p - ref)) + 0.6 * leapCost(abs(p - registers[v])) : leapCost(abs(p - ref))
                    // Desviarse mucho del registro propio también cuesta (mantiene al bajo abajo y a la soprano arriba).
                    c += 0.3 * max(0, abs(p - registers[v]) - 5)
                    for u in 0..<n where u != v && busy[u] {
                        if u < v && p > lines[u].pitch { c += 18 }   // por encima de una voz más aguda que sigue sonando
                        if u > v && p < lines[u].pitch { c += 18 }   // por debajo de una más grave
                    }
                }
                if busy[v] { c += 30 }
                c += Double(hi - lo - 1) * 25
                return c
            }

            // dp[j][i]: mejor coste repartiendo las i notas más agudas entre las j voces más agudas.
            let inf = Double.greatestFiniteMagnitude
            var dp = [[Double]](repeating: [Double](repeating: inf, count: k + 1), count: n + 1)
            var back = [[Int]](repeating: [Int](repeating: 0, count: k + 1), count: n + 1)
            dp[0][0] = 0
            for j in 1...n {
                for i in 0...k {
                    for g in 0...i where dp[j - 1][i - g] < inf {
                        let c = dp[j - 1][i - g] + groupCost(j - 1, i - g, i)
                        if c < dp[j][i] { dp[j][i] = c; back[j][i] = g }
                    }
                }
            }
            var i = k
            for j in stride(from: n, through: 1, by: -1) {
                let g = back[j][i]
                let v = j - 1
                if g > 0 {
                    var sum = 0.0, end = lines[v].end
                    for idx in (i - g)..<i {
                        result[sorted[idx]] = v
                        sum += Double(notes[sorted[idx]].pitch)
                        end = max(end, notes[sorted[idx]].endTick)
                    }
                    lines[v].pitch = sum / Double(g)
                    lines[v].end = end
                    lines[v].started = true
                }
                i -= g
            }
        }
        return result
    }
}
