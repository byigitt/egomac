import Foundation
import SwiftSoup

/// Thread-safe client for EGO's "Otobüs Nerede?" endpoint.
///
/// EGO sits behind an F5 BIG-IP that issues a `TS01df2781`-style session cookie
/// on the first GET. Subsequent POSTs MUST replay that cookie or the response
/// arrives with an empty `<div class="bus-list">`. We auto-reprime when that
/// happens (cookie rotated / expired).
actor EGOClient {
    private let session: URLSession
    private let baseURL = URL(string: "https://www.ego.gov.tr/otobusnerede")!
    private var cookiesPrimed = false

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpCookieAcceptPolicy = .always
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func fetchBuses(stopNo: String) async throws -> [Bus] {
        if !cookiesPrimed {
            try await primeCookies()
            cookiesPrimed = true
        }

        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
        req.setValue("https://www.ego.gov.tr", forHTTPHeaderField: "Origin")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = "durak_no=\(stopNo)".data(using: .utf8)

        let (data, _) = try await session.data(for: req)
        guard let html = String(data: data, encoding: .utf8) else {
            throw EGOError.invalidEncoding
        }

        let buses = try Self.parse(html: html, stopNo: stopNo)
        if buses.isEmpty {
            // Possible session expiry — drop primed flag so next call re-seeds.
            cookiesPrimed = false
        }
        return buses
    }

    /// Fetch every stop in parallel and return a result-per-stop dictionary.
    /// Errors per stop are isolated — one bad stop doesn't fail the whole batch.
    func fetchAll(stopNos: [String]) async -> [String: Result<[Bus], Error>] {
        await withTaskGroup(of: (String, Result<[Bus], Error>).self) { group in
            for stop in stopNos {
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

    private func primeCookies() async throws {
        var req = URLRequest(url: baseURL)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        _ = try await session.data(for: req)
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // MARK: - Parsing

    static func parse(html: String, stopNo: String = "") throws -> [Bus] {
        let doc = try SwiftSoup.parse(html)
        let cards = try doc.select("div.bus-card").array()
        var result: [Bus] = []

        for card in cards {
            guard let badgeEl = try card.select("[class*=route-badge]").first() else { continue }
            let line = try badgeEl.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let isOzel = (try badgeEl.className()).contains("ozel")

            let route = try card.select("[class*=route-title]").text()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let metaText = try card.select(".route-meta").text()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let etaText = try card.select(".eta-mins").text()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let queueText = try card.select(".eta-queue").text()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var plate: String? = nil
            var vehicleId: String? = nil
            var speed: Int? = nil
            var note: String? = nil
            var attributes: [String] = []

            if metaText.contains("Hız") {
                // Live: "06 DY 3531, [13-406], Hız:0 km, Körüklü, Engelli"
                let parts = metaText
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }

                for (i, part) in parts.enumerated() {
                    if i == 0 && !part.hasPrefix("[") && !part.hasPrefix("Hız") {
                        plate = part
                    } else if part.hasPrefix("[") && part.hasSuffix("]") {
                        vehicleId = String(part.dropFirst().dropLast())
                    } else if part.hasPrefix("Hız") {
                        let digits = part.filter { $0.isNumber }
                        speed = Int(digits)
                    } else {
                        attributes.append(part)
                    }
                }
            } else if !metaText.isEmpty {
                note = metaText
            }

            let bus = Bus(
                line: line,
                route: route,
                etaMin: parseEtaMin(etaText),
                plate: plate,
                vehicleId: vehicleId,
                speedKmh: speed,
                stopPosition: queueText.isEmpty ? nil : queueText,
                scheduleNote: note,
                isOzel: isOzel,
                attributes: attributes,
                stopNo: stopNo
            )
            result.append(bus)
        }
        return result
    }

    private static func parseEtaMin(_ text: String) -> Int? {
        // "36 dk" → 36
        guard !text.isEmpty else { return nil }
        let digits = text.prefix(while: { $0.isNumber || $0 == " " }).filter { $0.isNumber }
        return Int(digits)
    }
}

enum EGOError: Error, LocalizedError {
    case invalidEncoding
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "Yanıt çözümlenemedi"
        case .emptyResponse: return "Boş yanıt"
        }
    }
}
