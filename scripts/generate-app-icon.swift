#!/usr/bin/env swift
// Renders the placeholder app icon into Resources/Assets.xcassets/AppIcon.appiconset.
//
// The artwork is drawn from plain shapes (a rounded square with a gauge ring), so it
// contains no third-party artwork and no SF Symbols (Apple's license doesn't allow SF Symbols in
// app icons). Usage, from the repository root:
//
//     swift scripts/generate-app-icon.swift
import AppKit

let outputDirectory = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

/// (file name, pixel size, point size, scale) in iconutil's `.iconset` naming scheme.
let variants: [(file: String, pixels: Int, points: Int, scale: Int)] = [16, 32, 128, 256, 512].flatMap { points in
    [
        (file: "icon_\(points)x\(points).png", pixels: points, points: points, scale: 1),
        (file: "icon_\(points)x\(points)@2x.png", pixels: points * 2, points: points, scale: 2),
    ]
}

func renderIcon(pixels: Int) -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("Couldn't create a \(pixels)px bitmap") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Drawn on Apple's 1024-point macOS icon grid: an 824-point body inset by 100 points.
    let scale = CGFloat(pixels) / 1024
    func scaled(_ value: CGFloat) -> CGFloat { value * scale }

    let body = NSRect(x: scaled(100), y: scaled(100), width: scaled(824), height: scaled(824))
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: scaled(186), yRadius: scaled(186))
    let background = NSGradient(
        starting: NSColor(srgbRed: 0.13, green: 0.62, blue: 0.71, alpha: 1),
        ending: NSColor(srgbRed: 0.21, green: 0.26, blue: 0.63, alpha: 1)
    )
    background?.draw(in: bodyPath, angle: -90)

    // A gauge: a translucent ring with a solid arc covering most of it.
    let center = NSPoint(x: CGFloat(pixels) / 2, y: CGFloat(pixels) / 2)
    let radius = scaled(250)
    let ring = NSBezierPath()
    ring.lineWidth = scaled(84)
    ring.lineCapStyle = .round
    ring.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    NSColor(white: 1, alpha: 0.35).setStroke()
    ring.stroke()
    let arc = NSBezierPath()
    arc.lineWidth = scaled(84)
    arc.lineCapStyle = .round
    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: -160, clockwise: true)
    NSColor(white: 1, alpha: 1).setStroke()
    arc.stroke()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Couldn't encode a \(pixels)px PNG")
    }
    return png
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
var images: [[String: String]] = []
for variant in variants {
    try renderIcon(pixels: variant.pixels).write(to: outputDirectory.appendingPathComponent(variant.file))
    images.append([
        "filename": variant.file,
        "idiom": "mac",
        "scale": "\(variant.scale)x",
        "size": "\(variant.points)x\(variant.points)",
    ])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(variants.count) icon images to \(outputDirectory.path)")
