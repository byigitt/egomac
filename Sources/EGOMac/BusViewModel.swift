import Foundation
import SwiftUI

@MainActor
final class BusViewModel: ObservableObject {
    /// All buses keyed by stop number (raw API result).
    @Published private(set) var busesByStop: [String: [Bus]] = [:]
    /// Per-stop error message (so one bad stop doesn't blank the whole UI).
    @Published private(set) var stopErrors: [String: String] = [:]
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var isRefreshing = false

    @Published var config: EGOConfig

    /// Quick-lookup search box at top of popover. When set to a valid 5-digit
    /// stop number, the list view shows results for *that* stop instead of the
    /// configured active stop — without saving anything to disk.
    @Published var adhocStopNo: String = "" {
        didSet { onAdhocChange() }
    }
    @Published private(set) var adhocBuses: [Bus] = []
    @Published private(set) var adhocError: String?
    @Published private(set) var adhocLoading: Bool = false

    private var adhocTask: Task<Void, Never>?

    private let client = EGOClient()
    private var pollTask: Task<Void, Never>?
    private var notifiedVehicles = Set<String>()

    /// Status-bar title callback.
    var onTitleChange: ((String) -> Void)?

    /// Cached line catalog snapshot for the search/list views. Loaded eagerly
    /// from disk on init so the popover can render before the network call.
    /// Refreshed in the background via `loadAllLines()`.
    @Published private(set) var allLines: [Line] = EGOClient.cachedLinesFromDisk()
    @Published private(set) var allLinesError: String?

    /// Per-line schedule cache, keyed by line code. Populated on demand.
    @Published private(set) var schedules: [String: LineSchedule] = [:]
    @Published private(set) var scheduleErrors: [String: String] = [:]
    private var inflightSchedules = Set<String>()

    // MARK: - Stop catalog (background sweep over all lines)

    /// Progress 0...1 while a full catalog refresh is in flight; nil otherwise.
    @Published private(set) var catalogProgress: Double?
    /// Most recent catalog refresh's stop count + last-saved age. Re-read from
    /// disk after each refresh so Settings always shows fresh stats.
    @Published private(set) var catalogSummary: (count: Int, ageDays: Int?)?
    @Published private(set) var catalogError: String?
    private var catalogRefreshTask: Task<Void, Never>?

    init(config: EGOConfig = .default) {
        self.config = config
    }

    // MARK: - Catalog access (line list, schedules)

    /// Force-refresh the line catalog (network). Updates `allLines` on success,
    /// `allLinesError` on failure. Safe to call from any view's `.task {}`.
    func loadAllLines(force: Bool = false) async {
        do {
            let fetched = force
                ? try await client.refreshLineCatalog()
                : try await client.fetchAllLines()
            self.allLines = fetched
            self.allLinesError = nil
        } catch {
            self.allLinesError = error.localizedDescription
            DebugLog.log("loadAllLines failed: \(error.localizedDescription)")
        }
    }

