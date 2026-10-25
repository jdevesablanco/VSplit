import Foundation

/// Ajuste "inteligente" para dibujar y alargar notas: a la rejilla visible (según el zoom) y, si hay alguna cerca,
/// al inicio o final de otra nota.
public enum Snap {
    /// Unidad de rejilla en ticks para el zoom actual: 1/16, 1/8, pulso o compás.
    public static func gridUnit(pxPerTick: Double, beatTicks: Int, barTicks: Int) -> Int {
        let beatPx = Double(beatTicks) * pxPerTick
        if beatPx > 220 { return max(1, beatTicks / 4) }
        if beatPx > 110 { return max(1, beatTicks / 2) }
        if beatPx > 18 { return beatTicks }
        return barTicks
    }

    /// Ajusta `tick` a la línea de rejilla más cercana (contada desde `origin`) o a un imán (bordes de notas) si está
    /// más cerca que `tolerance`.
    public static func snap(_ tick: Int, unit: Int, origin: Int = 0, magnets: [Int] = [], tolerance: Int = 0) -> Int {
        if let m = magnets.min(by: { abs($0 - tick) < abs($1 - tick) }), abs(m - tick) <= tolerance { return m }
        guard unit > 1 else { return tick }
        let rel = Double(tick - origin) / Double(unit)
        return origin + Int(rel.rounded()) * unit
    }

    /// Hacia abajo (para el inicio de una nota nueva: cae en la casilla donde haces clic).
    public static func floor(_ tick: Int, unit: Int, origin: Int = 0) -> Int {
        guard unit > 1 else { return tick }
        return origin + Int((Double(tick - origin) / Double(unit)).rounded(.down)) * unit
    }
}
