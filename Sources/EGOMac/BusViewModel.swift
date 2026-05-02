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

    init(config: EGOConfig = .default) {
        self.config = config
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

    /// Save & re-fetch (typically on settings change). Pass `restartFetch=false`
    /// for view-only changes (active-stop switching) so we don't pound the API.
    func updateConfig(_ new: EGOConfig, restartFetch: Bool = true) {
        let stopsChanged = Set(new.stops.map(\.stopNo)) != Set(config.stops.map(\.stopNo))
        self.config = new
        ConfigLoader.save(new)
        if restartFetch && stopsChanged {
            // New stop set → drop dedup/error state for stops we no longer watch.
            let live = Set(new.stops.map(\.stopNo))
            busesByStop = busesByStop.filter { live.contains($0.key) }
            stopErrors = stopErrors.filter { live.contains($0.key) }
            notifiedVehicles.removeAll()
        }
        if restartFetch {
            Task { await self.refresh() }
        } else {
            updateTitle()
        }
    }

    // MARK: - Refresh

    func refresh() async {
        let stops = config.stops.map(\.stopNo)
        guard !stops.isEmpty else {
            self.busesByStop = [:]
            self.stopErrors = [:]
            updateTitle()
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let results = await client.fetchAll(stopNos: stops)
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

        let liveCount = newBuses.values.flatMap { $0 }.filter { $0.etaMin != nil }.count
        DebugLog.log("refresh ok: \(stops.count) stop(s), \(liveCount) live")

        checkAlerts(newBuses)
        updateTitle()
    }

    // MARK: - Title

    /// Closest watched live ETA across **all** stops drives the menu bar title.
    private func updateTitle() {
        var bestEta: Int?
        for stop in config.stops {
            let watched = stop.watchedSet
            let buses = busesByStop[stop.stopNo] ?? []
            for b in buses {
                guard let eta = b.etaMin, watched.contains(b.line) else { continue }
                if bestEta.map({ eta < $0 }) ?? true { bestEta = eta }
            }
        }
        if let eta = bestEta {
            // Keep title VERY short — MacBooks with notch lose long titles.
            let title = " \(eta)'"
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
                    notifiedVehicles.insert(bus.dedupKey)
                    if config.notificationsEnabled {
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
        // Use the global minimum watched ETA across all stops.
        var minEta: Int?
        for stop in config.stops {
            let watched = stop.watchedSet
            for bus in (busesByStop[stop.stopNo] ?? []) {
                guard let eta = bus.etaMin, watched.contains(bus.line) else { continue }
                if minEta.map({ eta < $0 }) ?? true { minEta = eta }
            }
        }
        guard let m = minEta else { return 120 }
        if m <= 8  { return 20 }
        if m <= 15 { return 30 }
        return 90
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
