#!/usr/bin/env swift
// Renders the app icon into Resources/Assets.xcassets/AppIcon.appiconset.
//
// The artwork is drawn from plain shapes (a rounded square with a shield and a gauge needle), so it
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
    func scaled(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: y * scale) }

    let body = NSRect(x: scaled(100), y: scaled(100), width: scaled(824), height: scaled(824))
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: scaled(186), yRadius: scaled(186))
    let background = NSGradient(
        starting: NSColor(srgbRed: 0.13, green: 0.62, blue: 0.71, alpha: 1),
        ending: NSColor(srgbRed: 0.21, green: 0.26, blue: 0.63, alpha: 1)
    )
    background?.draw(in: bodyPath, angle: -90)

    // A white shield carrying a gauge: a track, the used part of it in solid colour, and a needle.
    // No letters anywhere, so nothing in the icon can be mistaken for another brand.
    let ink = NSColor(srgbRed: 0.17, green: 0.24, blue: 0.60, alpha: 1)

    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: scaled(512), y: scaled(808)))
    shield.curve(to: NSPoint(x: scaled(282), y: scaled(742)),
                 controlPoint1: scaled(512, 808), controlPoint2: scaled(390, 790))
    shield.line(to: NSPoint(x: scaled(282), y: scaled(540)))
    shield.curve(to: NSPoint(x: scaled(512), y: scaled(222)),
                 controlPoint1: scaled(282, 380), controlPoint2: scaled(430, 290))
    shield.curve(to: NSPoint(x: scaled(742), y: scaled(540)),
                 controlPoint1: scaled(594, 290), controlPoint2: scaled(742, 380))
    shield.line(to: NSPoint(x: scaled(742), y: scaled(742)))
    shield.curve(to: NSPoint(x: scaled(512), y: scaled(808)),
                 controlPoint1: scaled(634, 790), controlPoint2: scaled(512, 808))
    shield.close()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowBlurRadius = scaled(30)
    shadow.shadowOffset = NSSize(width: 0, height: -scaled(14))
    shadow.set()
    NSColor.white.setFill()
    shield.fill()
    NSGraphicsContext.restoreGraphicsState()

    let center = NSPoint(x: scaled(512), y: scaled(530))
    let radius = scaled(150)
    let lineWidth = scaled(58)
    func arc(from start: CGFloat, to end: CGFloat, alpha: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        ink.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }
    let needleAngle: CGFloat = 38
    arc(from: 210, to: -30, alpha: 0.24)
    arc(from: 210, to: needleAngle, alpha: 1)

    let radians = needleAngle * .pi / 180
    let needle = NSBezierPath()
    needle.lineWidth = scaled(44)
    needle.lineCapStyle = .round
    needle.move(to: center)
    needle.line(to: NSPoint(x: center.x + cos(radians) * scaled(112), y: center.y + sin(radians) * scaled(112)))
    ink.setStroke()
    needle.stroke()
    let hub = scaled(40)
    ink.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)).fill()

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
