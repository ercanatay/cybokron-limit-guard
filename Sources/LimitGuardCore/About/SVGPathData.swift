import CoreGraphics
import Foundation

/// Parses SVG path data (the `d` attribute of an SVG `<path>`) into a `CGPath`, in the SVG's own
/// coordinates (y grows downward).
///
/// SwiftUI's `Path(_: String)` does not read SVG path data: it only parses the format of
/// `Path.description` and returns `nil` for anything else.
///
/// Supports every SVG 1.1 path command (M L H V C S Q T A Z, absolute and relative), implicit
/// repeated commands, and compact number syntax (`.5.5`, `-1-2`, `1e-3`, arc flags without
/// separators such as `a1 1 0 001 1`).
public enum SVGPathData {
    /// The path, or `nil` when `data` is empty or malformed.
    public static func path(from data: String) -> CGPath? {
        var parser = SVGPathParser(bytes: Array(data.utf8))
        return parser.parse()
    }
}

private struct SVGPathParser {
    let bytes: [UInt8]
    var index = 0
    let path = CGMutablePath()
    var current = CGPoint.zero
    var subpathStart = CGPoint.zero
    /// The second control point of the previous C/S segment, for S's reflected first one.
    var lastCubicControl: CGPoint?
    /// The control point of the previous Q/T segment, for T's reflected one.
    var lastQuadControl: CGPoint?

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parse() -> CGPath? {
        skipSeparators()
        // Path data must begin with a moveto.
        guard index < bytes.count, bytes[index] == UInt8(ascii: "M") || bytes[index] == UInt8(ascii: "m") else {
            return nil
        }
        var command: UInt8?
        while true {
            skipSeparators()
            guard index < bytes.count else { break }
            let byte = bytes[index]
            if Self.isCommand(byte) {
                command = byte
                index += 1
            }
            // A number without a command first (or after Z, which takes none) is malformed.
            guard let active = command, perform(active) else { return nil }
            switch active {
            // Coordinates repeated after a moveto are implicit linetos.
            case UInt8(ascii: "M"): command = UInt8(ascii: "L")
            case UInt8(ascii: "m"): command = UInt8(ascii: "l")
            case UInt8(ascii: "Z"), UInt8(ascii: "z"): command = nil
            default: break
            }
        }
        return path.isEmpty ? nil : path.copy()
    }

    // MARK: - Commands

    /// Reads the arguments of one `command` segment and adds it. Returns `false` when they are
    /// missing or malformed.
    private mutating func perform(_ command: UInt8) -> Bool {
        let relative = command >= UInt8(ascii: "a")
        let origin = relative ? current : .zero
        var cubicControl: CGPoint?
        var quadControl: CGPoint?

        switch command | 0x20 {  // lowercase
        case UInt8(ascii: "m"):
            guard let point = point(relativeTo: origin) else { return false }
            path.move(to: point)
            current = point
            subpathStart = point
        case UInt8(ascii: "l"):
            guard let point = point(relativeTo: origin) else { return false }
            path.addLine(to: point)
            current = point
        case UInt8(ascii: "h"):
            guard let x = number() else { return false }
            current = CGPoint(x: x + origin.x, y: current.y)
            path.addLine(to: current)
        case UInt8(ascii: "v"):
            guard let y = number() else { return false }
            current = CGPoint(x: current.x, y: y + origin.y)
            path.addLine(to: current)
        case UInt8(ascii: "c"):
            guard let control1 = point(relativeTo: origin), let control2 = point(relativeTo: origin),
                  let end = point(relativeTo: origin)
            else { return false }
            path.addCurve(to: end, control1: control1, control2: control2)
            cubicControl = control2
            current = end
        case UInt8(ascii: "s"):
            guard let control2 = point(relativeTo: origin), let end = point(relativeTo: origin) else { return false }
            let control1 = lastCubicControl.map { reflect($0) } ?? current
            path.addCurve(to: end, control1: control1, control2: control2)
            cubicControl = control2
            current = end
        case UInt8(ascii: "q"):
            guard let control = point(relativeTo: origin), let end = point(relativeTo: origin) else { return false }
            path.addQuadCurve(to: end, control: control)
            quadControl = control
            current = end
        case UInt8(ascii: "t"):
            guard let end = point(relativeTo: origin) else { return false }
            let control = lastQuadControl.map { reflect($0) } ?? current
            path.addQuadCurve(to: end, control: control)
            quadControl = control
            current = end
        case UInt8(ascii: "a"):
            guard let rx = number(), let ry = number(), let rotation = number(),
                  let largeArc = flag(), let sweep = flag(), let end = point(relativeTo: origin)
            else { return false }
            addArc(radiusX: rx, radiusY: ry, rotation: rotation, largeArc: largeArc, sweep: sweep, to: end)
            current = end
        case UInt8(ascii: "z"):
            path.closeSubpath()
            current = subpathStart
        default:
            return false
        }
        lastCubicControl = cubicControl
        lastQuadControl = quadControl
        return true
    }

