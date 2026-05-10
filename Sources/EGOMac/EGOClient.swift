import Foundation

/// Thread-safe client for the EGO Cep'te private JSON API used by the iOS app.
///
/// Discovered via `pymobiledevice3 pcap` against the iOS app:
///
///   GET https://egocptsrvand.ego.gov.tr/mblSrv14/service.asp
///       ?FNC=Otobusler&VER=3.1.0&LAN=tr&DURAK={stopNo}                 → all lines at stop
///       ?FNC=Otobus   &VER=3.1.0&LAN=tr&HAT={lineNo}&DURAK={stopNo}    → all live buses on a line
///
/// The endpoint returns a JSON envelope `{ table: [row], message: "", status: "TRUE" }`.
/// Live rows carry `plaka_no` / `lat` / `lng` / `saniye`; scheduled rows have
/// `arac_no == "-"` and just a `sure` string with the next departure note.
///
/// The host is fronted by an F5 BIG-IP that hands out a `TS010fd228=...` cookie.
/// Our probes show the cookie is NOT enforced, but we still accept it and
/// replay it in case that changes.
actor EGOClient {
    private let session: URLSession

    private static let serviceBase = URL(
        string: "https://egocptsrvand.ego.gov.tr/mblSrv14/service.asp"
    )!
    /// Base path is rotated by EGO between mblSrv9..mblSrv30; they all alias to
    /// the same handler. Pinning to one number keeps logs readable.

    /// Public website used as a fallback for the line catalog and schedule
    /// pages — see `docs/api-discovery.md`. The mobile JSON service does not
    /// expose either of those.
    private static let webBase = URL(string: "https://www.ego.gov.tr")!

    /// Mirrors what the iOS Cep'te app sends. The website endpoints accept it
    /// too — they only sniff for the `X-Requested-With` header for AJAX gating.
    private static let userAgent =
        "EGO Cepte/8 CFNetwork/1568.300.101 Darwin/24.0.0"

    private static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // MARK: - Caches
    /// `fetchAllLines` result — changes at most once a day per EGO ops cycle,
    /// so we cache it for 24h. Schedules and route samples have their own
    /// caches in `RouteIndex` and the schedule loader.
    private var linesCache: (timestamp: Date, lines: [Line])?
    private static let linesCacheTTL: TimeInterval = 24 * 60 * 60

    /// Local persisted copy of the line catalog so the popover can render
    /// the search list before the network round trip completes on launch.
    private static let linesDiskURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ego-mac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lines.json")
    }()

    private struct LinesDiskFormat: Codable {
        let savedAt: Date
        let lines: [Line]
    }

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpCookieAcceptPolicy = .always
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Fetch every line currently being served at `stopNo`. Returns one row per
    /// line: a live bus when one exists, a scheduled-departure row otherwise.
    func fetchBuses(stopNo: String) async throws -> [Bus] {
        let url = Self.url(fnc: "Otobusler", params: ["DURAK": stopNo])
        let rows = try await callAPI(url: url)
        return rows.enumerated().map { idx, row in
            row.toBus(stopNo: stopNo, sourceIndex: idx)
        }
    }

    /// Fetch every live bus currently on `line`, with ETA computed against the
    /// user's stop. Sorted by ETA ascending (`saniye=999999` / "Geçti" goes last).
    /// This is the endpoint the iOS app uses for the per-line list.
    ///
    /// Side effect: the returned bus rows are also fed to `RouteIndex.shared`
    /// so we can rebuild the line's stop sequence over time without a
    /// dedicated endpoint.
    func fetchLineBuses(line: String, atStop stopNo: String) async throws -> [Bus] {
        let url = Self.url(fnc: "Otobus", params: ["HAT": line, "DURAK": stopNo])
        let rows = try await callAPI(url: url)
        let buses = rows.enumerated().map { idx, row in
            row.toBus(stopNo: stopNo, sourceIndex: idx)
        }
        await RouteIndex.shared.record(buses: buses, forLine: line)
        return buses.sorted(by: Self.lineOrder)
    }

    /// Return every bus line known to EGO. Cached for 24h in-actor and on
    /// disk under `~/.ego-mac/lines.json`. Disk cache is used as a fast cold
    /// start when the network call hasn't completed yet.
    func fetchAllLines() async throws -> [Line] {
        // 1. In-memory cache.
        if let c = linesCache, Date().timeIntervalSince(c.timestamp) < Self.linesCacheTTL {
            return c.lines
        }
        // 2. Disk cache (warm start).
        if let disk = Self.loadLinesFromDisk(),
           Date().timeIntervalSince(disk.savedAt) < Self.linesCacheTTL {
            linesCache = (disk.savedAt, disk.lines)
            // Refresh in the background so the next call sees fresh data.
            Task.detached { [weak self] in
                _ = try? await self?.refreshLineCatalog()
            }
            return disk.lines
        }
        // 3. Network.
        let lines = try await fetchAllLinesUncached()
        linesCache = (Date(), lines)
        Self.saveLinesToDisk(lines)
        DebugLog.log("lines fetched: \(lines.count) hat")
        return lines
    }

    /// Synchronous best-effort accessor used by code paths that can't `await`
    /// (e.g. SwiftUI initialisers). Returns the disk cache if present.
    nonisolated static func cachedLinesFromDisk() -> [Line] {
        loadLinesFromDisk()?.lines ?? []
    }

    private static func loadLinesFromDisk() -> LinesDiskFormat? {
        guard let data = try? Data(contentsOf: linesDiskURL) else { return nil }
        return try? JSONDecoder.iso8601.decode(LinesDiskFormat.self, from: data)
    }

    private static func saveLinesToDisk(_ lines: [Line]) {
        let payload = LinesDiskFormat(savedAt: Date(), lines: lines)
        if let data = try? JSONEncoder.iso8601.encode(payload) {
            try? data.write(to: linesDiskURL, options: .atomic)
        }
    }

    /// Force a refresh of the line catalog (bypasses the 24h cache).
    func refreshLineCatalog() async throws -> [Line] {
        let lines = try await fetchAllLinesUncached()
        linesCache = (Date(), lines)
        return lines
    }

    private func fetchAllLinesUncached() async throws -> [Line] {
        let url = Self.webBase.appendingPathComponent("AjaxData/HatListesi")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("https://www.ego.gov.tr/hareketsaatleri", forHTTPHeaderField: "Referer")
        req.httpBody = Data()                              // empty body — returns full list
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw EGOError.httpStatus(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw EGOError.invalidEncoding
        }
        return Self.parseHatListesi(html: html)
    }

    /// Fetch one line's full schedule (Hafta içi / Cumartesi / Pazar) plus the
    /// metadata table at the top (kalkış / varış / mesafe / süre).
    /// Backed by `https://www.ego.gov.tr/HareketSaatleri` POST.
    func fetchLineSchedule(line: String) async throws -> LineSchedule {
        let url = Self.webBase.appendingPathComponent("HareketSaatleri")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "hat_no1=\(Self.urlEncode(line))".data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw EGOError.httpStatus(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw EGOError.invalidEncoding
        }
        guard let parsed = Self.parseSchedule(html: html, lineCode: line) else {
            throw EGOError.serverMessage("Hareket saatleri okunamadı")
        }
        DebugLog.log("schedule \(line): \(parsed.weekdayDepartures.count)/\(parsed.saturdayDepartures.count)/\(parsed.sundayDepartures.count) (HC/Ct/Pz), \(parsed.routeStops.count) stops")
        return parsed
    }

    /// Sweep every line's `HareketSaatleri` page and aggregate a deduped
    /// catalog of every stop EGO knows about. ~667 requests, semaphored to
    /// `concurrency` in-flight at a time. Reports 0...1 progress + the
    /// running deduped count via `progress`.
    ///
    /// Result is also written to `~/.ego-mac/stops-catalog.json` via
    /// `StopCatalog.replaceAll` once the sweep finishes.
    func fetchFullStopCatalog(
        concurrency: Int = 8,
        progress: ((_ done: Int, _ total: Int, _ uniqueStops: Int) -> Void)? = nil
    ) async throws -> [StopCatalogEntry] {
        let lines = try await fetchAllLines()
        let total = lines.count
        DebugLog.log("catalog refresh start: \(total) hat")

        // Aggregate buffer protected by a tiny actor-local lock pattern.
        // We use an `actor`-style box to avoid Swift 6 strict-Sendable noise.
        actor Aggregator {
            var dict: [String: StopCatalogEntry] = [:]
            var done: Int = 0
            func merge(line: String, stops: [LineStop]) -> Int {
                done += 1
                for s in stops {
                    if var existing = dict[s.stopNo] {
                        if !existing.seenOnLines.contains(line) {
                            existing.seenOnLines.append(line)
                            existing.seenOnLines = Array(existing.seenOnLines.prefix(8))
                            dict[s.stopNo] = existing
                        }
                    } else {
                        dict[s.stopNo] = StopCatalogEntry(
                            stopNo: s.stopNo, name: s.name, address: nil,
                            seenOnLines: [line]
                        )
                    }
                }
                return done
            }
            func snapshot() -> (done: Int, count: Int, all: [StopCatalogEntry]) {
                (done, dict.count, Array(dict.values))
            }
        }
        let agg = Aggregator()

        // Throttle with a counting semaphore. Swift's TaskGroup doesn't have a
        // built-in concurrency cap, so we rate-limit with a chunked dispatch.
        await withTaskGroup(of: Void.self) { group in
            var inflight = 0
            var index = 0
            // Seed the initial batch.
            while inflight < concurrency && index < total {
                let line = lines[index]; index += 1; inflight += 1
                group.addTask { [weak self] in
                    guard let self else { return }
                    if let schedule = try? await self.fetchLineSchedule(line: line.code) {
                        let done = await agg.merge(line: line.code, stops: schedule.routeStops)
                        let snap = await agg.snapshot()
                        await MainActor.run { progress?(done, total, snap.count) }
                    } else {
                        let done = await agg.merge(line: line.code, stops: [])
                        await MainActor.run { progress?(done, total, 0) }
                    }
                }
            }
            // Top up as each finishes.
            for await _ in group {
                if index < total {
                    let line = lines[index]; index += 1
                    group.addTask { [weak self] in
                        guard let self else { return }
                        if let schedule = try? await self.fetchLineSchedule(line: line.code) {
                            let done = await agg.merge(line: line.code, stops: schedule.routeStops)
                            let snap = await agg.snapshot()
                            await MainActor.run { progress?(done, total, snap.count) }
                        } else {
                            let done = await agg.merge(line: line.code, stops: [])
                            await MainActor.run { progress?(done, total, 0) }
                        }
                    }
                }
            }
        }

        let final = await agg.snapshot()
        DebugLog.log("catalog refresh ok: \(final.count) stops, \(final.done) lines")
        await StopCatalog.shared.replaceAll(final.all)
        return final.all
    }

    /// Fetch every stop in parallel and return a result-per-stop dictionary.
    /// Errors per stop are isolated — one bad stop doesn't fail the whole batch.
    func fetchAll(stopNos: [String]) async -> [String: Result<[Bus], Error>] {
        var seen = Set<String>()
        let uniqueStopNos = stopNos.filter { seen.insert($0).inserted }

        return await withTaskGroup(of: (String, Result<[Bus], Error>).self) { group in
            for stop in uniqueStopNos {
                group.addTask {
                    do {
                        let buses = try await self.fetchBuses(stopNo: stop)
                        return (stop, .success(buses))
                    } catch {
                        return (stop, .failure(error))
                    }
                }
            }
            var out: [String: Result<[Bus], Error>] = [:]
            for await (stop, result) in group {
                out[stop] = result
            }
            return out
        }
    }

    // MARK: - HTTP

    private func callAPI(url: URL) async throws -> [EGORow] {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: req)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw EGOError.httpStatus(http.statusCode)
        }

        do {
            let envelope = try Self.decoder.decode(EGOEnvelope.self, from: data)
            if envelope.status.uppercased() == "FALSE" && (envelope.message ?? "").isEmpty == false {
                throw EGOError.serverMessage(envelope.message ?? "")
            }
            return envelope.table ?? []
        } catch let DecodingError.dataCorrupted(ctx) {
            throw EGOError.decoding(ctx.debugDescription)
        } catch {
            throw error
        }
    }

    // MARK: - URL building

    private static func url(fnc: String, params: [String: String]) -> URL {
        var comps = URLComponents(url: serviceBase, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "FNC", value: fnc),
            URLQueryItem(name: "VER", value: "3.1.0"),
            URLQueryItem(name: "LAN", value: "tr"),
        ]
        // Stable param order — useful for log grepping.
        for k in params.keys.sorted() {
            items.append(URLQueryItem(name: k, value: params[k]))
        }
        comps.queryItems = items
        return comps.url!
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // EGO mixes string/number types, so all our Codable fields are String? and we
        // coerce on the way in. No keyDecodingStrategy needed (we already use snake_case).
        return d
    }()

    /// URL-encode for query strings / form bodies — EGO line codes contain
    /// dashes and the ÖHO suffix is sometimes hyphenated, so we keep it simple.
    private static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+;")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - HTML parsers (website fallback endpoints)

    /// Parse `<option value="481"> (481 ) - UYANIŞ-...”</option>` rows out of
    /// the `/AjaxData/HatListesi` payload. The first option is always
    /// `value="0"` ("Hat seçiniz") which we drop.
    static func parseHatListesi(html: String) -> [Line] {
        // Lightweight regex parse — SwiftSoup would be overkill here.
        let pattern = #"<option\s+value="([^"]+)"\s*>\s*([^<]+?)\s*</option>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        var seen = Set<String>()
        var out: [Line] = []
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        re.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
            guard let m = match, m.numberOfRanges == 3 else { return }
            let code = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let text = decodeHtmlEntities(ns.substring(with: m.range(at: 2)))
            guard code != "0", !code.isEmpty, seen.insert(code).inserted else { return }
            // EGO option text shape: " (481 ) - UYANIŞ-ASFALT-15 TEMMUZ KIZILAY …"
            // We strip the leading "(code) - " prefix when present.
            let prefix = #"^\s*\(\s*\#(NSRegularExpression.escapedPattern(for: code))\s*\)\s*-\s*"#
            let cleaned = text.replacingOccurrences(
                of: prefix, with: "", options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            let isOzel = cleaned.uppercased().contains("ÖHO")
            out.append(Line(code: code, displayName: cleaned, isOzel: isOzel))
        }
        return out
    }

    /// Pull schedule + metadata + ordered stops out of `/HareketSaatleri` HTML.
    ///
    /// The page below `<!-- Saat Tablosu -->` is **two `<table>`s back to back**:
    ///
    /// 1. Schedule table — a single `<tr>` with three `<td>`s, one per day
    ///    type (Hafta içi / Cumartesi / Pazar). Each cell is a long string
    ///    where multiple departures are split by `<br>` (or `<p>`) tags. A
    ///    typical departure looks like `"00:01 SIHHIYEDEN BAŞLAR/SIHHIYEDE
    ///    BİTER-SEMT TEN-00:45"` — the leading `HH:MM` is the actual
    ///    departure, the trailing free text is the note.
    ///
    /// 2. Stop table — one `<tr>` per stop with four `<td>`s:
    ///    `(sıra | durak_no | DURAK_ADI | adres)`. We hoist this directly
    ///    into `LineSchedule.routeStops` so callers don't need to brute-force
    ///    discover stop sequences from `RouteIndex`.
    ///
    /// The metadata block (Hat Adı / Kalkış Yeri / Mesafe / Süre) lives
    /// ABOVE the `<!-- Saat Tablosu -->` comment, in the same simple
    /// `<td>label</td><td>:</td><td>value</td>` pattern as before.
    static func parseSchedule(html: String, lineCode: String) -> LineSchedule? {
        guard let scheduleStart = html.range(of: "<!-- Saat Tablosu -->") else { return nil }
        let scheduleHtml = String(html[scheduleStart.lowerBound...])

        // --- Tables in order ---
        let tables = extractTables(in: scheduleHtml)

        // Schedule table is the first one. If there's only one (some legacy
        // line pages), use it as schedule and produce empty stops.
        let scheduleTable = tables.first ?? scheduleHtml
        let weekday  = extractDepartures(scheduleTable: scheduleTable, columnIndex: 0)
        let saturday = extractDepartures(scheduleTable: scheduleTable, columnIndex: 1)
        let sunday   = extractDepartures(scheduleTable: scheduleTable, columnIndex: 2)

        // Stop table is the second one. Fail gracefully when it's missing.
        let routeStops: [LineStop] = tables.count >= 2
            ? extractStops(stopTable: tables[1], lineCode: lineCode)
            : []

        // Metadata block lives ABOVE the schedule comment.
        let header = String(html[..<scheduleStart.lowerBound])
        let lineName    = extractMetaField(header, label: "Hat Adı") ?? ""
        let originName  = extractMetaField(header, label: "Kalkış Yeri")
        let destinName  = extractMetaField(header, label: "Varış Yeri")
        let distanceKm  = extractMetaField(header, label: "Mesafesi").flatMap { parseLeadingInt($0) }
        let durationMin = extractMetaField(header, label: "Süresi") .flatMap { parseLeadingInt($0) }

        return LineSchedule(
            lineCode: lineCode,
            lineName: lineName,
            originName: originName,
            destinationName: destinName,
            distanceKm: distanceKm,
            durationMinutes: durationMin,
            weekdayDepartures: weekday,
            saturdayDepartures: saturday,
            sundayDepartures: sunday,
            routeStops: routeStops
        )
    }

    /// Extract every `<table>...</table>` block, body only (without surrounding
    /// table tags). Used to slice the schedule + stop list apart.
    private static func extractTables(in html: String) -> [String] {
        let re = try? NSRegularExpression(pattern: #"<table[^>]*>([\s\S]*?)</table>"#, options: [])
        guard let re else { return [] }
        let ns = html as NSString
        var out: [String] = []
        re.enumerateMatches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges == 2 else { return }
            out.append(ns.substring(with: m.range(at: 1)))
        }
        return out
    }

    /// Pull every departure entry out of one column of the schedule table.
    /// Each cell is a flat string with multiple `<br>`-separated entries; we
    /// split on `<br>` (or `<p>`) AND on every `"HH:MM"` boundary so cells
    /// that compress entries with literal newlines still come out right.
    private static func extractDepartures(scheduleTable: String, columnIndex: Int) -> [LineSchedule.DepartureEntry] {
        let rowRe  = try? NSRegularExpression(pattern: #"<tr[^>]*>([\s\S]*?)</tr>"#, options: [])
        let cellRe = try? NSRegularExpression(pattern: #"<td[^>]*>([\s\S]*?)</td>"#, options: [])
        guard let rowRe, let cellRe else { return [] }

        let ns = scheduleTable as NSString
        var out: [LineSchedule.DepartureEntry] = []
        rowRe.enumerateMatches(in: scheduleTable, options: [],
                               range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match, m.numberOfRanges == 2 else { return }
            let rowHtml = ns.substring(with: m.range(at: 1))
            let rowNs = rowHtml as NSString
            var cells: [String] = []
            cellRe.enumerateMatches(in: rowHtml, options: [],
                                    range: NSRange(location: 0, length: rowNs.length)) { cm, _, _ in
                guard let c = cm, c.numberOfRanges == 2 else { return }
                cells.append(rowNs.substring(with: c.range(at: 1)))
            }
            guard cells.count > columnIndex else { return }
            let cellHtml = cells[columnIndex]

            // Normalise <br> / <p> into newlines, then split on whitespace.
            let normalised = cellHtml
                .replacingOccurrences(of: #"<br[^>]*>"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: #"</?p[^>]*>"#, with: "\n", options: .regularExpression)
            let plain = decodeHtmlEntities(stripTags(normalised))

            // Find every "HH:MM" — the prefix of one departure entry.
            // The note for entry N is the substring between HH:MM_N and HH:MM_(N+1).
            let timeRe = try? NSRegularExpression(pattern: #"\b(\d{1,2}:\d{2})\b"#, options: [])
            guard let timeRe else { return }
            let pNs = plain as NSString
            let matches = timeRe.matches(in: plain, options: [],
                                         range: NSRange(location: 0, length: pNs.length))
            for (idx, tm) in matches.enumerated() {
                let time = pNs.substring(with: tm.range(at: 1))
                let noteStart = tm.range.location + tm.range.length
                let noteEnd = (idx + 1 < matches.count) ? matches[idx + 1].range.location : pNs.length
                let noteRange = NSRange(location: noteStart, length: max(0, noteEnd - noteStart))
                var note: String? = pNs.substring(with: noteRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "- \t"))
                if note?.isEmpty == true { note = nil }
                out.append(.init(time: time, note: note))
            }
        }
        return out
    }

    /// Parse the stop table — four `<td>`s per row: `sıra | durak_no | ad | adres`.
    /// The header row ("Sıra | Durak No | ...") shows up as a `<th>`-only row
    /// which our `<td>` regex skips automatically.
    private static func extractStops(stopTable: String, lineCode: String) -> [LineStop] {
        let rowRe  = try? NSRegularExpression(pattern: #"<tr[^>]*>([\s\S]*?)</tr>"#, options: [])
        let cellRe = try? NSRegularExpression(pattern: #"<td[^>]*>([\s\S]*?)</td>"#, options: [])
        guard let rowRe, let cellRe else { return [] }

        let ns = stopTable as NSString
        var out: [LineStop] = []
        rowRe.enumerateMatches(in: stopTable, options: [],
                               range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match, m.numberOfRanges == 2 else { return }
            let rowHtml = ns.substring(with: m.range(at: 1))
            let rowNs = rowHtml as NSString
            var cells: [String] = []
            cellRe.enumerateMatches(in: rowHtml, options: [],
                                    range: NSRange(location: 0, length: rowNs.length)) { cm, _, _ in
                guard let c = cm, c.numberOfRanges == 2 else { return }
                cells.append(rowNs.substring(with: c.range(at: 1)))
            }
            guard cells.count >= 3 else { return }
            let raw = cells.map { decodeHtmlEntities(stripTags($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let seq = Int(raw[0]), seq > 0 else { return }
            let stopNo = raw[1]
            // EGO sometimes emits empty stop numbers in pathological cases
            guard !stopNo.isEmpty else { return }
            let name = raw[2].isEmpty ? "Durak \(stopNo)" : raw[2]
            // Coordinates are NOT in this page — we'll fill them in lazily from
            // RouteIndex's GPS observations once a live bus passes through.
            out.append(LineStop(
                lineCode: lineCode,
                sequence: seq,
                stopNo: stopNo,
                name: name,
                latitude: nil,
                longitude: nil
            ))
        }
        return out
    }

    private static func extractMetaField(_ html: String, label: String) -> String? {
        // Schedule pages render metadata as adjacent `<td>` cells:
        // `<td>Hat Adı</td><td class="...">:</td><td class="...">UYANIŞ-...</td>`
        // We tolerate variable whitespace and the `:` separator cell.
        let pattern = "<td[^>]*>\\s*\(NSRegularExpression.escapedPattern(for: label))\\s*</td>\\s*<td[^>]*>\\s*:\\s*</td>\\s*<td[^>]*>([\\s\\S]*?)</td>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let m = re.firstMatch(in: html, options: [],
                                    range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 2 else { return nil }
        let raw = ns.substring(with: m.range(at: 1))
        return decodeHtmlEntities(stripTags(raw))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseLeadingInt(_ s: String) -> Int? {
        let digits = s.prefix(while: { $0.isNumber })
        return digits.isEmpty ? nil : Int(digits)
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
         .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Decode the small set of HTML entities EGO actually emits (it never
    /// uses anything fancier than `&amp;`, `&#199;`, `&#214;`, etc.).
    private static func decodeHtmlEntities(_ s: String) -> String {
        var out = s
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        // Numeric entities (decimal): &#199; → Ç
        let numericRe = try? NSRegularExpression(pattern: #"&#(\d+);"#, options: [])
        let ns = out as NSString
        if let re = numericRe {
            // Scan in reverse so substitution offsets stay valid.
            let matches = re.matches(in: out, options: [], range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches {
                guard m.numberOfRanges == 2 else { continue }
                let codeStr = ns.substring(with: m.range(at: 1))
                if let code = UInt32(codeStr), let scalar = Unicode.Scalar(code) {
                    out = (out as NSString).replacingCharacters(in: m.range, with: String(Character(scalar)))
                }
            }
        }
        return out
    }

    /// Sort key used by `fetchLineBuses`:
    /// 1. live, ETA ascending
    /// 2. live but past ("Geçti" / saniye=999999)
    /// 3. scheduled (no plate)
    private static func lineOrder(_ a: Bus, _ b: Bus) -> Bool {
        func rank(_ x: Bus) -> Int {
            if x.etaSeconds != nil { return 0 }
            if x.hasLiveData { return 1 }       // past
            return 2                             // scheduled
        }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb }
        switch (a.etaSeconds, b.etaSeconds) {
        case let (l?, r?): return l < r
        default:
            // Both nil — tie-break on busStopSeq (closer first), then plate.
            return (a.busStopSeq ?? .max) < (b.busStopSeq ?? .max)
        }
    }
}

// MARK: - Wire format

/// Envelope returned by every `service.asp?FNC=...` call.
private struct EGOEnvelope: Decodable {
    let table: [EGORow]?
    let message: String?
    let status: String

    private enum CodingKeys: String, CodingKey { case table, message, status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.table = try? c.decode([EGORow].self, forKey: .table)
        self.message = try? c.decode(String.self, forKey: .message)
        self.status = (try? c.decode(String.self, forKey: .status)) ?? "TRUE"
    }
}

/// A single row from `table[]`. EGO sends every value as a string, so we keep
/// them strings and parse on demand inside `toBus`. `arac_no == "-"` (or empty)
/// signals a scheduled-only row that has no plate / no GPS / no ETA.
private struct EGORow: Decodable {
    let arac_no: String?
    let plaka_no: String?
    let hat_no: String?
    let hat_kod: String?
    let hat_kisa_kod: String?
    let hat_ad: String?
    let sure: String?
    let saniye: String?
    let hiz: String?
    let lat: String?
    let lng: String?
    let durak_no: String?
    let onceki_durak_no: String?
    let durak_sira_no: String?
    let secili_durak_no: String?
    let secili_durak_sira_no: String?
    let aci: String?
    let doluluk: String?
    let konum_tarihi: String?
    let yon: String?
    let durum: String?
    let konum: String?
    let detay: String?

    /// Map a raw EGO row into our `Bus` model.
    func toBus(stopNo: String, sourceIndex: Int) -> Bus {
        let line = (hat_kisa_kod?.nonEmpty
                    ?? hat_no?.nonEmpty
                    ?? hat_kod?.nonEmpty
                    ?? "?")
        let route = hat_ad?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // --- Live vs scheduled ---
        let plate = plaka_no?.nonEmpty
        let aracId = (arac_no?.nonEmpty == "-" ? nil : arac_no?.nonEmpty)
        let isLiveRow = plate != nil || lat?.nonEmpty != nil

        // --- ETA semantics ---
        // EGO encodes "bus already passed your stop" as `saniye=999999` and
        // `sure=Geçti`. Treat that as no ETA but keep the row visible.
        var etaSeconds: Int? = nil
        var pastFlag = false
        let sureText = sure?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let raw = saniye, let n = Int(raw) {
            if n >= 999_000 {
                pastFlag = true
            } else {
                etaSeconds = max(0, n)
            }
        } else if isLiveRow {
            // Fallback for older payloads that only return `sure` text.
            etaSeconds = Self.parseSureToSeconds(sureText)
        }
        if sureText.localizedCaseInsensitiveContains("geçti") { pastFlag = true }

        // --- Stop sequence numbers ---
        let busSeq = durak_sira_no.flatMap { Int($0) }
        let userSeq = secili_durak_sira_no.flatMap { Int($0) }
        let stopPosition: String? = {
            if let user = userSeq, let bus = busSeq {
                return "\(user)/\(bus)"
            }
            return nil
        }()

        // --- Speed ("24 km" → 24) ---
        let speedKmh: Int? = {
            guard let h = hiz else { return nil }
            let digits = h.filter(\.isNumber)
            return digits.isEmpty ? nil : Int(digits)
        }()

        // --- Coordinates ---
        let latVal = lat.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        let lngVal = lng.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }

        // --- Heading ---
        let heading = aci.flatMap { Int($0) }

        // --- Last seen timestamp ---
        let lastSeen = konum_tarihi.flatMap(Self.parseLastUpdate)

        // --- Detay split (legacy: "Körüklü, Engelli") ---
        let attrs: [String] = (detay ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // --- Schedule note ---
        let scheduleNote: String? = {
            guard !isLiveRow else { return nil }
            return sureText.isEmpty ? nil : sureText
        }()

        // --- ÖHO heuristic ---
        let isOzel = (hat_ad?.localizedCaseInsensitiveContains("ÖHO") ?? false)
                  || (hat_ad?.localizedCaseInsensitiveContains("(ÖHO)") ?? false)

        return Bus(
            line: line,
            route: route,
            etaSeconds: etaSeconds,
            plate: plate,
            vehicleId: aracId,
            speedKmh: speedKmh,
            stopPosition: stopPosition,
            scheduleNote: scheduleNote,
            isOzel: isOzel,
            attributes: attrs,
            stopNo: stopNo,
            sourceIndex: sourceIndex,
            latitude: latVal,
            longitude: lngVal,
            headingDegrees: heading,
            occupancy: doluluk?.nonEmpty,
            lastUpdate: lastSeen,
            busStopSeq: busSeq,
            userStopSeq: userSeq,
            isPast: pastFlag,
            currentStopNo: durak_no?.nonEmpty
        )
    }

    /// Best-effort fallback for rows that only carry a `sure` text (e.g. "5 dk", "36 sn").
    /// The new endpoint always sends `saniye`, so this is rarely exercised.
    private static func parseSureToSeconds(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.contains("geçti") || lower.contains("t.v.") { return nil }
        let digits = text.prefix(while: { $0.isNumber || $0.isWhitespace }).filter(\.isNumber)
        guard let n = Int(digits) else { return nil }
        if lower.contains("sn") { return n }
        if lower.contains("sa") { return n * 3600 }   // "1 sa 1 dk" → at least the hours
        return n * 60
    }

    private static let lastUpdateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm:ss"
        f.locale = Locale(identifier: "tr_TR")
        f.timeZone = TimeZone(identifier: "Europe/Istanbul")
        return f
    }()

    private static func parseLastUpdate(_ s: String) -> Date? {
        lastUpdateFormatter.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private extension Optional where Wrapped == String {
    /// Returns the trimmed string if non-empty, otherwise nil.
    /// EGO uses both "" and missing keys for "no value".
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }
}

private extension String {
    /// Returns nil for empty strings — matches the optional-chaining ergonomics above.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - JSON helpers shared with disk caches

extension JSONEncoder {
    /// Encoder used for on-disk caches — stable, ISO-8601 dates so files
    /// survive across timezone changes.
    static var iso8601: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

enum EGOError: Error, LocalizedError {
    case invalidEncoding
    case emptyResponse
    case httpStatus(Int)
    case serverMessage(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:        return "Yanıt çözümlenemedi"
        case .emptyResponse:          return "Boş yanıt"
        case .httpStatus(let code):   return "Sunucu hatası (HTTP \(code))"
        case .serverMessage(let m):   return m
        case .decoding(let m):        return "JSON çözümlenemedi: \(m)"
        }
    }
}
