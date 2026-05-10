import Foundation

/// EGO does not expose a "give me every stop on this line, in order" endpoint.
/// `RouteIndex` reconstructs that mapping by remembering every
/// `(durak_sira_no → durak_no)` pair we've seen during normal `FNC=Otobus`
/// polls and persisting them under `~/.ego-mac/route-cache/<line>.json`.
///
/// Stop names + coordinates come from the embedded `StopsBlob` via
/// `SearchIndex.shared`, so a freshly observed `stopNo` is immediately
/// renderable on the map without an extra round trip.
///
/// Threading: this is an `actor`, so any number of concurrent `record(...)`
/// calls from different feature views are safe.
actor RouteIndex {
    static let shared = RouteIndex()

    /// One observation cell per (line, sequence). Latest observation wins so a
    /// route revision (EGO occasionally renumbers stops mid-shift) is picked up
    /// on the next sample without manual flushing.
    private var byLine: [String: [Int: RouteSamplePoint]] = [:]

    /// In-memory cap per line. Routes top out around 80–100 stops, so 256 is
    /// a comfortable ceiling that prevents pathological RAM growth even if EGO
    /// starts emitting bogus sequence numbers.
    private static let maxSequencePerLine = 256

    private static let cacheDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ego-mac/route-cache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        // Warm start — load every cached line file so reopening the popover
        // shows the route immediately.
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: Self.cacheDir, includingPropertiesForKeys: nil) {
            for url in entries where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let pts = try? JSONDecoder.iso8601.decode([RouteSamplePoint].self, from: data),
                      let first = pts.first else { continue }
                var map: [Int: RouteSamplePoint] = [:]
                for p in pts { map[p.sequence] = p }
                byLine[first.lineCode] = map
            }
        }
    }

    // MARK: - Recording

    /// Ingest the live bus rows we just fetched for one line. Each live bus
    /// row gives us:
    ///   - `bus.busStopSeq` (durak_sira_no) — the bus's position in the route
    ///   - `bus.currentStopNo` (durak_no) — the actual stop number it's at
    ///   - `bus.userStopSeq` (secili_durak_sira_no) — the route's total stop count
    ///     (since we always query against the user's selected stop, the user's
    ///     sequence number IS the route's terminus number for that direction)
    func record(buses: [Bus], forLine line: String) {
        var map = byLine[line] ?? [:]
        let now = Date()
        for bus in buses {
            guard let seq = bus.busStopSeq,
                  let stopNo = bus.currentStopNo,
                  seq > 0, seq <= Self.maxSequencePerLine
            else { continue }
            // Prefer the freshest observation when same `(seq, stopNo)` repeats,
            // and prefer one WITH coordinates over one without.
            let existing = map[seq]
            let newer = RouteSamplePoint(
                lineCode: line,
                sequence: seq,
                stopNo: stopNo,
                observedAt: now,
                routeStopCount: bus.userStopSeq,
                latitude: bus.latitude,
                longitude: bus.longitude
            )
            if let e = existing, e.latitude != nil && newer.latitude == nil {
                // Keep the older sample's GPS rather than overwriting with a missing one.
                map[seq] = RouteSamplePoint(
                    lineCode: line,
                    sequence: seq,
                    stopNo: stopNo,
                    observedAt: now,
                    routeStopCount: bus.userStopSeq,
                    latitude: e.latitude,
                    longitude: e.longitude
                )
            } else {
                map[seq] = newer
            }
        }
        byLine[line] = map
        Self.save(line: line, samples: map.values.sorted { $0.sequence < $1.sequence })
    }

    // MARK: - Reading

    /// Best-known ordered list of stops on a line. Each entry is a
    /// `LineStop` with name + coordinates resolved from `StopsBlob` when
    /// possible. Gaps (sequences we haven't observed yet) become entries
    /// with `name: "Durak \(seq)"` and `nil` coordinates so the UI still
    /// shows the row count.
    func orderedStops(forLine line: String) async -> [LineStop] {
        let map = byLine[line] ?? [:]
        guard !map.isEmpty else { return [] }
        let routeStopCount = map.values.compactMap(\.routeStopCount).max() ?? map.keys.max() ?? 0
        guard routeStopCount > 0 else { return [] }
        let names = await SearchIndex.shared.lookupStopNames(
            Set(map.values.map(\.stopNo))
        )
        var out: [LineStop] = []
        out.reserveCapacity(routeStopCount)
        for seq in 1...routeStopCount {
            if let sample = map[seq] {
                out.append(LineStop(
                    lineCode: line,
                    sequence: seq,
                    stopNo: sample.stopNo,
                    name: names[sample.stopNo] ?? "Durak \(sample.stopNo)",
                    latitude: sample.latitude,
                    longitude: sample.longitude
                ))
            } else {
                // Unknown sequence — placeholder so the UI lists every position.
                out.append(LineStop(
                    lineCode: line,
                    sequence: seq,
                    stopNo: "?",
                    name: "Durak \(seq)",
                    latitude: nil,
                    longitude: nil
                ))
            }
        }
        return out
    }

    /// Coverage ratio (0.0–1.0) — how many stops we know vs. the route's
    /// total. Useful for showing a "harita yükleniyor" hint when sparse.
    func coverage(forLine line: String) -> (known: Int, total: Int)? {
        let map = byLine[line] ?? [:]
        guard !map.isEmpty else { return nil }
        let total = map.values.compactMap(\.routeStopCount).max() ?? map.keys.max() ?? 0
        return (map.count, total)
    }

    /// Average observed seconds-per-segment for `line`, computed from the
    /// stored samples. Returns `nil` when we have fewer than two samples on
    /// distinct sequences (so the per-line average is meaningful).
    ///
    /// Persisted via the same on-disk JSON used by `record`, so segment-time
    /// learning survives app restarts (Phase 5c).
    func averageSecondsPerSegment(forLine line: String) -> Double? {
        guard let map = byLine[line], map.count >= 2 else { return nil }
        let sorted = map.values.sorted { $0.observedAt < $1.observedAt }
        // Pair consecutive observations, keep only positive forward jumps so
        // we don't pollute the average with route-loop wrap-around ("end of
        // line→start" would look like a giant negative segment).
        var deltas: [Double] = []
        var prev: RouteSamplePoint? = nil
        for sample in sorted {
            if let p = prev,
               sample.sequence > p.sequence,
               sample.observedAt > p.observedAt {
                let secs = sample.observedAt.timeIntervalSince(p.observedAt)
                let segs = Double(sample.sequence - p.sequence)
                let perSeg = secs / segs
                if perSeg >= 20 && perSeg <= 300 {  // sanity clamp
                    deltas.append(perSeg)
                }
            }
            prev = sample
        }
        guard !deltas.isEmpty else { return nil }
        return deltas.reduce(0, +) / Double(deltas.count)
    }

    /// Drop any cached samples older than `maxAge` for a line. Called when the
    /// user explicitly hits "Yenile" on a route view.
    func evict(line: String, olderThan maxAge: TimeInterval = 7 * 24 * 3600) {
        guard var map = byLine[line] else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        map = map.filter { $0.value.observedAt > cutoff }
        byLine[line] = map
        Self.save(line: line, samples: map.values.sorted { $0.sequence < $1.sequence })
    }

    // MARK: - Disk persistence

    private static func cacheURL(line: String) -> URL {
        // Sanitise — line codes contain dashes which are filename-safe, but
        // belt-and-suspenders against any future line-code surprises.
        let safe = line.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#, with: "_", options: .regularExpression
        )
        return cacheDir.appendingPathComponent("\(safe).json")
    }

    private static func save(line: String, samples: [RouteSamplePoint]) {
        guard let data = try? JSONEncoder.iso8601.encode(samples) else { return }
        try? data.write(to: cacheURL(line: line), options: .atomic)
    }
}


