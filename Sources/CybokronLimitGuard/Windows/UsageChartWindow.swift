import AppKit
import Charts
import LimitGuardCore
import SwiftUI

/// What the chart window draws; the engine fills it later, the temporary menu item builds it from files.
struct UsageChartContent {
    /// Nil when the usage report couldn't be read (or has no daily buckets): only the history shows.
    var report: UsageReport?
    var samples: [UsageSample]
    var weeklyResetsAt: Date?
    var now: Date = Date()
}

/// Swift Charts window: daily tokens (7/30/90 days) and the 5-hour / weekly limit history.
@MainActor
final class UsageChartWindowController: NSWindowController {
    private let model: UsageChartModel

    init(load: @escaping () async -> UsageChartContent) {
        let model = UsageChartModel(load: load)
        self.model = model
        let hostingController = NSHostingController(rootView: UsageChartView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.Chart.title
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 640))
        window.contentMinSize = NSSize(width: 480, height: 420)
        super.init(window: window)
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        if let window, !window.isVisible { window.center() }
        bringToFront()
        model.reload()
    }
}

@MainActor
private final class UsageChartModel: ObservableObject {
    @Published var content: UsageChartContent?
    @Published var days = 30
    @Published var loading = false
    @Published var timedOut = false
    private let load: () async -> UsageChartContent
    private var generation = 0
    private static let timeout: Duration = .seconds(20)

    init(load: @escaping () async -> UsageChartContent) { self.load = load }

    /// Loads with an overall timeout; a result that arrives after the timeout, or after a newer
    /// reload started, is dropped.
    func reload() {
        guard !loading else { return }
        generation += 1
        let generation = generation
        loading = true
        timedOut = false
        let loadTask = Task { await load() }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard !Task.isCancelled else { return }
            loadTask.cancel()
            self?.finish(generation, nil)
        }
        Task { [weak self] in
            let result = await loadTask.value
            timeoutTask.cancel()
            self?.finish(generation, result)
        }
    }

    private func finish(_ generation: Int, _ result: UsageChartContent?) {
        guard generation == self.generation, loading else { return }
        loading = false
        if let result { content = result } else { timedOut = true }
    }
}

private struct UsageChartView: View {
    @ObservedObject var model: UsageChartModel
    @Environment(\.colorScheme) private var scheme

    private static let ranges = [7, 30, 90]
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        let palette = PanelPalette.forScheme(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.timedOut {
                    Text(L10n.Chart.timedOut).foregroundStyle(PanelPalette.warning)
                }
                if let content = model.content {
                    if content.report?.daily != nil { dailySection(content, palette) }
                    historySection(content, palette)
                } else if !model.timedOut {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.Chart.loading).foregroundStyle(palette.secondaryText)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.solidBackground)
        .toolbar {
            ToolbarItem {
                Button { model.reload() } label: { Label(L10n.Chart.refresh, systemImage: "arrow.clockwise") }
                    .disabled(model.loading)
            }
        }
    }

    // MARK: Daily tokens

    @ViewBuilder
    private func dailySection(_ content: UsageChartContent, _ palette: PanelPalette) -> some View {
        let report = content.report ?? UsageReport(daily: nil, peakDailyTokens: nil, currentStreakDays: nil)
        let today = ChartData.today(content.now)
        let bars = ChartData.daily(report, days: model.days, today: today)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.Chart.dailyHeader).font(.headline)
                Spacer()
                Picker(L10n.Chart.range, selection: $model.days) {
                    ForEach(Self.ranges, id: \.self) { Text(L10n.Chart.days($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            Text(summary(report, bars)).font(.callout).foregroundStyle(palette.secondaryText)
            Chart(bars, id: \.day) { bar in
                BarMark(x: .value(L10n.Chart.dailyHeader, dayDate(bar.day), unit: .day), y: .value(L10n.Chart.axisTokens, bar.tokens))
                    .foregroundStyle(PanelPalette.teal)
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let tokens = value.as(Int64.self) { Text(ChartData.compactTokens(tokens)) }
                    }
                }
            }
            .frame(height: 200)
        }
    }

    private func summary(_ report: UsageReport, _ bars: [DailyUsage]) -> String {
        var parts: [String] = []
        if let peak = report.peakDailyTokens ?? bars.map(\.tokens).max() {
            parts.append(L10n.Chart.peak(ChartData.compactTokens(peak)))
        }
        if let streak = report.currentStreakDays { parts.append(L10n.Chart.streak(streak)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Limit history

    @ViewBuilder
    private func historySection(_ content: UsageChartContent, _ palette: PanelPalette) -> some View {
        let samples = ChartData.limitHistory(content.samples, days: model.days, now: content.now)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.Chart.historyHeader).font(.headline)
                Spacer()
                if content.report?.daily == nil {
                    Picker(L10n.Chart.range, selection: $model.days) {
                        ForEach(Self.ranges, id: \.self) { Text(L10n.Chart.days($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
            if samples.isEmpty {
                Text(L10n.Chart.noHistory).foregroundStyle(palette.secondaryText)
            } else {
                Chart {
                    ForEach(samples, id: \.date) { sample in
                        if let value = sample.fiveHour {
                            LineMark(x: .value(L10n.Chart.axisTime, sample.date), y: .value(L10n.Chart.axisPercent, value), series: .value(L10n.Chart.axisWindow, L10n.Chart.fiveHour))
                                .foregroundStyle(by: .value(L10n.Chart.axisWindow, L10n.Chart.fiveHour))
                        }
                        if let value = sample.weekly {
                            LineMark(x: .value(L10n.Chart.axisTime, sample.date), y: .value(L10n.Chart.axisPercent, value), series: .value(L10n.Chart.axisWindow, L10n.Chart.weekly))
                                .foregroundStyle(by: .value(L10n.Chart.axisWindow, L10n.Chart.weekly))
                        }
                    }
                }
                .chartForegroundStyleScale([L10n.Chart.fiveHour: PanelPalette.teal, L10n.Chart.weekly: PanelPalette.indigo])
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Int.self) { Text("\(v) %") } }
                    }
                }
                .frame(height: 200)
            }
            if let runOut = forecast(content, samples) {
                Text(L10n.Chart.forecast(Self.forecastFormatter.string(from: runOut)))
                    .font(.callout).foregroundStyle(palette.secondaryText)
            }
        }
    }

    /// Only a date still ahead of us counts.
    private func forecast(_ content: UsageChartContent, _ samples: [UsageSample]) -> Date? {
        let points = content.samples.compactMap { s in s.weekly.map { (s.date, $0) } }
        guard let date = Forecast.runOut(samples: points, now: content.now, resetsAt: content.weeklyResetsAt),
              date > content.now else { return nil }
        return date
    }

    private static let forecastFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return f
    }()

    // MARK: Days

    private func dayDate(_ day: String) -> Date { Self.dayFormatter.date(from: day) ?? Date() }
}
