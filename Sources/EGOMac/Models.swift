import Foundation

struct Bus: Identifiable, Hashable {
    let line: String              // "481" or "263-7"
    let route: String             // route description
    let etaSeconds: Int?          // raw seconds remaining (nil → not arriving / past / scheduled).
                                  // The new JSON API exposes this directly via `saniye`. The legacy HTML
                                  // path normalised "N dk" / "N sn" into seconds for the same field.
    let plate: String?            // "06 DY 3531"
    let vehicleId: String?        // "13-406" (legacy bracket value or new arac_no)
    let speedKmh: Int?
    let stopPosition: String?     // "57/24" (userStopSeq/busStopSeq) — stable legacy format
    let scheduleNote: String?     // "Sonraki Hareket Saati İlk Duraktan 11:20 / 9 dk Sonra"
    let isOzel: Bool              // ÖHO (private operator)
    let attributes: [String]      // ["Körüklü", "Engelli"]
    let stopNo: String            // which stop fed this row
    let sourceIndex: Int          // position in the source response; disambiguates identical schedule rows

    // --- Extra fields surfaced by the JSON API. All optional so legacy callers
    //     and HTML-derived rows keep compiling unchanged.
    let latitude: Double?         // 39.872116
    let longitude: Double?        // 32.81625
    let headingDegrees: Int?      // 0..360, EGO calls this `aci`
    let occupancy: String?        // "Dolu" / "Boş" / "Orta" — raw label from API
    let lastUpdate: Date?         // parsed from `konum_tarihi` ("09.05.2026 12:58:19")
    let busStopSeq: Int?          // bus's current position in the route (1..N)
    let userStopSeq: Int?         // user's selected stop position in the route (1..N)
    let isPast: Bool              // API said "Geçti" or saniye=999999 — bus already passed user's stop
    let currentStopNo: String?    // `durak_no` — the stop the bus is AT right now (vs `stopNo` = user's stop)

    init(
        line: String,
        route: String,
        etaSeconds: Int? = nil,
        plate: String? = nil,
        vehicleId: String? = nil,
        speedKmh: Int? = nil,
        stopPosition: String? = nil,
        scheduleNote: String? = nil,
        isOzel: Bool = false,
        attributes: [String] = [],
        stopNo: String = "",
        sourceIndex: Int = 0,
        latitude: Double? = nil,
        longitude: Double? = nil,
        headingDegrees: Int? = nil,
        occupancy: String? = nil,
        lastUpdate: Date? = nil,
        busStopSeq: Int? = nil,
        userStopSeq: Int? = nil,
        isPast: Bool = false,
        currentStopNo: String? = nil
    ) {
        self.line = line
        self.route = route
        self.etaSeconds = etaSeconds
        self.plate = plate
        self.vehicleId = vehicleId
        self.speedKmh = speedKmh
        self.stopPosition = stopPosition
        self.scheduleNote = scheduleNote
        self.isOzel = isOzel
        self.attributes = attributes
        self.stopNo = stopNo
        self.sourceIndex = sourceIndex
        self.latitude = latitude
        self.longitude = longitude
        self.headingDegrees = headingDegrees
        self.occupancy = occupancy
        self.lastUpdate = lastUpdate
        self.busStopSeq = busStopSeq
        self.userStopSeq = userStopSeq
        self.isPast = isPast
        self.currentStopNo = currentStopNo
    }

    var id: String {
        if let plate { return "\(stopNo):\(line):plate:\(plate)" }
        if let vehicleId { return "\(stopNo):\(line):vehicle:\(vehicleId)" }
        return "\(stopNo):\(line):scheduled:\(sourceIndex):\(route):\(scheduleNote ?? "")"
    }

    /// True when the API gave us a numeric ETA. Past buses ("Geçti") still have
    /// `plate`/`lat`/`lng` but no usable seconds, so they're not "live" for ranking.
    var isLive: Bool { etaSeconds != nil }

    /// True when the row carries any live tracking info (plate / GPS / heading)
    /// even if there's no ETA — used for the "Geçti" / "on top of stop" cases.
    var hasLiveData: Bool { plate != nil || latitude != nil }

    /// ETA in whole minutes — 0 when the bus is < 1 minute away.
    /// Use this for thresholds, sorting, and the menu-bar title; use
    /// `etaSeconds` directly when sub-minute precision matters in the UI.
    var etaMin: Int? {
        guard let s = etaSeconds else { return nil }
        return max(0, s / 60)
    }

    /// True when the bus is live and less than a minute away.
    var isImminent: Bool {
        guard let s = etaSeconds else { return false }
        return s < 60
    }

