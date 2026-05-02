import Foundation

struct Bus: Identifiable, Hashable {
    let line: String              // "481" or "263-7"
    let route: String             // route description
    let etaMin: Int?              // nil → scheduled, not live-tracked
    let plate: String?            // "06 DY 3531"
    let vehicleId: String?        // "13-406" (parsed from "[13-406]")
    let speedKmh: Int?
    let stopPosition: String?     // "57/24" (totalStops/currentStop)
    let scheduleNote: String?     // "Sonraki Hareket Saati İlk Duraktan 11:20 / 9 dk Sonra"
    let isOzel: Bool              // ÖHO (private operator)
    let attributes: [String]      // ["Körüklü", "Engelli"]
    let stopNo: String            // which stop fed this row
    let sourceIndex: Int          // position in the source response; disambiguates identical schedule rows

    var id: String {
        if let plate { return "\(stopNo):\(line):plate:\(plate)" }
        if let vehicleId { return "\(stopNo):\(line):vehicle:\(vehicleId)" }
        return "\(stopNo):\(line):scheduled:\(sourceIndex):\(route):\(scheduleNote ?? "")"
    }

    var isLive: Bool { etaMin != nil }

    /// Stable key used to dedup notifications across refreshes.
    /// Includes stopNo so the same bus reaching two of your stops still alerts.
    ///
    /// Plate is preferred over vehicleId because EGO occasionally rotates the
    /// bracket value between an internal route-vehicle id (e.g. "37-096") and
    /// the same bus's plate (e.g. "06 HO 1137"). Plate stays stable.
    var dedupKey: String {
        let id = plate ?? vehicleId ?? "\(line)-\(route)"
        return "\(stopNo):\(line):\(id)"
    }
}

/// One configured stop — name, number, and watched lines just for this stop.
struct StopProfile: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    var name: String              // user label, e.g., "Ev", "İş", "Hastane"
    var stopNo: String            // 5-digit EGO durak numarası
    var watchedLines: [String]    // hat numaraları takip edilecek (bu durağa özel)

    init(id: UUID = UUID(), name: String, stopNo: String, watchedLines: [String]) {
        self.id = id
        self.name = name
        self.stopNo = stopNo
        self.watchedLines = watchedLines
    }

    var watchedSet: Set<String> { Set(watchedLines) }

    /// Best-effort display label — falls back to "Durak N" when name is empty.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Durak \(stopNo)" : trimmed
    }
}

/// User-facing settings. Persisted as JSON to ~/.ego-mac/config.json.
///
/// Migration:
///  v1: { "stopNo": "10940",         "watchedLines": ["481"],  ... }
///  v2: { "stopNos": ["10940","..."],"watchedLines": ["481"],  ... }
///  v3: { "stops": [{name, stopNo, watchedLines}], ...        }
/// Decoder accepts all three; encoder always writes v3.
struct EGOConfig: Codable, Equatable, Hashable {
    var stops: [StopProfile]
    var activeStopId: UUID?              // currently selected stop in popover
    var alertThresholdMin: Int           // global (applies to every stop)
    var quietHoursStart: Int
    var quietHoursEnd: Int
    var notificationsEnabled: Bool = true   // master switch — mute banners w/o losing the menu-bar countdown

    static let `default` = EGOConfig(
        stops: [
            StopProfile(name: "Ev", stopNo: "10940", watchedLines: ["481", "263-7"]),
        ],
        activeStopId: nil,                // resolved at runtime → first stop
        alertThresholdMin: 5,
        quietHoursStart: 23,
        quietHoursEnd: 6,
        notificationsEnabled: true
    )

    init(
        stops: [StopProfile],
        activeStopId: UUID? = nil,
        alertThresholdMin: Int,
        quietHoursStart: Int,
        quietHoursEnd: Int,
        notificationsEnabled: Bool = true
    ) {
        self.stops = stops
        self.activeStopId = activeStopId
        self.alertThresholdMin = alertThresholdMin
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.notificationsEnabled = notificationsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case stops, activeStopId
        case stopNo, stopNos, watchedLines           // legacy
        case alertThresholdMin, quietHoursStart, quietHoursEnd
        case notificationsEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if let modern = try? c.decode([StopProfile].self, forKey: .stops), !modern.isEmpty {
            self.stops = modern
        } else {
            // Build StopProfiles from legacy fields.
            let legacyLines = (try? c.decode([String].self, forKey: .watchedLines)) ?? []
            if let stopArr = try? c.decode([String].self, forKey: .stopNos), !stopArr.isEmpty {
                self.stops = stopArr.map {
                    StopProfile(name: "Durak \($0)", stopNo: $0, watchedLines: legacyLines)
                }
            } else if let single = try? c.decode(String.self, forKey: .stopNo) {
                self.stops = [StopProfile(name: "Durak \(single)", stopNo: single, watchedLines: legacyLines)]
            } else {
                self.stops = EGOConfig.default.stops
            }
        }

        self.activeStopId = try? c.decode(UUID.self, forKey: .activeStopId)
        self.alertThresholdMin = (try? c.decode(Int.self, forKey: .alertThresholdMin)) ?? EGOConfig.default.alertThresholdMin
        self.quietHoursStart  = (try? c.decode(Int.self, forKey: .quietHoursStart))  ?? EGOConfig.default.quietHoursStart
        self.quietHoursEnd    = (try? c.decode(Int.self, forKey: .quietHoursEnd))    ?? EGOConfig.default.quietHoursEnd
        self.notificationsEnabled = (try? c.decode(Bool.self, forKey: .notificationsEnabled)) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stops, forKey: .stops)
        try c.encodeIfPresent(activeStopId, forKey: .activeStopId)
        try c.encode(alertThresholdMin, forKey: .alertThresholdMin)
        try c.encode(quietHoursStart, forKey: .quietHoursStart)
        try c.encode(quietHoursEnd, forKey: .quietHoursEnd)
        try c.encode(notificationsEnabled, forKey: .notificationsEnabled)
    }

    // MARK: - Helpers

    /// Resolve the effective active stop, falling back to the first stop if
    /// `activeStopId` is missing/stale.
    var resolvedActiveStop: StopProfile? {
        if let id = activeStopId, let s = stops.first(where: { $0.id == id }) {
            return s
        }
        return stops.first
    }

    func isQuietHour(now: Date = Date()) -> Bool {
        let h = Calendar.current.component(.hour, from: now)
        if quietHoursStart == quietHoursEnd { return false }
        if quietHoursStart < quietHoursEnd {
            return h >= quietHoursStart && h < quietHoursEnd
        } else {
            // wraps midnight, e.g. 23..6
            return h >= quietHoursStart || h < quietHoursEnd
        }
    }

    /// Union of all watched lines across every stop — used for global title/notification logic.
    var allWatchedLines: Set<String> {
        Set(stops.flatMap(\.watchedLines))
    }
}