    private func reflect(_ control: CGPoint) -> CGPoint {
        CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
    }

    /// An elliptical arc from `current` to `end`, as cubic Béziers of at most 90° each
    /// (SVG 1.1, appendix F.6.5: endpoint to center parameterization).
    private mutating func addArc(radiusX: CGFloat, radiusY: CGFloat, rotation: CGFloat,
                                 largeArc: Bool, sweep: Bool, to end: CGPoint) {
        let start = current
        guard start != end else { return }
        var rx = abs(radiusX)
        var ry = abs(radiusY)
        guard rx > 0, ry > 0 else {
            path.addLine(to: end)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let halfDX = (start.x - end.x) / 2
        let halfDY = (start.y - end.y) / 2
        let x1 = cosPhi * halfDX + sinPhi * halfDY
        let y1 = -sinPhi * halfDX + cosPhi * halfDY

        // Radii too small to reach the end point are scaled up just enough.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coefficient = max(0, numerator / denominator).squareRoot()
        if largeArc == sweep {
            coefficient = -coefficient
        }
        let centerX1 = coefficient * rx * y1 / ry
        let centerY1 = -coefficient * ry * x1 / rx
        let center = CGPoint(x: cosPhi * centerX1 - sinPhi * centerY1 + (start.x + end.x) / 2,
                             y: sinPhi * centerX1 + cosPhi * centerY1 + (start.y + end.y) / 2)

        let ux = (x1 - centerX1) / rx
        let uy = (y1 - centerY1) / ry
        let vx = (-x1 - centerX1) / rx
        let vy = (-y1 - centerY1) / ry
        let startAngle = atan2(uy, ux)
        var sweepAngle = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        if !sweep, sweepAngle > 0 {
            sweepAngle -= 2 * .pi
        } else if sweep, sweepAngle < 0 {
            sweepAngle += 2 * .pi
        }

        // A point of the unit circle, on the ellipse.
        func onEllipse(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: center.x + rx * x * cosPhi - ry * y * sinPhi,
                    y: center.y + rx * x * sinPhi + ry * y * cosPhi)
        }
        let segments = max(1, Int((abs(sweepAngle) / (.pi / 2)).rounded(.up)))
        let step = sweepAngle / CGFloat(segments)
        let handle = 4.0 / 3.0 * tan(step / 4)
        var angle = startAngle
        for segment in 0..<segments {
            let next = angle + step
            let control1 = onEllipse(cos(angle) - handle * sin(angle), sin(angle) + handle * cos(angle))
            let control2 = onEllipse(cos(next) + handle * sin(next), sin(next) - handle * cos(next))
            let point = segment == segments - 1 ? end : onEllipse(cos(next), sin(next))
            path.addCurve(to: point, control1: control1, control2: control2)
            angle = next
        }
    }

    // MARK: - Tokens

    private mutating func point(relativeTo origin: CGPoint) -> CGPoint? {
        guard let x = number(), let y = number() else { return nil }
        return CGPoint(x: x + origin.x, y: y + origin.y)
    }

    /// The next number: an optional sign, digits with an optional fraction, an optional exponent.
    /// A second `.` or a sign starts the next number, as in `.5.5` or `1-2`.
    private mutating func number() -> CGFloat? {
        skipSeparators()
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        var digits = skipDigits()
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            digits += skipDigits()
        }
        guard digits > 0 else {
            index = start
            return nil
        }
        if index < bytes.count, bytes[index] | 0x20 == UInt8(ascii: "e") {
            var exponent = index + 1
            if exponent < bytes.count, bytes[exponent] == UInt8(ascii: "+") || bytes[exponent] == UInt8(ascii: "-") {
                exponent += 1
            }
            if exponent < bytes.count, Self.isDigit(bytes[exponent]) {
                index = exponent
                _ = skipDigits()
            }
        }
        guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)), value.isFinite else {
            index = start
            return nil
        }
        return CGFloat(value)
    }

    /// An arc flag: a single `0` or `1`, which needs no separator from what follows.
    private mutating func flag() -> Bool? {
        skipSeparators()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "0"): index += 1; return false
        case UInt8(ascii: "1"): index += 1; return true
        default: return nil
        }
    }

    private mutating func skipDigits() -> Int {
        let start = index
        while index < bytes.count, Self.isDigit(bytes[index]) {
            index += 1
        }
        return index - start
    }

    private mutating func skipSeparators() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0C, 0x0D, UInt8(ascii: ","): index += 1
            default: return
            }
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func isCommand(_ byte: UInt8) -> Bool {
        switch byte | 0x20 {
        case UInt8(ascii: "m"), UInt8(ascii: "l"), UInt8(ascii: "h"), UInt8(ascii: "v"), UInt8(ascii: "c"),
             UInt8(ascii: "s"), UInt8(ascii: "q"), UInt8(ascii: "t"), UInt8(ascii: "a"), UInt8(ascii: "z"):
            return byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "z")
        default:
            return false
        }
    }
}