    /// On-demand schedule fetch with simple in-flight de-dup. Cached forever
    /// for the lifetime of the popover; the schedule changes ~weekly so a long
    /// TTL is fine. UI calls this from `.task(id: line)`.
    func loadSchedule(line: String) async {
        if schedules[line] != nil || inflightSchedules.contains(line) { return }
        inflightSchedules.insert(line)
        defer { inflightSchedules.remove(line) }
        do {
            let s = try await client.fetchLineSchedule(line: line)
            self.schedules[line] = s
            self.scheduleErrors[line] = nil
        } catch {
            self.scheduleErrors[line] = error.localizedDescription
            DebugLog.log("schedule \(line) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Lifecycle

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if !self.config.isQuietHour() {
                    await self.refresh()
                }
                let interval = self.nextInterval()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        // Hydrate catalog summary from disk + auto-refresh if stale or missing.
        recomputeCatalogSummary()
        if catalogShouldRefresh() {
            Task.detached(priority: .background) { [weak self] in
                await self?.refreshStopCatalog()
            }
        }
    }

    /// True when the on-disk catalog is missing or older than
    /// `StopCatalog.refreshInterval` (7 days).
    private func catalogShouldRefresh() -> Bool {
        guard let age = StopCatalog.ageOnDisk() else { return true }
        return age > StopCatalog.refreshInterval
    }

    private func recomputeCatalogSummary() {
        guard let s = SearchIndex.diskCatalogSummary() else {
            catalogSummary = nil
            return
        }
        let days = Int(s.age.map { $0 / 86400 } ?? 0)
        catalogSummary = (count: s.count, ageDays: days)
    }

    /// Public entry point — idempotent; if a refresh is already in flight we
    /// just return its task. Used by the Settings "Yenile" button + launch.
    func refreshStopCatalog() async {
        if let task = catalogRefreshTask {
            await task.value
            return
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            self.catalogProgress = 0
            self.catalogError = nil
            do {
                _ = try await self.client.fetchFullStopCatalog { [weak self] done, total, _ in
                    guard let self else { return }
                    self.catalogProgress = Double(done) / Double(total)
                }
                // Pull the freshly-saved catalog into SearchIndex.
                SearchIndex.shared.reloadStopCatalog()
                self.recomputeCatalogSummary()
            } catch {
                self.catalogError = error.localizedDescription
                DebugLog.log("catalog refresh failed: \(error.localizedDescription)")
            }
            self.catalogProgress = nil
            self.catalogRefreshTask = nil
        }
        catalogRefreshTask = task
        await task.value
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Active stop

    var activeStop: StopProfile? { config.resolvedActiveStop }

    /// Buses for the currently active stop (sorted), what the popover list shows
    /// when adhoc search is empty.
    var activeBuses: [Bus] {
        guard let active = activeStop else { return [] }
        let raw = busesByStop[active.stopNo] ?? []
        return sortBuses(raw, watched: active.watchedSet)
    }

    var activeError: String? {
        guard let active = activeStop else { return nil }
        return stopErrors[active.stopNo]
    }

    /// True when adhoc search has a valid 5-digit number entered.
    var hasAdhocLookup: Bool { resolvedAdhoc != nil }

    /// What the popover list view should actually display.
    var displayedBuses: [Bus] { hasAdhocLookup ? adhocBuses : activeBuses }
    var displayedError: String? { hasAdhocLookup ? adhocError : activeError }

    /// 5-digit numeric or nil.
    var resolvedAdhoc: String? {
        let q = adhocStopNo.trimmingCharacters(in: .whitespaces)
        return (q.count == 5 && q.allSatisfy(\.isNumber)) ? q : nil
    }

    private func onAdhocChange() {
        adhocTask?.cancel()
        guard let stop = resolvedAdhoc else {
            adhocBuses = []
            adhocError = nil
            adhocLoading = false
            return
        }
        adhocLoading = true
        adhocError = nil
        adhocTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled else { return }
            // Only fetch if the user hasn't kept typing in the meantime.
            guard self.resolvedAdhoc == stop else { return }
            do {
                let buses = try await self.client.fetchBuses(stopNo: stop)
                guard !Task.isCancelled, self.resolvedAdhoc == stop else { return }
                self.adhocBuses = self.sortBuses(buses, watched: [])
                self.adhocError = nil
            } catch {
                self.adhocError = error.localizedDescription
            }
            self.adhocLoading = false
        }
    }

    func setActiveStop(_ id: UUID) {
        guard config.stops.contains(where: { $0.id == id }) else { return }
        var new = config
        new.activeStopId = id
        updateConfig(new, restartFetch: false)
    }

    // MARK: - Config mutations

    /// Save config and only hit the network when the set of valid stop numbers changes.
    /// UI-only edits (name, active tab, notification toggle/threshold) update derived
    /// state locally, which keeps Settings typing from spawning a fetch per keypress.
    func updateConfig(_ new: EGOConfig, restartFetch: Bool = true) {
        let old = config
        let oldStops = Self.validStopNos(from: old)
        let newStops = Self.validStopNos(from: new)
        let stopNosChanged = Set(oldStops) != Set(newStops)
        let alertInputsChanged = old.alertThresholdMin != new.alertThresholdMin
            || Self.watchedSignature(old) != Self.watchedSignature(new)

        self.config = new
        ConfigLoader.save(new)

        guard restartFetch else {
            updateTitle()
            return
        }

        if stopNosChanged {
            // New stop set → drop dedup/error state for stops we no longer watch.
            let live = Set(newStops)
            busesByStop = busesByStop.filter { live.contains($0.key) }
            stopErrors = stopErrors.filter { live.contains($0.key) }
            notifiedVehicles.removeAll()
            Task { await self.refresh() }
        } else {
            if alertInputsChanged, new.notificationsEnabled {
                checkAlerts(busesByStop)
            }
            updateTitle()
        }
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else {
            DebugLog.log("refresh skipped: already running")
            return
        }

        let stops = Self.validStopNos(from: config)
        guard !stops.isEmpty else {
            self.busesByStop = [:]
            self.stopErrors = [:]
            updateTitle()
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let results = await client.fetchAll(stopNos: stops)
        guard Set(Self.validStopNos(from: config)) == Set(stops) else {
            DebugLog.log("refresh discarded: stop list changed while request was in flight")
            Task { await self.refresh() }
            return
        }

        var newBuses: [String: [Bus]] = [:]
        var newErrors: [String: String] = [:]

        for (stopNo, result) in results {
            switch result {
            case .success(let buses):
                newBuses[stopNo] = buses
            case .failure(let err):
                newErrors[stopNo] = err.localizedDescription
                // Keep previous data for this stop if we have it (don't blank the UI on a transient error).
                newBuses[stopNo] = busesByStop[stopNo] ?? []
            }
        }

        self.busesByStop = newBuses
        self.stopErrors = newErrors
        self.lastUpdate = Date()

        let liveCount = newBuses.values.reduce(0) { total, buses in
            total + buses.lazy.filter { $0.etaMin != nil }.count
        }
        DebugLog.log("refresh ok: \(stops.count) stop(s), \(liveCount) live")

        checkAlerts(newBuses)
        updateTitle()
    }

    // MARK: - Title

    /// Closest watched live ETA across **all** stops drives the menu bar title.
    private func updateTitle() {
        if let secs = minWatchedEtaSeconds() {
            // Keep title VERY short — MacBooks with notch lose long titles.
            // < 60 s: render as seconds ("30s") so an imminent bus doesn't read as "0'".
            let title: String
            if secs < 60 {
                title = " \(secs)s"
            } else {
                title = " \(secs / 60)'"
            }
            DebugLog.log("title → '\(title)'")
            onTitleChange?(title)
        } else {
            onTitleChange?("")
        }
    }

    // MARK: - Alerts (per-stop watched lines)

    private func checkAlerts(_ snapshot: [String: [Bus]]) {
        let threshold = config.alertThresholdMin
        var seenKeys = Set<String>()

        for stop in config.stops {
            let watched = stop.watchedSet
            let buses = snapshot[stop.stopNo] ?? []
            for bus in buses {
                guard watched.contains(bus.line),
                      let eta = bus.etaMin
                else { continue }
                seenKeys.insert(bus.dedupKey)

                if eta <= threshold, !notifiedVehicles.contains(bus.dedupKey) {
                    if config.notificationsEnabled {
                        notifiedVehicles.insert(bus.dedupKey)
                        Notifier.notify(
                            title: "\(bus.line) yaklaşıyor — \(eta) dk",
                            body: "\(stop.displayName) · \(bus.route)"
                        )
                    } else {
                        DebugLog.log("NOTIFY suppressed (master switch off): \(bus.line) \(eta)dk")
                    }
                }
            }
        }
        notifiedVehicles = notifiedVehicles.intersection(seenKeys)
    }

    // MARK: - Polling cadence

    private func nextInterval() -> Double {
        guard let m = minWatchedEta() else { return 120 }
        if m <= 8  { return 20 }
        if m <= 15 { return 30 }
        return 90
    }

    private func minWatchedEta() -> Int? {
        minWatchedEtaSeconds().map { max(0, $0 / 60) }
    }

    /// Like `minWatchedEta` but in raw seconds — lets the title show "30s" for
    /// imminent buses instead of collapsing to "0'".
    private func minWatchedEtaSeconds() -> Int? {
        var minSecs: Int?
        for stop in config.stops {
            let watched = stop.watchedSet
            for bus in (busesByStop[stop.stopNo] ?? []) {
                guard let secs = bus.etaSeconds, watched.contains(bus.line) else { continue }
                if minSecs.map({ secs < $0 }) ?? true { minSecs = secs }
            }
        }
        return minSecs
    }

    private static func validStopNos(from config: EGOConfig) -> [String] {
        var seen = Set<String>()
        return config.stops.compactMap { stop in
            let trimmed = stop.stopNo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count == 5, trimmed.allSatisfy(\.isNumber), seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
    }

    private static func watchedSignature(_ config: EGOConfig) -> [String] {
        config.stops.map { stop in
            "\(stop.id.uuidString)|\(stop.stopNo)|\(stop.watchedLines.sorted().joined(separator: ","))"
        }
    }

    // MARK: - Sorting

    private func sortBuses(_ list: [Bus], watched: Set<String>) -> [Bus] {
        list.sorted { lhs, rhs in
            func rank(_ b: Bus) -> Int {
                let isWatched = watched.contains(b.line)
                if b.isLive && isWatched { return 0 }
                if b.isLive               { return 1 }
                if isWatched             { return 2 }
                return 3
            }
            let rl = rank(lhs), rr = rank(rhs)
            if rl != rr { return rl < rr }
            switch (lhs.etaMin, rhs.etaMin) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return lhs.line < rhs.line
            }
        }
    }
}
