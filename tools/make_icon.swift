#!/usr/bin/env swift
// Draws the app icon at every size and writes the asset catalog.
// Usage: swift tools/make_icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appendingPathComponent("App/Assets.xcassets")
let iconset = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// A warm cream keycap on deep teal, with rings of sound spreading out from under it.
func draw(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Standard macOS icon grid: 824pt body inside a 1024pt canvas.
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(red: 0.05, green: 0.27, blue: 0.31, alpha: 1),
                        NSColor(red: 0.03, green: 0.14, blue: 0.20, alpha: 1)])!.draw(in: body, angle: -90)

    ctx.saveGState()
    body.addClip()
    for (i, radius) in [270.0, 345.0, 420.0].enumerated() {
        let ring = NSBezierPath(ovalIn: NSRect(x: 512 - radius, y: 490 - radius, width: radius * 2, height: radius * 2))
        NSColor(red: 0.45, green: 0.90, blue: 0.82, alpha: 0.55 - Double(i) * 0.16).setStroke()
        ring.lineWidth = 15
        ring.stroke()
    }
    ctx.restoreGState()

    // Keycap: skirt, then the dished top face.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
    shadow.shadowBlurRadius = 34
    shadow.shadowOffset = NSSize(width: 0, height: -20)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(red: 0.79, green: 0.69, blue: 0.56, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 322, y: 300, width: 380, height: 400), xRadius: 72, yRadius: 72).fill()
    NSGraphicsContext.restoreGraphicsState()
    let top = NSBezierPath(roundedRect: NSRect(x: 362, y: 374, width: 300, height: 304), xRadius: 56, yRadius: 56)
    NSGradient(colors: [NSColor(red: 0.99, green: 0.95, blue: 0.87, alpha: 1),
                        NSColor(red: 0.91, green: 0.83, blue: 0.71, alpha: 1)])!.draw(in: top, angle: -90)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (point, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = point * scale
    let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
    try draw(size: pixels).write(to: iconset.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(point)x\(point)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconset.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: .prettyPrinted)
    .write(to: catalog.appendingPathComponent("Contents.json"))
print("wrote \(iconset.path)")
