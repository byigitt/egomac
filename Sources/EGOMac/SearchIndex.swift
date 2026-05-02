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

    private var stops: [StopSearchResult] = []
    private var lines: [LineSearchResult] = []

    /// Memoized last-query result so re-typing the same string is instant.
    private var stopQueryCache: [String: [StopSearchResult]] = [:]
    private var lineQueryCache: [String: [LineSearchResult]] = [:]

    private init() {
        loadStops()
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
            StopSearchResult(stopNo: $0.r, name: $0.n)
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

    /// Search stops by name OR ref. Returns up to `limit` results.
    func searchStops(_ query: String, limit: Int = 12) -> [StopSearchResult] {
        let q = Self.normalize(query)
        guard !q.isEmpty else { return [] }
        if let cached = stopQueryCache[q] { return cached }

        let isNumeric = q.allSatisfy { $0.isNumber }
        let scored: [(StopSearchResult, Int)] = stops.compactMap { stop in
            // Numeric: prefix-match on ref
            if isNumeric {
                if stop.stopNo.hasPrefix(q) { return (stop, 0) }
                if stop.stopNo.contains(q) { return (stop, 50) }
                return nil
            }
            // Text: substring on name (case+diacritic insensitive)
            let nName = Self.normalize(stop.name)
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
        stopQueryCache[q] = result
        return result
    }

    // MARK: - Lines (EGO ajax)

    /// Fetch the full line list (cached). Safe to call repeatedly.
    func ensureLinesLoaded() async {
        if linesLoaded { return }
        do {
            let html = try await Self.fetchLineListHTML()
            self.lines = Self.parseLineOptions(html: html)
            self.linesLoaded = true
            self.lineLoadError = nil
            DebugLog.log("search: loaded \(lines.count) lines")
        } catch {
            self.lineLoadError = error.localizedDescription
            DebugLog.log("search: line list fetch failed: \(error.localizedDescription)")
        }
    }

    func searchLines(_ query: String, limit: Int = 12) -> [LineSearchResult] {
        let q = Self.normalize(query)
        guard !q.isEmpty else { return [] }
        if let cached = lineQueryCache[q] { return cached }

        let scored: [(LineSearchResult, Int)] = lines.compactMap { line in
            let nLine = Self.normalize(line.lineNo)
            let nRoute = Self.normalize(line.route)
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
        lineQueryCache[q] = result
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
