#!/usr/bin/env swift
// Genera AppIcon.icns: la imagen de fondo (Resources/Background.jpg) en un squircle con la "V" de dos haces de luz.
// Uso: swift Scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let bgImage = NSImage(contentsOfFile: "Resources/Background.jpg")

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    let box = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bg = CGPath(roundedRect: box, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(bg); ctx.setFillColor(CGColor(gray: 0.02, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(bg); ctx.clip()
    if let img = bgImage, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        // Recorte cuadrado centrado de la foto.
        let side = min(cg.width, cg.height)
        if let crop = cg.cropping(to: CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)) {
            ctx.draw(crop, in: box)
        }
    }
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.35)); ctx.fill(box)
    // "V" con resplandor
    func stroke(_ a: CGPoint, _ b: CGPoint, _ c1: CGColor, _ c2: CGColor) {
        let p = CGMutablePath(); p.move(to: a); p.addLine(to: b)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 60, color: c2)
        ctx.setLineCap(.round); ctx.setLineWidth(70); ctx.setStrokeColor(c2); ctx.addPath(p); ctx.strokePath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setLineCap(.round); ctx.setLineWidth(40); ctx.addPath(p); ctx.replacePathWithStrokedPath(); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c1, c2] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: a, end: b, options: [])
        ctx.restoreGState()
    }
    stroke(CGPoint(x: 300, y: 760), CGPoint(x: 512, y: 270), CGColor(red: 0.75, green: 0.88, blue: 1, alpha: 1), CGColor(red: 0.29, green: 0.6, blue: 1, alpha: 1))
    stroke(CGPoint(x: 724, y: 760), CGPoint(x: 512, y: 270), CGColor(red: 1, green: 0.85, blue: 0.5, alpha: 1), CGColor(red: 1, green: 0.42, blue: 0.16, alpha: 1))
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let set = (out as NSString).deletingLastPathComponent + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                               ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (n, px) in sizes { try! render(px).write(to: URL(fileURLWithPath: "\(set)/icon_\(n).png")) }
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); p.arguments = ["-c", "icns", set, "-o", out]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(atPath: set)
print("OK", out)
