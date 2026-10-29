import Foundation

/// Burn-rate forecast for a usage window (spec §12, D28). Pure; samples are (time, usedPercent 0–100).
public enum Forecast {
    static let lookback: TimeInterval = 6 * 3600
    static let minSpan: TimeInterval = 2 * 3600
    static let minSamples = 3
    /// A drop larger than this between neighbouring samples means the window reset.
    static let resetDrop = 5.0

    /// When the fitted line reaches 100 %, or nil when there is no trustworthy positive trend, the
    /// window is already full, or the limit would reset first.
    public static func runOut(samples: [(Date, Double)], now: Date, resetsAt: Date?) -> Date? {
        var recent = samples
            .filter { $0.0 >= now.addingTimeInterval(-lookback) && $0.0 <= now }
            .sorted { $0.0 < $1.0 }
        if let resetIndex = (1..<max(recent.count, 1)).last(where: { recent[$0 - 1].1 - recent[$0].1 > resetDrop }) {
            recent.removeFirst(resetIndex)
        }
        guard recent.count >= minSamples, let first = recent.first, let last = recent.last,
              last.0.timeIntervalSince(first.0) >= minSpan, last.1 < 100 else { return nil }

        // Ordinary least squares on hours since the first sample.
        let xs = recent.map { $0.0.timeIntervalSince(first.0) / 3600 }
        let ys = recent.map(\.1)
        let n = Double(recent.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        let sxx = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        guard sxx > 0 else { return nil }
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let slope = sxy / sxx
        guard slope > 0 else { return nil }

        let latestFitted = meanY + slope * ((xs.last ?? 0) - meanX)
        let hoursLeft = (100 - latestFitted) / slope
        guard hoursLeft.isFinite, hoursLeft >= 0 else { return nil }
        let projected = last.0.addingTimeInterval(hoursLeft * 3600)
        if let resetsAt, projected > resetsAt { return nil }
        return projected
    }
}
