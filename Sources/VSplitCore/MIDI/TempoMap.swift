import Foundation

/// Conversión tick ↔ segundos según los cambios de tempo, y compases/beats según los cambios de compás.
public struct TempoMap: Sendable, Equatable {
    public struct Tempo: Sendable, Equatable { public var tick: Int; public var microsecondsPerQuarter: Int; var seconds: Double }
    public struct Meter: Sendable, Equatable { public var tick: Int; public var numerator: Int; public var denominator: Int; public var bar: Int }

    public let ppq: Int
    public private(set) var tempos: [Tempo]
    public private(set) var meters: [Meter]

    public init(ppq: Int, events: [MIDIEvent]) {
        self.ppq = max(1, ppq)
        var t: [(Int, Int)] = []
        var m: [(Int, Int, Int)] = []
        for e in events {
            if let us = e.tempoMicroseconds, us > 0 { t.append((e.tick, us)) }
            if let ts = e.timeSignature { m.append((e.tick, ts.numerator, ts.denominator)) }
        }
        t.sort { $0.0 < $1.0 }
        m.sort { $0.0 < $1.0 }
        var tempos: [Tempo] = [Tempo(tick: 0, microsecondsPerQuarter: 500_000, seconds: 0)]
        for (tick, us) in t {
            if tick == tempos.last!.tick { tempos[tempos.count - 1].microsecondsPerQuarter = us; continue }
            let last = tempos.last!
            let secs = last.seconds + Double(tick - last.tick) / Double(self.ppq) * Double(last.microsecondsPerQuarter) / 1_000_000
            tempos.append(Tempo(tick: tick, microsecondsPerQuarter: us, seconds: secs))
        }
        self.tempos = tempos

        var meters: [Meter] = [Meter(tick: 0, numerator: 4, denominator: 4, bar: 0)]
        for (tick, num, den) in m {
            if tick == meters.last!.tick { meters[meters.count - 1].numerator = num; meters[meters.count - 1].denominator = den; continue }
            let last = meters.last!
            let barLen = last.numerator * self.ppq * 4 / last.denominator
            // Un cambio a mitad de compás empieza un compás nuevo en ese punto.
            let bars = Int((Double(tick - last.tick) / Double(max(1, barLen))).rounded(.up))
            meters.append(Meter(tick: tick, numerator: num, denominator: den, bar: last.bar + bars))
        }
        self.meters = meters
    }

    // MARK: Tiempo

    private func tempoIndex(atTick tick: Int) -> Int {
        var lo = 0, hi = tempos.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if tempos[mid].tick <= tick { lo = mid } else { hi = mid - 1 } }
        return lo
    }

    public func seconds(atTick tick: Int) -> Double {
        let t = tempos[tempoIndex(atTick: tick)]
        return t.seconds + Double(tick - t.tick) / Double(ppq) * Double(t.microsecondsPerQuarter) / 1_000_000
    }

    public func tick(atSeconds s: Double) -> Int {
        var lo = 0, hi = tempos.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if tempos[mid].seconds <= s { lo = mid } else { hi = mid - 1 } }
        let t = tempos[lo]
        return t.tick + Int(((s - t.seconds) * 1_000_000 / Double(t.microsecondsPerQuarter) * Double(ppq)).rounded())
    }

    /// Cuántos ticks hay en `ms` milisegundos a partir de `tick` (respeta los cambios de tempo).
    public func ticks(forMilliseconds ms: Double, from tick: Int) -> Int {
        max(0, self.tick(atSeconds: seconds(atTick: tick) + ms / 1000) - tick)
    }

    public func bpm(atTick tick: Int) -> Double { 60_000_000 / Double(tempos[tempoIndex(atTick: tick)].microsecondsPerQuarter) }
    public var initialBPM: Double { bpm(atTick: 0) }

    // MARK: Compases

    public func meter(atTick tick: Int) -> Meter {
        var lo = 0, hi = meters.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if meters[mid].tick <= tick { lo = mid } else { hi = mid - 1 } }
        return meters[lo]
    }

    public func barLength(_ m: Meter) -> Int { max(1, m.numerator * ppq * 4 / max(1, m.denominator)) }
    public func beatLength(_ m: Meter) -> Int { max(1, ppq * 4 / max(1, m.denominator)) }

    /// Compás (0-based), beat dentro del compás (0-based) y tick dentro del beat.
    public func position(atTick tick: Int) -> (bar: Int, beat: Int, tickInBeat: Int, barStart: Int) {
        let m = meter(atTick: tick)
        let len = barLength(m)
        let rel = max(0, tick - m.tick)
        let barsIn = rel / len
        let barStart = m.tick + barsIn * len
        let inBar = tick - barStart
        let bl = beatLength(m)
        return (m.bar + barsIn, inBar / bl, inBar % bl, barStart)
    }

    public func barStartTick(containing tick: Int) -> Int { position(atTick: tick).barStart }

    public struct Bar: Sendable { public var number: Int; public var startTick: Int; public var length: Int; public var beatLength: Int; public var numerator: Int; public var denominator: Int }

    /// Compases que intersectan [from, to).
    public func bars(from: Int, to: Int) -> [Bar] {
        var out: [Bar] = []
        var tick = barStartTick(containing: max(0, from))
        var guardCount = 0
        while tick < to && guardCount < 100_000 {
            let m = meter(atTick: tick)
            let p = position(atTick: tick)
            var len = barLength(m)
            // Cortar el compás si un cambio de compás cae antes de que termine.
            if let next = meters.first(where: { $0.tick > tick }), next.tick < tick + len { len = next.tick - tick }
            out.append(Bar(number: p.bar, startTick: tick, length: len, beatLength: beatLength(m), numerator: m.numerator, denominator: m.denominator))
            tick += len
            guardCount += 1
        }
        return out
    }
}
