import Foundation

/// Computes "tahmini geçiş saati" for each stop on a line.
///
/// EGO doesn't expose a stop-by-stop running time, but it does give us
/// `LineSchedule.durationMinutes` (line-end-to-line-end run time) and we know
/// the route's total stop count from `RouteIndex.coverage`. Combining the two
/// gives a flat per-stop heuristic of `duration / (N - 1)` minutes per leg.
///
/// We layer two refinements on top:
///
/// 1. **Observed segment times** — when the same bus is sampled at sequence A
///    at time t1 and sequence B at time t2, we record `(B-A, t2-t1)` and
///    average over recent samples per line. This drifts the per-stop estimate
///    toward reality on routes where some segments are longer than others
///    (typical for radial Ankara lines that hit Kızılay traffic mid-route).
///
/// 2. **Active live bus correction** — if there's a live bus already on the
///    line, the prediction for stops AHEAD of that bus is anchored on the
///    bus's `etaSeconds` against the user's stop, not on the schedule.
///
/// Persistence (Phase 5c): segment samples are kept in
/// `~/.ego-mac/segment-times.json` so we don't lose hard-won data between
/// app launches.
struct PassTimePredictor {
    let lineCode: String
    let schedule: LineSchedule?
    let stops: [LineStop]
    /// Live buses fetched in the same screen, used to anchor the prediction
    /// when a bus is already mid-route.
    let liveBuses: [Bus]
    /// Empirically-observed seconds per segment for this line, when available.
    /// Falls back to the schedule-derived per-stop heuristic when nil.
    var observedSecondsPerSegment: Double?

    /// Compute the predicted pass time at a single stop sequence.
    /// Returns `nil` when we lack enough data (no schedule + no live bus).
    func predictedPassTime(forStopSequence seq: Int, now: Date = Date()) -> Date? {
        guard !stops.isEmpty else { return nil }

        // 1. If a live bus is currently between origin and this stop, use its
        //    ETA-against-user-stop and offset by the per-segment heuristic.
        if let bus = closestLiveBus(approaching: seq),
           let etaSec = bus.etaSeconds,
           let userSeq = bus.userStopSeq {
            // The user's stop is at `userSeq`; the target stop is at `seq`.
            // If `seq <= userSeq`, the bus reaches the target BEFORE the user.
            // If `seq > userSeq`, the bus reaches it AFTER.
            let perSegmentSec = perSegmentSeconds()
            let segmentDelta = seq - (bus.busStopSeq ?? 1)
            // Negative segmentDelta means the bus already passed it — for
            // those, return nil (not "predicted", just "missed").
            guard segmentDelta >= 0 else { return nil }
            let offset = TimeInterval(segmentDelta) * perSegmentSec
            // The bus's ETA is the time until it reaches `userSeq`. Pass time
            // at `seq` from "now" is the bus's current-position-to-`seq` time.
            let secondsFromNow = TimeInterval(etaSec) - TimeInterval(userSeq - seq) * perSegmentSec
            // If the live anchor sits at the user's stop, use it directly;
            // otherwise extrapolate via per-segment heuristic.
            _ = offset
            return now.addingTimeInterval(max(0, secondsFromNow))
        }

        // 2. No live bus → fall back to "next scheduled departure + cumulative
        //    per-segment time".
        guard let depart = nextScheduledDeparture(after: now) else { return nil }
        let perSegmentSec = perSegmentSeconds()
        let offset = TimeInterval(seq - 1) * perSegmentSec
        return depart.addingTimeInterval(offset)
    }

    /// Returns the next departure time (today) at or after `now`. Crosses
    /// midnight by falling back to the first departure of the next day-type.
    func nextScheduledDeparture(after now: Date) -> Date? {
        guard let schedule else { return nil }
        let day = LineSchedule.Day.current
        let entries = schedule.departures(for: day)
        let cal = Calendar(identifier: .gregorian)
        let todayMidnight = cal.startOfDay(for: now)
        let nowMinutes = cal.dateComponents([.hour, .minute], from: now)
        let nowOffset = (nowMinutes.hour ?? 0) * 60 + (nowMinutes.minute ?? 0)

        for entry in entries {
            guard let off = parseHHMM(entry.time) else { continue }
            if off >= nowOffset {
                return todayMidnight.addingTimeInterval(TimeInterval(off * 60))
            }
        }
        // After last departure today → return tomorrow's first.
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: todayMidnight),
           let firstOff = entries.compactMap({ parseHHMM($0.time) }).min() {
            return tomorrow.addingTimeInterval(TimeInterval(firstOff * 60))
        }
        return nil
    }

    /// Per-stop seconds derivation — in priority order:
    ///   1. Empirically observed average (best)
    ///   2. Schedule duration / (stop count - 1)
    ///   3. 90 s flat fallback
    private func perSegmentSeconds() -> TimeInterval {
        if let observed = observedSecondsPerSegment, observed >= 30, observed <= 240 {
            return observed
        }
        guard let schedule, let dur = schedule.durationMinutes,
              stops.count > 1 else {
            return 90
        }
        // Clamp per-segment so a 170-minute / 5-stop pathological case doesn't
        // give us absurd 30+-minute segments.
        let raw = TimeInterval(dur * 60) / TimeInterval(stops.count - 1)
        return max(45, min(180, raw))
    }

    /// Of the live buses, pick the one CLOSEST to but not past the requested
    /// sequence. Returns nil when no live bus is approaching.
    private func closestLiveBus(approaching targetSeq: Int) -> Bus? {
        let approaching = liveBuses.filter {
            !$0.isPast && ($0.busStopSeq ?? .max) <= targetSeq
        }
        return approaching.max(by: { ($0.busStopSeq ?? 0) < ($1.busStopSeq ?? 0) })
    }

    private func parseHHMM(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}

/// Convenience date formatter for the "HH:mm" predictions shown in the UI.
extension Date {
    var hhmm: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "Europe/Istanbul")
        f.locale = Locale(identifier: "tr_TR")
        return f.string(from: self)
    }
}
