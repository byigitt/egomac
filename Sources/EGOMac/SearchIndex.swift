import Foundation
import SwiftSoup
import Compression

/// Search results for the settings UI.
struct StopSearchResult: Identifiable, Hashable {
    let id = UUID()
    let stopNo: String        // "12207"
    let name: String          // "Güvenpark"
}

struct LineSearchResult: Identifiable, Hashable {
    let id = UUID()
    let lineNo: String        // "481"
    let route: String         // "UYANIŞ-ASFALT-...-CEYHUN"
}

/// Runtime in-memory index of Ankara EGO bus stops + lines, with Turkish-locale
/// fuzzy search. Stops come from a bundled JSON snapshot; lines come from
/// EGO's `/AjaxData/HatListesiOtobus` endpoint (lazy-fetched on first query).
@MainActor
final class SearchIndex: ObservableObject {
    static let shared = SearchIndex()

    @Published private(set) var stopsLoaded = false
    @Published private(set) var linesLoaded = false
    @Published private(set) var lineLoadError: String?

    private struct IndexedStop {
        let result: StopSearchResult
        let normalizedName: String
    }

    private struct IndexedLine {
        let result: LineSearchResult
        let normalizedLineNo: String
        let normalizedRoute: String
    }

    private var stops: [IndexedStop] = []
    private var lines: [IndexedLine] = []

    /// Memoized query results so re-typing the same string is instant.
    private var stopQueryCache: [String: [StopSearchResult]] = [:]
    private var lineQueryCache: [String: [LineSearchResult]] = [:]
    private var lineLoadTask: Task<Void, Never>?

    private init() {
        loadStops()
        loadStopCatalog()
    }

    /// Total stops indexed for search (embedded + EGO catalog merged).
    /// Surfaced in Settings.
    nonisolated static func diskCatalogSummary() -> (count: Int, age: TimeInterval?)? {
        guard let f = StopCatalog.loadFromDisk() else { return nil }
        return (f.entries.count, Date().timeIntervalSince(f.savedAt))
    }

    /// Re-merge the EGO catalog from disk — called after a successful
    /// `BusViewModel.refreshStopCatalog()` so newly fetched stops become
    /// searchable immediately.
    func reloadStopCatalog() {
        loadStopCatalog()
        // Drop cached query results so the next search hits the new merged list.
        stopQueryCache.removeAll()
    }

    /// Merge EGO catalog entries on top of the embedded blob. EGO names win
    /// when the same stopNo exists in both. Entries only in the blob (older
    /// stops EGO has retired) are kept as fallback so search never regresses.
    private func loadStopCatalog() {
        guard let file = StopCatalog.loadFromDisk() else { return }
        // Build a map of EGO entries first.
        var byStop: [String: IndexedStop] = [:]
        byStop.reserveCapacity(stops.count + file.entries.count)
        // Seed with the existing embedded blob so we keep its coverage.
        for s in stops { byStop[s.result.stopNo] = s }
        // EGO wins.
        for e in file.entries {
            let result = StopSearchResult(stopNo: e.stopNo, name: e.name)
            byStop[e.stopNo] = IndexedStop(result: result, normalizedName: Self.normalize(e.name))
        }
        self.stops = Array(byStop.values)
        self.stopsLoaded = true
        DebugLog.log("search: merged catalog \(file.entries.count) EGO + embedded → \(self.stops.count) total")
    }

    // MARK: - Stops (bundled OSM snapshot)

    private struct StopsFile: Decodable {
        let stops: [Entry]
        struct Entry: Decodable { let r: String; let n: String }
    }

