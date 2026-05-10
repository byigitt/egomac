import Foundation

/// One entry in the on-disk EGO stop catalog. Built up by sweeping every
/// line's `HareketSaatleri` page (each page lists ~40-100 stops with
/// official EGO names + addresses). Aggregated and deduped by `stopNo`.
struct StopCatalogEntry: Codable, Hashable {
    let stopNo: String           // "10940"
    let name: String             // "1231 SK." — EGO's authoritative label
    let address: String?         // "Çankaya..." (when present in source)
    /// At least one line code that contains this stop. Useful for "this stop
    /// is served by N lines" UI affordances. We only keep the first ~8 to
    /// keep the file small.
    var seenOnLines: [String]
}

/// On-disk wrapper. We bump `schemaVersion` if we ever change the entry shape
/// in a non-decodable way; older clients then ignore the file and re-fetch.
struct StopCatalogFile: Codable {
    var schemaVersion: Int = 1
    var savedAt: Date
    var entries: [StopCatalogEntry]
}

/// Owns the on-disk EGO stop catalog. Read paths are sync (used by the search
/// index hot loop). Write paths are async and serialized via the `actor`.
actor StopCatalog {
    static let shared = StopCatalog()
    private init() {}

    private static let diskURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ego-mac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stops-catalog.json")
    }()

    /// 7-day TTL — EGO almost never adds stops, but a weekly refresh keeps us
    /// honest without hammering the server.
    static let refreshInterval: TimeInterval = 7 * 24 * 3600

    // MARK: - Sync read

    /// Best-effort synchronous load — used at app start by `SearchIndex`.
    /// Returns an empty file when the cache is missing.
    nonisolated static func loadFromDisk() -> StopCatalogFile? {
        guard let data = try? Data(contentsOf: diskURL) else { return nil }
        return try? JSONDecoder.iso8601.decode(StopCatalogFile.self, from: data)
    }

    static func ageOnDisk() -> TimeInterval? {
        loadFromDisk().map { Date().timeIntervalSince($0.savedAt) }
    }

    // MARK: - Write

    /// Merge a batch of newly observed stops into the persisted catalog.
    /// Newer EGO names always win (they're authoritative), but `seenOnLines`
    /// accumulates across calls so the union view of which lines pass each
    /// stop survives over time.
    func merge(observed: [StopCatalogEntry]) {
        var current: [String: StopCatalogEntry] = [:]
        if let file = Self.loadFromDisk() {
            for e in file.entries { current[e.stopNo] = e }
        }
        for newEntry in observed {
            if var existing = current[newEntry.stopNo] {
                existing = StopCatalogEntry(
                    stopNo: newEntry.stopNo,
                    name: newEntry.name,
                    address: newEntry.address ?? existing.address,
                    seenOnLines: Array(Set(existing.seenOnLines + newEntry.seenOnLines).prefix(8))
                )
                current[newEntry.stopNo] = existing
            } else {
                current[newEntry.stopNo] = newEntry
            }
        }
        let file = StopCatalogFile(
            schemaVersion: 1,
            savedAt: Date(),
            entries: current.values.sorted { $0.stopNo < $1.stopNo }
        )
        if let data = try? JSONEncoder.iso8601.encode(file) {
            try? data.write(to: Self.diskURL, options: .atomic)
        }
    }

    /// Replace the entire catalog (used at the end of a full refresh — drops
    /// any stops EGO has retired between scans).
    func replaceAll(_ entries: [StopCatalogEntry]) {
        let file = StopCatalogFile(
            schemaVersion: 1,
            savedAt: Date(),
            entries: entries.sorted { $0.stopNo < $1.stopNo }
        )
        if let data = try? JSONEncoder.iso8601.encode(file) {
            try? data.write(to: Self.diskURL, options: .atomic)
        }
    }
}
