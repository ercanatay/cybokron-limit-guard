import Foundation
import OSLog

/// Orchestrates limit polling, session scanning, auto-continue and reset spending (spec §5, §7, §8).
///
/// Everything happens in `tick()`; `start()` only runs it on a timer. Public operations are serialised,
/// so a tick, a manual continue and a manual spend never interleave across their `await`s. The Engine
/// is the only writer of `state.json`, `activity.json`, `usage-history.json` and the reset ledger; it
/// only reads the settings.
@MainActor
public final class Engine: ObservableObject {
    public struct Dependencies {
        public var clock: EngineClock
        public var environment: EngineEnvironment
        /// Reads and consume over the private stdio `codex app-server`.
        public var account: CodexAccountService
        public var sessions: SessionSource
        /// Delivery over the shared daemon (`AppServerDelivery`).
        public var delivery: EngineDelivery
        public var dataDirectory: URL
        /// Read before every tick; an unreadable file must give defaults (notice not accepted: no actions).
        public var settings: @MainActor () -> Settings
        /// `codex --version`, recorded in every activity entry.
        public var codexVersion: String?
        /// The reset executor's wait between consume retries.
        public var resetSleeper: @Sendable (Duration) async -> Void

        public init(
            clock: EngineClock, environment: EngineEnvironment, account: CodexAccountService,
            sessions: SessionSource, delivery: EngineDelivery, dataDirectory: URL,
            settings: @escaping @MainActor () -> Settings, codexVersion: String? = nil,
            resetSleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        ) {
            self.clock = clock
            self.environment = environment
            self.account = account
            self.sessions = sessions
            self.delivery = delivery
            self.dataDirectory = dataDirectory
            self.settings = settings
            self.codexVersion = codexVersion
            self.resetSleeper = resetSleeper
        }
    }

    public static let stateFileName = "state.json"
    public static let activityFileName = "activity.json"
    public static let usageHistoryFileName = "usage-history.json"
    public static let ledgerFileName = "reset-ledger.json"

    static let scanInterval: TimeInterval = 30
    /// A continue must show up in the rollout within this time (D24).
    static let confirmWindow: TimeInterval = 120
    static let keepAwakeMaxWait: TimeInterval = 6 * 3600
    static let shortTurn: TimeInterval = 60
    static let stillReachedAfter: TimeInterval = 3600
    static let ledgerMaxAge: TimeInterval = 24 * 3600
    static let pendingMaxAge: TimeInterval = 24 * 3600
    static let usageRefresh: TimeInterval = 3600
    static let freshRead: TimeInterval = 30

    private nonisolated static let logger = Logger(subsystem: "com.cybokron.limitguard", category: "Engine")

    @Published public private(set) var snapshot: AccountSnapshot?
    @Published public private(set) var health: ProtocolHealth = .full
    @Published public private(set) var sessions: [SessionState] = []
    @Published public private(set) var tabs: [EngineTab] = []
    @Published public private(set) var nextAction: NextAction?
    @Published public private(set) var forecast = EngineForecast()
    @Published public private(set) var usage: UsageReport?
    @Published public private(set) var isPaused = false
    /// Why the last limits read failed; the snapshot shown is then older and closes the gate.
    @Published public private(set) var readError: String?
    /// The same failure by kind (not signed in, unreachable, other); nil after a successful read.
    @Published public private(set) var readFailure: LimitsReadFailure?

    private struct Countdown {
        var threadId: String
        var turnId: String
        var text: String
        var until: Date
        var tab: TabRef
        var pid: Int32?
    }

    private struct ContinueTarget {
        var threadId: String
        var turnId: String
        var text: String
    }

    private let dependencies: Dependencies
    private let stateStore: JSONStore<AppState>
    private let activity: ActivityLog
    private let history: UsageHistory
    /// The only ledger and executor of the process (spec §8.3).
    private let ledger: ResetLedger
    private let executor: ResetExecutor

    private var state = AppState()
    /// `state.json` could not be read (newer version or broken): it is never overwritten, nothing acts.
    private var stateUnusable = false
    private var settings = Settings()
    private var bootstrapped = false
    /// Guards without a pid were dropped from the loaded state; the file still has them.
    private var legacyTabsDropped = false
    /// A spend ended with an unknown result: no automatic spend until relaunch.
    private var autoSpendBlocked = false
    private var lastGate: Bool?
    private var readOnlyReason: String?
    private var lastReadAttemptAt: Date?
    private var nextLimitsReadAt = Date.distantPast
    private var lastUsageAttemptAt: Date?
    private var lastScanAt: Date?
    private var historySamples: [UsageSample]?
    private var currentTabs: [TerminalTab] = []
    /// threadId → cwd of the daemon's loaded threads; nil when the daemon could not be reached.
    private var loadedCwds: [String: String]?
    private var mapping: [TabRef: String] = [:]
    private var countdown: Countdown?
    /// The thread whose continue is being delivered right now.
    private var sendingThread: String?
    private var nextContinue: ContinueTarget?
    private var waitsForContinue = false
    private var wantAwake = false
    private var keepAwakeOn = false
    private var notedKeys: Set<String> = []
    /// Stops (thread|turn) that already had their extra read.
    private var forcedReadStops: Set<String> = []
    private var unconfirmedNoted: Set<UUID> = []
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Error>?