    private func loadStops() {
        // Decode the embedded gzip+base64 blob — no file IO so macOS doesn't
        // demand Desktop folder access when the .app happens to live there.
        guard let gzData = Data(base64Encoded: StopsBlob.base64,
                                options: .ignoreUnknownCharacters),
              let raw = Self.gunzip(gzData),
              let parsed = try? JSONDecoder().decode(StopsFile.self, from: raw)
        else {
            DebugLog.log("stops blob decode failed — search disabled")
            return
        }
        self.stops = parsed.stops.map {
            let result = StopSearchResult(stopNo: $0.r, name: $0.n)
            return IndexedStop(result: result, normalizedName: Self.normalize($0.n))
        }
        self.stopsLoaded = true
        DebugLog.log("search: loaded \(stops.count) stops (embedded)")
    }

    /// Decompress raw deflate/gzip bytes via Compression framework.
    private static func gunzip(_ data: Data) -> Data? {
        // Strip gzip header (10 bytes) + trailing 8 bytes of footer; what's
        // left is raw deflate which Apple's COMPRESSION_ZLIB can decode.
        guard data.count > 18 else { return nil }
        let body = data.subdata(in: 10..<(data.count - 8))
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: 4 * 1024 * 1024)
        defer { dst.deallocate() }
        let n = body.withUnsafeBytes { src -> Int in
            guard let base = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_decode_buffer(dst, 4 * 1024 * 1024, base, body.count, nil, COMPRESSION_ZLIB)
        }
        guard n > 0 else { return nil }
        return Data(bytes: dst, count: n)
    }

    /// Resolve a batch of stop numbers to names in O(N + M).
    /// Used by `RouteIndex` to label each stop on a line's route. Stops we
    /// don't know yield no entry (caller falls back to a placeholder).
    func lookupStopNames(_ stopNos: Set<String>) -> [String: String] {
        guard !stopNos.isEmpty else { return [:] }
        var out: [String: String] = [:]
        out.reserveCapacity(stopNos.count)
        for indexed in stops where stopNos.contains(indexed.result.stopNo) {
            out[indexed.result.stopNo] = indexed.result.name
            if out.count == stopNos.count { break }
        }
        return out
    }

    /// Search stops by name OR ref. Returns up to `limit` results.
    func searchStops(_ query: String, limit: Int = 12) -> [StopSearchResult] {
        let q = Self.normalize(query)
        guard !q.isEmpty else { return [] }
        let cacheKey = "\(limit)|\(q)"
        if let cached = stopQueryCache[cacheKey] { return cached }

        let isNumeric = q.allSatisfy { $0.isNumber }
        let scored: [(StopSearchResult, Int)] = stops.compactMap { indexed in
            let stop = indexed.result
            // Numeric: prefix-match on ref
            if isNumeric {
                if stop.stopNo.hasPrefix(q) { return (stop, 0) }
                if stop.stopNo.contains(q) { return (stop, 50) }
                return nil
            }
            // Text: substring on name (case+diacritic insensitive)
            let nName = indexed.normalizedName
            if nName == q { return (stop, 0) }
            if nName.hasPrefix(q) { return (stop, 10) }
            if nName.contains(q) { return (stop, 50) }
            // Word-boundary match
            for word in nName.split(separator: " ") where word.hasPrefix(q) {
                return (stop, 30)
            }
            return nil
        }
        let sorted = scored
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { $0.0 }
        let result = Array(sorted)
        stopQueryCache[cacheKey] = result
        return result
    }

    // MARK: - Lines (EGO ajax)

    /// Fetch the full line list (cached). Safe to call repeatedly.
    func ensureLinesLoaded() async {
        if linesLoaded { return }
        if let lineLoadTask {
            await lineLoadTask.value
            return
        }

        let task = Task { @MainActor in
            defer { lineLoadTask = nil }
            do {
                let html = try await Self.fetchLineListHTML()
                self.lines = Self.parseLineOptions(html: html).map {
                    IndexedLine(
                        result: $0,
                        normalizedLineNo: Self.normalize($0.lineNo),
                        normalizedRoute: Self.normalize($0.route)
                    )
                }
                self.linesLoaded = true
                self.lineLoadError = nil
                DebugLog.log("search: loaded \(lines.count) lines")
            } catch {
                self.lineLoadError = error.localizedDescription
                DebugLog.log("search: line list fetch failed: \(error.localizedDescription)")
            }
        }
        lineLoadTask = task
        await task.value
    }

    func searchLines(_ query: String, limit: Int = 12) -> [LineSearchResult] {
        let q = Self.normalize(query)
        guard !q.isEmpty else { return [] }
        let cacheKey = "\(limit)|\(q)"
        if let cached = lineQueryCache[cacheKey] { return cached }

        let scored: [(LineSearchResult, Int)] = lines.compactMap { indexed in
            let line = indexed.result
            let nLine = indexed.normalizedLineNo
            let nRoute = indexed.normalizedRoute
            // Exact match
            if nLine == q { return (line, 0) }
            if nLine.hasPrefix(q) { return (line, 5) }
            if nRoute.hasPrefix(q) { return (line, 15) }
            if nLine.contains(q) { return (line, 30) }
            if nRoute.contains(q) { return (line, 40) }
            return nil
        }
        let sorted = scored
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { $0.0 }
        let result = Array(sorted)
        lineQueryCache[cacheKey] = result
        return result
    }

    // MARK: - EGO line-list endpoint

    /// POST `/AjaxData/HatListesiOtobus` — returns ALL bus lines as `<option>` elements.
    /// Server ignores any body parameters (we don't filter server-side).
    ///
    /// Example option:
    ///   `<option value="481"> (481 ) - UYANIŞ-ASFALT-... -CEYHUN A.K.CAD</option>`
    private static func fetchLineListHTML() async throws -> String {
        let url = URL(string: "https://www.ego.gov.tr/AjaxData/HatListesiOtobus")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.ego.gov.tr/tr/hareketsaatleri", forHTTPHeaderField: "Referer")
        req.setValue("https://www.ego.gov.tr", forHTTPHeaderField: "Origin")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = "".data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let html = String(data: data, encoding: .utf8) else {
            throw EGOError.invalidEncoding
        }
        return html
    }

    private static func parseLineOptions(html: String) -> [LineSearchResult] {
        // The endpoint returns just `<option ...>` fragments — wrap in a parent.
        let wrapped = "<select>\(html)</select>"
        guard let doc = try? SwiftSoup.parse(wrapped) else { return [] }
        let opts = (try? doc.select("option").array()) ?? []
        var out: [LineSearchResult] = []
        for opt in opts {
            let value = (try? opt.attr("value")) ?? ""
            // Skip placeholder rows like value="0".
            guard !value.isEmpty, value != "0" else { continue }
            let text = (try? opt.text()) ?? ""
            // Format: " (481 ) - UYANIŞ-..."
            // Strip the redundant "(NNN ) - " prefix to keep just the route.
            let route = text
                .replacingOccurrences(of: "( \(value) )", with: "")
                .replacingOccurrences(of: "(\(value))", with: "")
                .replacingOccurrences(of: "(\(value) )", with: "")
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                .trimmingCharacters(in: .whitespaces)
            out.append(LineSearchResult(lineNo: value, route: route))
        }
        return out
    }

    // MARK: - Turkish-locale aware normalization

    /// Lowercase + strip diacritics + Turkish-letter folding so users can type
    /// "guvenpark" or "GÜVENPARK" or "güvenpark" interchangeably.
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased(with: Locale(identifier: "tr_TR"))
        // Fold common Turkish characters to ASCII equivalents.
        let folded = lowered
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "İ", with: "i")
            .replacingOccurrences(of: "ş", with: "s")
            .replacingOccurrences(of: "ç", with: "c")
            .replacingOccurrences(of: "ğ", with: "g")
            .replacingOccurrences(of: "ü", with: "u")
            .replacingOccurrences(of: "ö", with: "o")
        return folded
            .applyingTransform(.stripDiacritics, reverse: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? folded
    }
}