    /// How many stops away the bus is from the user (negative if past).
    var stopsAway: Int? {
        guard let user = userStopSeq, let bus = busStopSeq else { return nil }
        return user - bus
    }

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

// MARK: - Line / route metadata

/// One bus line as listed by `/AjaxData/HatListesi`. We carry the raw EGO
/// option text plus parsed `code` ("481", "263-7") and `displayName`.
struct Line: Codable, Hashable, Identifiable {
    let code: String              // "481", "263-7", "481-6"
    let displayName: String       // "UYANIŞ-ASFALT-15 TEMMUZ KIZILAY …"
    let isOzel: Bool              // ÖHO heuristic on displayName

    var id: String { code }

    /// Two display halves for typical route strings ("A-B-C-D→E") — we surface
    /// the first and last segments separated by `-` to render compact terminus
    /// labels in the UI.
    var terminus1: String? {
        let parts = displayName.split(separator: "-", omittingEmptySubsequences: true)
        return parts.first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }
    var terminus2: String? {
        let parts = displayName.split(separator: "-", omittingEmptySubsequences: true)
        return parts.last.map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}

/// One stop on a line's route, sequenced 1…N. Built up empirically from
/// repeated `FNC=Otobus&HAT=...` polls (see `RouteIndex`); the EGO API does
/// not expose a single endpoint that lists every stop on a line in order.
struct LineStop: Codable, Hashable, Identifiable {
    let lineCode: String
    let sequence: Int             // 1..N
    let stopNo: String
    let name: String              // resolved from `StopsBlob` / `SearchIndex`
    let latitude: Double?
    let longitude: Double?

    var id: String { "\(lineCode)#\(sequence)" }

    var coordinate: (lat: Double, lon: Double)? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return (lat, lon)
    }
}

/// Schedule scraped from `/HareketSaatleri`. Three columns of departure
/// times plus the line metadata table that sits above them.
struct LineSchedule: Codable, Hashable {
    let lineCode: String
    let lineName: String
    let originName: String?
    let destinationName: String?
    let distanceKm: Int?
    let durationMinutes: Int?
    let weekdayDepartures: [DepartureEntry]
    let saturdayDepartures: [DepartureEntry]
    let sundayDepartures: [DepartureEntry]
    /// Ordered list of every stop on this line, scraped from the same
    /// `HareketSaatleri` page in a separate `<table>` block. Each entry
    /// carries the EGO stop number + Turkish display name + street address.
    /// Empty when the page didn't include the route table (rare — most
    /// lines do).
    var routeStops: [LineStop] = []

    /// One line on the schedule. `time` is `HH:mm`. `note` is the trailing
    /// free-text annotation EGO sometimes puts next to a departure (e.g.
    /// "21071'DEN BAŞLAR", "KARAPINAR'DA BİTER").
    struct DepartureEntry: Codable, Hashable, Identifiable {
        let time: String
        let note: String?

        var id: String { note.map { "\(time)|\($0)" } ?? time }
    }

    /// All departures for a given Turkish weekday name ("Hafta içi", etc.) plus
    /// the convenience `today` selector.
    func departures(for day: Day) -> [DepartureEntry] {
        switch day {
        case .weekday:  return weekdayDepartures
        case .saturday: return saturdayDepartures
        case .sunday:   return sundayDepartures
        }
    }

    enum Day: String, CaseIterable { case weekday, saturday, sunday
        var label: String {
            switch self {
            case .weekday:  return "Hafta içi"
            case .saturday: return "Cumartesi"
            case .sunday:   return "Pazar"
            }
        }
        static var current: Day {
            switch Calendar.current.component(.weekday, from: Date()) {
            case 1: return .sunday        // Sunday = 1 in Calendar's weekday
            case 7: return .saturday      // Saturday = 7
            default: return .weekday
            }
        }
    }
}

/// One observed sighting of a bus at a particular sequence position on a
/// line. Aggregating thousands of these lets us recover the ordered stop
/// list (`durak_sira_no → durak_no`) without a dedicated endpoint.
struct RouteSamplePoint: Codable, Hashable {
    let lineCode: String
    let sequence: Int             // durak_sira_no
    let stopNo: String            // durak_no
    let observedAt: Date
    /// `secili_durak_sira_no` from the same row — the route's total stop
    /// count, so we know when we've hit the terminus.
    let routeStopCount: Int?
    /// Bus's GPS coordinate at the moment of observation. We use this as the
    /// stop's approximate location since the embedded `StopsBlob` doesn't
    /// carry per-stop lat/lng. Refines over time as we see more buses pass.
    let latitude: Double?
    let longitude: Double?
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