    public init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
        let dir = dependencies.dataDirectory
        stateStore = JSONStore(url: dir.appending(path: Self.stateFileName), schemaVersion: 1)
        activity = ActivityLog(url: dir.appending(path: Self.activityFileName))
        history = UsageHistory(url: dir.appending(path: Self.usageHistoryFileName))
        ledger = ResetLedger(store: JSONStore(url: dir.appending(path: Self.ledgerFileName), schemaVersion: 1))
        let clock = dependencies.clock
        executor = ResetExecutor(
            service: dependencies.account, ledger: ledger, now: { clock.now },
            sleeper: dependencies.resetSleeper, log: { Self.logger.notice("\($0, privacy: .public)") })
        do {
            let loaded = try stateStore.load() ?? AppState()
            state = loaded
            // Guards from before they were bound to the Codex process can't be told apart from a new
            // tab on the same tty: they are dropped (saved at bootstrap).
            state.guardedTabs.removeAll { $0.ref.pid == nil }
            state.untickedTabs.removeAll { $0.pid == nil }
            legacyTabsDropped = state != loaded
            isPaused = state.paused
        } catch {
            Self.logger.error("state.json unusable: \(String(describing: error), privacy: .public)")
            stateUnusable = true
        }
    }

    private var now: Date { dependencies.clock.now }

    // MARK: - Public operations

    /// Runs `tick()` on the polling cadence until `stop()`.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.bootstrap()
            while !Task.isCancelled {
                guard let engine = self else { return }
                await engine.tick()
                let wake = engine.nextWake()
                let clock = engine.dependencies.clock
                let sleeper = Task { try await clock.sleep(until: wake) }
                engine.sleeper = sleeper
                _ = await sleeper.result
            }
        }
    }

    public func stop() {
        loop?.cancel()
        sleeper?.cancel()
        loop = nil
    }

    /// Ticks now instead of at the next scheduled time (after wake from sleep, a settings change, …).
    public func wake() {
        sleeper?.cancel()
    }

    /// The launch work: expire stale ledger entries, then resume a pending consume. Runs once; the
    /// first tick runs it when `start()` did not.
    public func bootstrap() async {
        await exclusive { await self.runBootstrap() }
    }

    public func tick() async {
        await exclusive { await self.runTick() }
    }

    /// Cancels the countdown or the scheduled continue; that stop is not continued automatically again.
    /// Acts only on the continue the next action shows. Once its send has started, the cancel changes
    /// nothing and the activity log says the message was already sent.
    public func cancelNextAction() {
        guard let target = nextContinue else {
            if let thread = sendingThread {
                appendActivity(ActivityEntry(
                    date: now, kind: .continueCancelled, threadId: thread,
                    detail: Localization.string("engine.cancel.tooLate", "Too late to cancel: the continue was already sent."),
                    codexVersion: dependencies.codexVersion))
            }
            return
        }
        if let countdown, countdown.threadId != target.threadId { return }
        countdown = nil
        nextContinue = nil
        nextAction = nil
        state.settledStops[target.threadId] = target.turnId
        saveState()
        appendActivity(ActivityEntry(
            date: now, kind: .continueCancelled, threadId: target.threadId, text: target.text,
            codexVersion: dependencies.codexVersion))
    }

    /// The manual "Use Reset" button (spec §8.2): no marker, same ledger and executor, limits re-read after.
    public func useReset(creditId: String) async -> SpendResult {
        await exclusive { await self.runUseReset(creditId) }
    }

    /// "Continue now" for a waiting session (unguarded tab, or "Send again" after an unconfirmed
    /// continue): skips the countdown and the guarded check, never the gate or the confirmation.
    /// As an explicit owner action it also skips the loop guard and the minimum gap, and Pause does
    /// not block it (Pause stops automatic actions only). The notice, read-only and age rules still apply.
    public func continueNow(threadId: String) async {
        await exclusive { await self.runContinueNow(threadId) }
    }

    public func setGuarded(_ tab: TabRef, _ on: Bool) {
        state.guardedTabs.removeAll { $0.ref == tab }
        state.untickedTabs.removeAll { $0 == tab }
        // An untick sticks while the tab lives, also against "guard new tabs automatically".
        if on { state.guardedTabs.append(GuardedTab(ref: tab, addedAt: now)) } else { state.untickedTabs.append(tab) }
        saveState()
        publishTabs()
    }

    /// Pauses all automatic continuing and spending; reading goes on. Kept in `state.json`, so a
    /// relaunch (reboot, update) stays paused.
    public func pause(_ on: Bool) {
        isPaused = on
        state.paused = on
        saveState()
        if on {
            countdown = nil
            nextContinue = nil
            nextAction = nil
        }
        wake()
    }

    // MARK: - Serialisation

    private func exclusive<T>(_ body: () async -> T) async -> T {
        while busy {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in waiters.append(waiter) }
        }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return await body()
    }

    func nextWake() -> Date {
        var wake = min(nextLimitsReadAt, (lastScanAt ?? now).addingTimeInterval(Self.scanInterval))
        if let countdown { wake = min(wake, countdown.until) }
        for pending in state.pendingDeliveries where !unconfirmedNoted.contains(pending.clientMessageId) {
            wake = min(wake, pending.sentAt.addingTimeInterval(Self.confirmWindow + 1))
        }
        return wake
    }

    // MARK: - Launch

    private func runBootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        settings = dependencies.settings()
        if stateUnusable {
            await note(.readOnly(Localization.string(
                "engine.readOnly.state",
                "The app's state file can't be used (it may be from a newer version), so automatic actions are paused.")))
        }
        do {
            for entry in try await ledger.expireOlderThan(Self.ledgerMaxAge, now: now) {
                await note(.resetResultUnknown(creditId: entry.creditId))
            }
        } catch {
            Self.logger.error("reset ledger not expired: \(String(describing: error), privacy: .public)")
        }
        // Guards whose Codex process is gone (quit, reboot, update) never carry over to a new tab.
        var next = state
        if let listed = await dependencies.environment.terminalTabs() { next = pruned(next, present: listed) }
        if next != state || legacyTabsDropped, !save(next) { state = next }
        let pending = try? await ledger.pending()
        if let result = await executor.resumePending() {
            await handleSpend(result, creditId: pending?.creditId ?? "?", reason: pending?.reason ?? .auto)
        }
    }

    // MARK: - Tick

    private func runTick() async {
        if !bootstrapped { await runBootstrap() }
        settings = dependencies.settings()
        sessions = await dependencies.sessions.scan(now: now)
        lastScanAt = now
        let countdownDue = countdown.map { now >= $0.until } ?? false
        // A countdown about to fire always gets a fresh read (spec §7.2 step 4); a stop seen for the
        // first time too, so it is classified while the windows still show which one stopped it.
        if countdownDue || now >= nextLimitsReadAt || hasUnrecordedStop() { await readLimits() }
        await refreshUsageIfDue()
        await trackSessions()
        await remindExpiringCredits()
        await considerAutoSpend()
        await refreshTabs()
        await runContinues()
        await updateKeepAwake()
        scheduleNextRead()
    }

    private func readLimits() async {
        lastReadAttemptAt = now
        do {
            var (read, readHealth) = try await dependencies.account.readLimits()
            read.readAt = now
            snapshot = read
            health = readHealth
            readError = nil
            readFailure = nil
            switch readHealth {
            case .full:
                readOnlyReason = nil
            case let .readOnly(reason):
                if readOnlyReason != reason {
                    readOnlyReason = reason
                    await note(.readOnly(reason))
                }
            }
            if case .full = readHealth, let gate = read.ordinaryUsageAllowed {
                if lastGate == false, gate { await note(.limitIsBack) }
                lastGate = gate
            }
            recordHistory(read)
        } catch {
            // The snapshot kept here ages past 30 s, which closes the gate on its own.
            readError = AppServerDelivery.describe(error)
            readFailure = LimitsReadFailure.classify(error)
        }
    }

    private func recordHistory(_ read: AccountSnapshot) {
        guard read.fiveHour != nil || read.weekly != nil else { return }
        if historySamples == nil { historySamples = (try? history.samples()) ?? [] }
        let sample = UsageSample(date: read.readAt, fiveHour: read.fiveHour?.usedPercent, weekly: read.weekly?.usedPercent)
        do {
            if try history.append(sample: sample) {
                historySamples?.append(sample)
                let cutoff = read.readAt.addingTimeInterval(-UsageHistory.retention)
                historySamples?.removeAll { $0.date < cutoff }
            }
        } catch {
            Self.logger.error("usage history not saved: \(String(describing: error), privacy: .public)")
        }
        let samples = historySamples ?? []
        forecast = EngineForecast(
            fiveHour: Forecast.runOut(
                samples: samples.compactMap { s in s.fiveHour.map { (s.date, $0) } }, now: now,
                resetsAt: read.fiveHour?.resetsAt),
            weekly: Forecast.runOut(
                samples: samples.compactMap { s in s.weekly.map { (s.date, $0) } }, now: now,
                resetsAt: read.weekly?.resetsAt))
    }

    private func refreshUsageIfDue() async {
        if let last = lastUsageAttemptAt, now.timeIntervalSince(last) < Self.usageRefresh { return }
        lastUsageAttemptAt = now
        // A failing usage read only leaves the chart as it was.
        if let report = try? await dependencies.account.readUsage() { usage = report }
    }

    private func isFresh(_ read: AccountSnapshot) -> Bool {
        now.timeIntervalSince(read.readAt) <= Self.freshRead
    }

    /// Health as the policies see it: an unusable state file also stops every automatic action.
    private var effectiveHealth: ProtocolHealth {
        stateUnusable ? .readOnly(reason: "state.json unusable") : health
    }

    // MARK: - Sessions, stops, loop records, confirmations

    private func trackSessions() async {
        var changed = false
        let byId = Dictionary(sessions.map { ($0.threadId, $0) }, uniquingKeysWith: { first, _ in first })

        for pending in state.pendingDeliveries {
            let request = ContinueRequest(
                threadId: pending.threadId, text: pending.text, clientMessageId: pending.clientMessageId, tab: nil)
            if let session = byId[pending.threadId], DeliveryConfirmer.isConfirmed(request: request, session: session) {
                // Counted when sent (spec §7.4); confirmation only verifies the delivery.
                state.pendingDeliveries.removeAll { $0.clientMessageId == pending.clientMessageId }
                state.stops[pending.threadId] = nil
                state.settledStops[pending.threadId] = nil
                changed = true
            } else if now.timeIntervalSince(pending.sentAt) > Self.confirmWindow,
                      unconfirmedNoted.insert(pending.clientMessageId).inserted {
                await note(.unconfirmed(threadId: pending.threadId), text: pending.text)
            }
        }
        let stale = state.pendingDeliveries.count
        state.pendingDeliveries.removeAll { now.timeIntervalSince($0.sentAt) > Self.pendingMaxAge }
        if state.pendingDeliveries.count != stale { changed = true }

        let fresh = snapshot.flatMap { isFresh($0) && health == .full ? $0 : nil }
        for session in sessions {
            let id = session.threadId
            // Our continue may be in flight: the rollout writes `task_started` before the user message.
            let confirming = state.pendingDeliveries.contains {
                $0.threadId == id && now.timeIntervalSince($0.sentAt) <= Self.confirmWindow
            }
            var waitingTurn: String?
            if case let .usageLimit(stopAt, turn) = session.lastStop, !session.userActivityAfterStop {
                waitingTurn = turn
                // Classified once, from a fresh full read only, and kept while the stop is current.
                if state.stops[id]?.turnId != turn, let read = fresh {
                    if var loop = state.loop[id], loop.consecutive > 0, let sent = loop.lastSentAt, stopAt > sent {
                        let duration = session.lastTurnDurations.last ?? .infinity
                        loop.shortTurnsInARow = duration < Self.shortTurn ? loop.shortTurnsInARow + 1 : 0
                        state.loop[id] = loop
                    }
                    let info = ContinuePolicy.classifyStop(turnId: turn, snapshot: read)
                    state.stops[id] = info
                    changed = true
                    if ContinuePolicy.isWaitingOnUsageLimit(session: session, snapshot: read, stopInfo: info, now: now) {
                        await note(.limitReached, once: "limitReached|\(id)|\(turn)")
                    }
                }
            } else if state.stops[id] != nil, !confirming {
                // Superseded. Activity while our continue is still pending (even unconfirmed) is taken as
                // ours, so a Codex that never writes our client id cannot reset the loop guard.
                let ours = state.pendingDeliveries.contains { $0.threadId == id }
                state.stops[id] = nil
                if session.lastStop == .none || (session.userActivityAfterStop && !ours) { resetLoop(id) }
                changed = true
            }
            if session.lastStop == .none, let loop = state.loop[id], loop.consecutive != 0 || loop.shortTurnsInARow != 0 {
                resetLoop(id)
                changed = true
            }
            if let settled = state.settledStops[id], settled != waitingTurn, !confirming {
                state.settledStops[id] = nil
                state.pendingDeliveries.removeAll { $0.threadId == id }
                changed = true
            }
        }
        if changed { saveState() }
    }

    /// True once per stop that is not classified yet: it gets one extra read, never a read every tick
    /// while reads fail or stay read-only (the spec §5 cadence applies after that).
    private func hasUnrecordedStop() -> Bool {
        var found = false
        for session in sessions {
            guard case let .usageLimit(at, turn) = session.lastStop, !session.userActivityAfterStop,
                  state.stops[session.threadId]?.turnId != turn, now.timeIntervalSince(at) <= ContinuePolicy.maxStopAge
            else { continue }
            if forcedReadStops.insert("\(session.threadId)|\(turn)").inserted { found = true }
        }
        return found
    }

    private func resetLoop(_ threadId: String) {
        guard var loop = state.loop[threadId] else { return }
        loop.consecutive = 0
        loop.shortTurnsInARow = 0
        state.loop[threadId] = loop
    }

    /// Sessions on a usage-limit stop auto-continue could still act on.
    private func waitingSessions() -> [SessionState] {
        guard let snapshot else { return [] }
        return sessions.filter {
            ContinuePolicy.isWaitingOnUsageLimit(session: $0, snapshot: snapshot, stopInfo: state.stops[$0.threadId], now: now)
        }
    }

    // MARK: - Reset credits

    private func remindExpiringCredits() async {
        guard let read = snapshot, isFresh(read), health == .full else { return }
        var changed = false
        let listed = Set(read.credits.map(\.id))
        if !state.expiryNotified.isSubset(of: listed) {
            state.expiryNotified.formIntersection(listed)
            changed = true
        }
        if settings.expiryReminders {
            for credit in ResetPolicy.expiringSoon(credits: read.credits, now: now) where !state.expiryNotified.contains(credit.id) {
                guard let expiresAt = credit.expiresAt else { continue }
                state.expiryNotified.insert(credit.id)
                changed = true
                await note(.resetExpiring(creditId: credit.id, at: expiresAt))
            }
        }
        if changed { saveState() }
    }

    private func considerAutoSpend() async {
        guard !autoSpendBlocked, !stateUnusable, let read = snapshot, isFresh(read) else { return }
        let pendingConsume: Bool
        do {
            pendingConsume = try await ledger.pending() != nil
        } catch {
            pendingConsume = true
        }
        let decision = ResetPolicy.decideAuto(
            snapshot: read, health: effectiveHealth, settings: settings, state: state, sessions: sessions,
            paused: isPaused, now: now, hasPendingConsume: pendingConsume)
        guard case let .spend(creditId) = decision, let marker = ResetPolicy.marker(for: read, now: now) else { return }
        // The marker, kept whatever the outcome, limits automatic spends to one per week (D9).
        var next = state
        next.autoSpend = marker
        guard save(next) else { return }
        let result = await executor.spend(creditId: creditId, reason: .auto)
        await handleSpend(result, creditId: creditId, reason: .auto)
    }

    private func runUseReset(_ creditId: String) async -> SpendResult {
        if !bootstrapped { await runBootstrap() }
        settings = dependencies.settings()
        // This call may have waited behind an automatic spend: check the credit against a fresh read.
        await readLimits()
        if case let .readOnly(reason) = effectiveHealth {
            // Read-only mode never spends (spec §6); `.busy` means nothing was sent.
            await note(.readOnly(reason))
            return .busy
        }
        guard let read = snapshot, isFresh(read), CreditPresentation.stillAvailable(creditId: creditId, in: read) else {
            Self.logger.notice("reset spend for \(creditId, privacy: .public) not sent: credit no longer available")
            return .busy
        }
        let result = await executor.spend(creditId: creditId, reason: .manual)
        await handleSpend(result, creditId: creditId, reason: .manual)
        return result
    }

    private func handleSpend(_ result: SpendResult, creditId: String, reason: SpendReason) async {
        switch result {
        case let .outcome(outcome):
            await note(.resetUsed(outcome), detail: "outcome \(outcome), credit \(creditId), \(reason.rawValue)")
            await readLimits()
        case .unknown:
            autoSpendBlocked = true
            await note(.resetResultUnknown(creditId: creditId), detail: "credit \(creditId), \(reason.rawValue)")
            await note(.readOnly(Localization.string(
                "engine.readOnly.autoSpend",
                "A reset credit spend has an unknown result, so automatic spending is paused until the app restarts.")),
                once: "autoSpendBlocked")
        case .busy:
            Self.logger.notice("reset spend for \(creditId, privacy: .public) not sent: another spend is pending")
        }
    }

    // MARK: - Tabs

    private func refreshTabs() async {
        let listed = await dependencies.environment.terminalTabs()
        do {
            loadedCwds = try await dependencies.delivery.loadedThreadCwds()
        } catch {
            loadedCwds = nil
            Self.logger.notice("daemon not reachable: \(AppServerDelivery.describe(error), privacy: .public)")
        }
        // A failed listing keeps the last known tabs: nothing is pruned or auto-guarded on it.
        if let listed {
            var next = pruned(state, present: listed)
            if settings.guardNewTabsAutomatically {
                for tab in listed where !next.guardedTabs.contains(where: { $0.ref == tab.ref }) && !next.untickedTabs.contains(tab.ref) {
                    next.guardedTabs.append(GuardedTab(ref: tab.ref, addedAt: now))
                }
            }
            if next != state, !save(next) { state = next }
            currentTabs = listed
        }
        let all = currentTabs
        // All Codex tabs take part, so same-folder duplicates are seen; guarding filters afterwards.
        mapping = loadedCwds.map { TabMatcher.match(tabs: all, threads: waitingSessions(), loadedThreadCwds: $0) } ?? [:]
        publishTabs()
    }

    /// Drops guards and unticks whose Codex process is no longer listed. A ref includes the pid and the
    /// start time, so a closed tab, or another process on the same tty, never inherits a guard.
    private func pruned(_ current: AppState, present listed: [TerminalTab]) -> AppState {
        let present = Set(listed.map(\.ref))
        var next = current
        next.guardedTabs.removeAll { !present.contains($0.ref) }
        next.untickedTabs.removeAll { !present.contains($0) }
        return next
    }

    private func isGuarded(_ tab: TabRef) -> Bool {
        state.guardedTabs.contains { $0.ref == tab }
    }

    private func publishTabs() {
        tabs = currentTabs.map { tab in
            let thread = mapping[tab.ref]
            return EngineTab(tab: tab, isGuarded: isGuarded(tab.ref), threadId: thread, isWaiting: thread != nil)
        }
    }

    // MARK: - Continues

    /// Notice accepted, not paused, auto-continue on, protocol and state usable.
    private var automaticContinueAllowed: Bool {
        !Notice.mustShow(settings: settings) && !isPaused && settings.autoContinue && effectiveHealth == .full
    }

    private func runContinues() async {
        wantAwake = false
        waitsForContinue = false
        if let due = countdown, now >= due.until {
            countdown = nil
            await fire(due)
        }
        guard let read = snapshot else {
            publishNextAction(earliestWait: nil)
            return
        }
        var earliestWait: (date: Date, target: ContinueTarget)?
        for session in waitingSessions() {
            guard case let .usageLimit(_, turn) = session.lastStop else { continue }
            let id = session.threadId
            if state.settledStops[id] == turn || state.pendingDeliveries.contains(where: { $0.threadId == id }) { continue }
            guard let tab = mapping.first(where: { $0.value == id })?.key, isGuarded(tab) else {
                if mapping.values.contains(id) == false, automaticContinueAllowed { await noteUnmapped(session, turn: turn) }
                continue
            }
            if countdown?.threadId == id { continue }
            let text = continueText(for: session)
            let target = ContinueTarget(threadId: id, turnId: turn, text: text)
            switch ContinuePolicy.decide(inputs(session, read, settings: settings, loop: state.loop[id] ?? LoopRecord(), paused: isPaused)) {
            case .notEligible:
                continue
            case let .waitUntil(date):
                waitsForContinue = true
                if date.timeIntervalSince(now) < Self.keepAwakeMaxWait { wantAwake = true }
                if earliestWait.map({ date < $0.date }) ?? true { earliestWait = (date, target) }
            case .waitForGate:
                waitsForContinue = true
                wantAwake = true
                let check = PollSchedule.nextLimitsRead(
                    after: lastReadAttemptAt ?? now, snapshot: read,
                    stopResets: state.stops[id]?.resetsAt.map { [$0] } ?? [], continuePending: true)
                if earliestWait.map({ check < $0.date }) ?? true { earliestWait = (check, target) }
                if let resetsAt = state.stops[id]?.resetsAt, now.timeIntervalSince(resetsAt) > Self.stillReachedAfter {
                    await note(.limitStillReached, once: "stillReached|\(id)|\(turn)")
                }
            case let .countdown(seconds):
                guard countdown == nil else { continue }
                let pid = currentTabs.first { $0.ref == tab }?.codexPid
                countdown = Countdown(
                    threadId: id, turnId: turn, text: text, until: now.addingTimeInterval(TimeInterval(seconds)), tab: tab, pid: pid)
                await note(.continueCountdown(threadId: id, seconds: seconds), text: text, tab: tab)
            case .send:
                guard countdown == nil else { continue }
                await deliverAutomatically(session, turn: turn, text: text, tab: tab)
            case .stopLoopGuard:
                settle(id, turn)
                await note(.loopStopped(threadId: id), tab: tab)
            case .stopRunaway:
                settle(id, turn)
                await note(.runawayStopped(threadId: id), tab: tab)
            }
        }
        if countdown != nil { wantAwake = true }
        publishNextAction(earliestWait: earliestWait)
    }

    private func publishNextAction(earliestWait: (date: Date, target: ContinueTarget)?) {
        if let countdown {
            nextContinue = ContinueTarget(threadId: countdown.threadId, turnId: countdown.turnId, text: countdown.text)
            nextAction = NextAction(kind: .countdown(until: countdown.until, threadId: countdown.threadId, text: countdown.text))
        } else if let wait = earliestWait {
            nextContinue = wait.target
            nextAction = NextAction(kind: .continueAt(wait.date, threadId: wait.target.threadId, text: wait.target.text))
        } else {
            nextContinue = nil
            let armed = settings.autoSpendEnabled && !autoSpendBlocked && !isPaused
                && !Notice.mustShow(settings: settings) && effectiveHealth == .full
            nextAction = armed ? NextAction(kind: .autoSpendArmed(threshold: settings.autoSpendThreshold)) : nil
        }
    }

    /// The countdown ended: re-check everything right before sending (spec §7.2 step 4).
    private func fire(_ due: Countdown) async {
        guard let session = sessions.first(where: { $0.threadId == due.threadId }),
              case let .usageLimit(_, turn) = session.lastStop, turn == due.turnId, !session.userActivityAfterStop
        else {
            settle(due.threadId, due.turnId)
            await skip(due.threadId, Localization.string("engine.skip.sessionChanged", "The session changed during the countdown."), tab: due.tab)
            return
        }
        guard let tab = currentTabs.first(where: { $0.ref == due.tab }), tab.codexPid == due.pid else {
            settle(due.threadId, due.turnId)
            await skip(due.threadId, Self.tabChangedReason, tab: due.tab)
            return
        }
        await deliverAutomatically(session, turn: turn, text: due.text, tab: due.tab)
    }

    private static var tabChangedReason: String {
        Localization.string("engine.skip.tabChanged", "The Terminal tab changed, so nothing was sent.")
    }

    private static var daemonReason: String {
        Localization.string("engine.skip.daemonUnreachable", "Codex daemon not reachable")
    }

    private func deliverAutomatically(_ session: SessionState, turn: String, text: String, tab: TabRef) async {
        let id = session.threadId
        guard loadedCwds != nil else {
            settle(id, turn)
            await skip(id, Self.daemonReason, tab: tab)
            return
        }
        guard mapping[tab] == id, isGuarded(tab), let read = snapshot else {
            settle(id, turn)
            await skip(id, Self.tabChangedReason, tab: tab)
            return
        }
        let decision = ContinuePolicy.decide(inputs(session, read, settings: settings, loop: state.loop[id] ?? LoopRecord(), paused: isPaused))
        switch decision {
        case .countdown, .send:
            // Cancelled while this tick was waiting on something: nothing is sent.
            guard state.settledStops[id] != turn else { return }
            await send(threadId: id, turn: turn, text: text, tab: tab, reuse: nil)
        case .waitUntil, .waitForGate:
            // The gate closed again: the normal flow takes over on a later tick.
            return
        default:
            settle(id, turn)
            await skip(id, Self.reason(for: decision), tab: tab)
        }
    }

    /// A waiting session with no tab: when a guarded tab in its folder exists, the owner is told why
    /// nothing happens (D18), once per stop.
    private func noteUnmapped(_ session: SessionState, turn: String) async {
        let folder = TabMatcher.normalize(session.cwd)
        guard currentTabs.contains(where: { isGuarded($0.ref) && $0.cwd.map(TabMatcher.normalize) == folder }) else { return }
        let daemonDown = loadedCwds == nil
        let reason = daemonDown
            ? Self.daemonReason
            : Localization.string("engine.skip.ambiguous", "Several Codex tabs could be this session; continue it by hand.")
        await note(
            .continueSkipped(threadId: session.threadId, reason: reason),
            once: "unmapped|\(session.threadId)|\(turn)|\(daemonDown)")
    }

    private func runContinueNow(_ threadId: String) async {
        if !bootstrapped { await runBootstrap() }
        settings = dependencies.settings()
        sessions = await dependencies.sessions.scan(now: now)
        lastScanAt = now
        await readLimits()
        await trackSessions()
        guard let session = sessions.first(where: { $0.threadId == threadId }),
              case let .usageLimit(_, turn) = session.lastStop, !session.userActivityAfterStop,
              let read = snapshot
        else {
            await skip(threadId, Localization.string("engine.skip.notWaiting", "This session isn't waiting on the usage limit."))
            return
        }
        var reuse: PendingDelivery?
        if let pending = state.pendingDeliveries.first(where: { $0.threadId == threadId }) {
            guard now.timeIntervalSince(pending.sentAt) > Self.confirmWindow else {
                await skip(threadId, Localization.string("engine.skip.confirming", "The last continue is still being confirmed."))
                return
            }
            // "Send again": the same clientMessageId, so the rollout can still confirm the first one.
            reuse = pending
        }
        do {
            _ = try await dependencies.delivery.loadedThreadCwds()
        } catch {
            await skip(threadId, Self.daemonReason)
            return
        }
        var manual = settings
        manual.autoContinue = true
        manual.countdownSeconds = 0
        // The owner asked: no loop guard or minimum gap, the gate and every other rule still apply.
        let decision = ContinuePolicy.decide(ContinueInputs(
            session: session, snapshot: read, snapshotAge: now.timeIntervalSince(read.readAt), health: effectiveHealth,
            settings: manual, loop: LoopRecord(), isGuarded: true, paused: false, now: now,
            stopInfo: state.stops[threadId]))
        guard decision == .send else {
            await skip(threadId, Self.reason(for: decision))
            return
        }
        if countdown?.threadId == threadId { countdown = nil }
        let tab = mapping.first { $0.value == threadId }?.key
        await send(threadId: threadId, turn: turn, text: reuse?.text ?? continueText(for: session), tab: tab, reuse: reuse)
        if nextContinue?.threadId == threadId { publishNextAction(earliestWait: nil) }
    }

    /// Stores the pending delivery, then sends. Never sends when the state cannot be saved first (D24).
    private func send(threadId: String, turn: String, text: String, tab: TabRef?, reuse: PendingDelivery?) async {
        var pending = reuse ?? PendingDelivery(threadId: threadId, clientMessageId: UUID(), text: text, sentAt: now)
        pending.sentAt = now
        var next = state
        next.pendingDeliveries.removeAll { $0.clientMessageId == pending.clientMessageId }
        next.pendingDeliveries.append(pending)
        next.settledStops[threadId] = turn
        guard save(next) else {
            await skip(threadId, Localization.string("engine.skip.stateNotSaved", "The app's state couldn't be saved, so nothing was sent."), tab: tab)
            return
        }
        unconfirmedNoted.remove(pending.clientMessageId)
        // From here a cancel is too late: the next action no longer points at this continue.
        if countdown?.threadId == threadId { countdown = nil }
        if nextContinue?.threadId == threadId {
            nextContinue = nil
            nextAction = nil
        }
        sendingThread = threadId
        let request = ContinueRequest(threadId: threadId, text: pending.text, clientMessageId: pending.clientMessageId, tab: tab)
        let result = await dependencies.delivery.deliver(request)
        sendingThread = nil
        switch result {
        case .sent, .failed:
            // A continue that may have reached Codex counts against the loop guard, confirmed or not.
            var loop = state.loop[threadId] ?? LoopRecord()
            loop.consecutive += 1
            loop.lastSentAt = pending.sentAt
            state.loop[threadId] = loop
            saveState()
        case .refused:
            break
        }
        switch result {
        case .sent:
            await note(.continueSent(threadId: threadId), text: pending.text, tab: tab)
        case let .refused(reason):
            // Nothing was sent; the stop stays settled, the owner can still continue it by hand.
            state.pendingDeliveries.removeAll { $0.clientMessageId == pending.clientMessageId }
            saveState()
            await skip(threadId, reason, tab: tab)
        case let .failed(reason):
            // The outcome is unknown: confirm through the rollout, never resend automatically.
            appendActivity(ActivityEntry(
                date: now, kind: .error, threadId: threadId, tab: tab?.tty, text: pending.text,
                detail: "delivery outcome unknown: \(reason)", codexVersion: dependencies.codexVersion))
        }
    }

    private func settle(_ threadId: String, _ turn: String) {
        state.settledStops[threadId] = turn
        saveState()
    }

    private func continueText(for session: SessionState) -> String {
        ContinueText.resolve(sample: session.languageSample, table: settings.continueTexts, fallback: settings.fallbackText).text
    }

    private func inputs(_ session: SessionState, _ read: AccountSnapshot, settings: Settings, loop: LoopRecord, paused: Bool) -> ContinueInputs {
        ContinueInputs(
            session: session, snapshot: read, snapshotAge: now.timeIntervalSince(read.readAt), health: effectiveHealth,
            settings: settings, loop: loop, isGuarded: true, paused: paused, now: now,
            stopInfo: state.stops[session.threadId])
    }

    static func reason(for decision: ContinueDecision) -> String {
        switch decision {
        case .notEligible(.finished): return Localization.string("engine.skip.finished", "The session's last turn finished.")
        case .notEligible(.otherError): return Localization.string("engine.skip.otherError", "The session stopped with another error.")
        case .notEligible(.userActed): return Localization.string("engine.skip.userActed", "You typed in the session after the stop.")
        case .notEligible(.tooOld): return Localization.string("engine.skip.tooOld", "The stop is too old to continue.")
        case .notEligible(.notGuarded): return Localization.string("engine.skip.notGuarded", "The tab isn't guarded.")
        case .notEligible(.paused): return Localization.string("engine.skip.paused", "Limit Guard is paused.")
        case .notEligible(.readOnly):
            return Localization.string("engine.skip.readOnly", "Codex changed how it reports usage, so automatic actions are paused.")
        case .notEligible(.noticeNotAccepted):
            return Localization.string("engine.skip.notice", "The legal notice hasn't been accepted yet.")
        case .notEligible(.autoContinueOff): return Localization.string("engine.skip.autoContinueOff", "Auto-continue is off.")
        case .waitUntil, .waitForGate: return Localization.string("engine.skip.limitNotBack", "Codex still reports the limit as reached.")
        case .stopLoopGuard: return Localization.string("engine.skip.loopGuard", "Stopped after the maximum number of tries.")
        case .stopRunaway:
            return Localization.string("engine.skip.runaway", "Stopped: the last continued turns each ended within a minute.")
        case .countdown, .send: return ""
        }
    }

    // MARK: - Keep-awake and polling

    /// On between a guarded usage-limit stop and its continue when the wait is under 6 h (D14).
    private func updateKeepAwake() async {
        let on = settings.keepAwake && wantAwake
        guard on != keepAwakeOn else { return }
        keepAwakeOn = on
        await dependencies.environment.setKeepAwake(on)
    }

    private func scheduleNextRead() {
        let waiting = Set(waitingSessions().map(\.threadId))
        let resets = state.stops.filter { waiting.contains($0.key) }.compactMap(\.value.resetsAt)
        let pending = countdown != nil || !state.pendingDeliveries.isEmpty || waitsForContinue
        nextLimitsReadAt = PollSchedule.nextLimitsRead(
            after: lastReadAttemptAt ?? now, snapshot: snapshot, stopResets: resets, continuePending: pending)
    }

    // MARK: - Notes, activity, state

    private func skip(_ threadId: String, _ reason: String, tab: TabRef? = nil) async {
        await note(.continueSkipped(threadId: threadId, reason: reason), tab: tab)
    }

    /// Logs the note and, when its toggle is on, hands it to the environment. `once` drops repeats.
    private func note(_ note: EngineNote, text: String? = nil, tab: TabRef? = nil, detail: String? = nil, once key: String? = nil) async {
        if let key, !notedKeys.insert(key).inserted { return }
        appendActivity(ActivityEntry(
            date: now, kind: note.activityKind, threadId: note.threadId, tab: tab?.tty, text: text,
            detail: detail ?? note.detail, codexVersion: dependencies.codexVersion))
        if note.isEnabled(in: settings.notify) { await dependencies.environment.notify(note) }
    }

    private func appendActivity(_ entry: ActivityEntry) {
        do {
            try activity.append(entry)
        } catch {
            Self.logger.error("activity not saved: \(String(describing: error), privacy: .public)")
        }
    }

    /// Saves `next` and makes it the current state; false (and nothing changed) when it could not be saved.
    private func save(_ next: AppState) -> Bool {
        guard !stateUnusable else { return false }
        do {
            try stateStore.save(next)
            state = next
            return true
        } catch {
            Self.logger.error("state not saved: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func saveState() {
        _ = save(state)
    }
}
