import SwiftUI
import AppKit

/// Tabbed detail screen for a single line. Tabs:
///
/// - **Otobüsler** — every live bus on this line, ETA against the user's
///   currently active stop. Reuses `EGOClient.fetchLineBuses`.
/// - **Duraklar** — the route's ordered stop list, reconstructed from
///   `RouteIndex` over time. Each row shows seq + stop name + (when we have
///   it) a `Tahmini HH:MM` predicted pass time.
/// - **Saatler** — the schedule scraped from `/HareketSaatleri`, three
///   columns (Hafta içi / Cumartesi / Pazar). Today's column highlighted.
/// - **Harita** — opens the `LineMapView` in a separate `NSPanel` window.
///
/// All four tabs are lazy: data is fetched on first appear (`task(id:)`).
struct LineDetailView: View {
    @ObservedObject var viewModel: BusViewModel
    let line: Line
    var onBack: () -> Void

    @State private var tab: Tab = .buses

    enum Tab: String, CaseIterable, Identifiable {
        case buses    = "Otobüsler"
        case stops    = "Duraklar"
        case schedule = "Saatler"
        case map      = "Harita"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider().opacity(0.4)

            Group {
                switch tab {
                case .buses:    BusesTab(viewModel: viewModel, line: line)
                case .stops:    StopsTab(viewModel: viewModel, line: line)
                case .schedule: ScheduleTab(viewModel: viewModel, line: line)
                case .map:      MapTab(viewModel: viewModel, line: line)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Header / tab bar

    private var header: some View {
        HStack(spacing: 8) {
            HeaderBack(label: "Geri", action: onBack)
            VStack(spacing: 0) {
                Text(line.code)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                Text(line.displayName)
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.4)
                    .opacity(0.85)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: 60, height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(EGOTheme.red)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { t in
                Button(action: { withAnimation(.easeOut(duration: 0.15)) { tab = t } }) {
                    VStack(spacing: 2) {
                        Text(t.rawValue)
                            .font(.system(size: 10.5, weight: tab == t ? .semibold : .regular))
                            .foregroundStyle(tab == t ? Color.primary : .secondary)
                        Rectangle()
                            .fill(tab == t ? EGOTheme.red : Color.clear)
                            .frame(height: 1.5)
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Buses tab

private struct BusesTab: View {
    @ObservedObject var viewModel: BusViewModel
    let line: Line

    @State private var buses: [Bus] = []
    @State private var loading = true
    @State private var error: String?

    private var anchorStop: StopProfile? { viewModel.activeStop }

    var body: some View {
        Group {
            if let stop = anchorStop {
                if loading && buses.isEmpty {
                    EmptyHint(text: "\(stop.displayName) için yükleniyor…")
                } else if let err = error, buses.isEmpty {
                    EmptyHint(text: "Hata: \(err)")
                } else if buses.isEmpty {
                    EmptyHint(text: "\(stop.displayName) durağına yaklaşan canlı \(line.code) otobüs yok.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(buses) { LineDetailBusRow(bus: $0, anchorStopName: stop.displayName) }
                        }
                    }
                }
            } else {
                EmptyHint(text: "Önce ayarlardan bir durak ekleyin.")
            }
        }
        .task(id: line.code) { await reload() }
    }

    private func reload() async {
        guard let stop = anchorStop else { return }
        loading = true
        defer { loading = false }
        do {
            let client = EGOClient()
            buses = try await client.fetchLineBuses(line: line.code, atStop: stop.stopNo)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct LineDetailBusRow: View {
    let bus: Bus
    let anchorStopName: String

    var body: some View {
        HStack(spacing: 8) {
            // Status dot — live red, past gray.
            Image(systemName: bus.isPast ? "checkmark.circle.fill" : "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(bus.isPast ? Color.secondary.opacity(0.5) : EGOTheme.red.opacity(0.85))

            VStack(alignment: .leading, spacing: 2) {
                Text(bus.plate ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                if let pos = bus.stopPosition {
                    Text("sıra \(pos)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text(etaText)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(bus.isPast ? Color.secondary : .primary)
                if let occ = bus.occupancy {
                    Text(occ)
                        .font(.system(size: 9))
                        .foregroundStyle(EGOTheme.red.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.02))
    }

    private var etaText: String {
        if bus.isPast { return "Geçti" }
        guard let s = bus.etaSeconds else { return "—" }
        if s < 60 { return "\(s) sn" }
        if s < 3600 { return "\(s / 60) dk" }
        let h = s / 3600, m = (s % 3600) / 60
        return m > 0 ? "\(h) sa \(m) dk" : "\(h) sa"
    }
}

// MARK: - Stops tab

private struct StopsTab: View {
    @ObservedObject var viewModel: BusViewModel
    let line: Line

    @State private var liveBuses: [Bus] = []
    @State private var observedSegmentSec: Double?
    @State private var loading = true

    private var anchorStopNo: String? { viewModel.activeStop?.stopNo }

    /// The stop list now comes straight from `HareketSaatleri` — it ships the
    /// full ordered route with real names. RouteIndex is only used as a
    /// fallback when the schedule is still loading or the page omits the
    /// stop table (rare).
    private var stops: [LineStop] {
        if let s = viewModel.schedules[line.code], !s.routeStops.isEmpty {
            return s.routeStops
        }
        return fallbackStops
    }
    @State private var fallbackStops: [LineStop] = []

    private var predictor: PassTimePredictor {
        PassTimePredictor(
            lineCode: line.code,
            schedule: viewModel.schedules[line.code],
            stops: stops,
            liveBuses: liveBuses,
            observedSecondsPerSegment: observedSegmentSec
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if loading && stops.isEmpty {
                EmptyHint(text: "Durak listesi yükleniyor…")
            } else if stops.isEmpty {
                EmptyHint(text: "Bu hat için durak listesi alınamadı.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(stops) { stop in
                            LineStopRow(
                                stop: stop,
                                predictedPassTime: predictor.predictedPassTime(forStopSequence: stop.sequence),
                                isUserStop: stop.stopNo == anchorStopNo
                            )
                        }
                    }
                }
            }
        }
        .task(id: line.code) { await reload() }
    }

    @MainActor
    private func reload() async {
        loading = true
        defer { loading = false }
        // Authoritative stop list comes from the schedule page — fetch it
        // first so the UI flips to real names ASAP.
        await viewModel.loadSchedule(line: line.code)
        // Live bus snapshot for the predictor's anchor logic.
        if let stop = viewModel.activeStop {
            if let buses = try? await EGOClient().fetchLineBuses(line: line.code, atStop: stop.stopNo) {
                liveBuses = buses
            }
        }
        // Fallback to RouteIndex only if the schedule didn't include a route table.
        if (viewModel.schedules[line.code]?.routeStops.isEmpty ?? true) {
            fallbackStops = await RouteIndex.shared.orderedStops(forLine: line.code)
        }
        observedSegmentSec = await RouteIndex.shared.averageSecondsPerSegment(forLine: line.code)
    }
}

private struct LineStopRow: View {
    let stop: LineStop
    let predictedPassTime: Date?
    let isUserStop: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(stop.sequence)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isUserStop ? EGOTheme.red : .secondary)
                .frame(width: 26, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(stop.name)
                    .font(.system(size: 11, weight: isUserStop ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(stop.stopNo == "?" ? .tertiary : .primary)
                if stop.stopNo != "?" {
                    Text("durak \(stop.stopNo)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Predicted pass time. The "Tahmini" tag keeps users honest —
            // these are heuristic estimates, not authoritative arrival times.
            if let predicted = predictedPassTime {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(predicted.hhmm)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isUserStop ? EGOTheme.red : .primary)
                    Text("Tahmini")
                        .font(.system(size: 7, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            isUserStop
                ? EGOTheme.red.opacity(0.08)
                : (stop.sequence.isMultiple(of: 2) ? Color.primary.opacity(0.02) : Color.clear)
        )
    }
}

// MARK: - Schedule tab

private struct ScheduleTab: View {
    @ObservedObject var viewModel: BusViewModel
    let line: Line

    @State private var loading = false

    private var schedule: LineSchedule? { viewModel.schedules[line.code] }
    private var error: String? { viewModel.scheduleErrors[line.code] }

    var body: some View {
        Group {
            if loading && schedule == nil {
                EmptyHint(text: "Hareket saatleri yükleniyor…")
            } else if let err = error, schedule == nil {
                EmptyHint(text: "Hata: \(err)")
            } else if let s = schedule {
                ScheduleContent(schedule: s)
            } else {
                EmptyHint(text: "Hareket saatleri yok.")
            }
        }
        .task(id: line.code) {
            loading = true
            await viewModel.loadSchedule(line: line.code)
            loading = false
        }
    }
}

private struct ScheduleContent: View {
    let schedule: LineSchedule
    private var today: LineSchedule.Day { .current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                metaBlock
                Divider().opacity(0.3)
                threeColumns
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var metaBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let o = schedule.originName {
                kv("Kalkış", o)
            }
            if let d = schedule.destinationName {
                kv("Varış", d)
            }
            HStack(spacing: 16) {
                if let km = schedule.distanceKm {
                    kv("Mesafe", "\(km) km")
                }
                if let m = schedule.durationMinutes {
                    kv("Süre", "\(m) dk")
                }
            }
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k + ":")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(v)
                .font(.system(size: 10))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }

    private var threeColumns: some View {
        HStack(alignment: .top, spacing: 8) {
            column(.weekday)
            column(.saturday)
            column(.sunday)
        }
    }

    private func column(_ day: LineSchedule.Day) -> some View {
        let entries = schedule.departures(for: day)
        let isToday = day == today
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(day.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isToday ? EGOTheme.red : .primary)
                if isToday {
                    Text("BUGÜN")
                        .font(.system(size: 7, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(EGOTheme.red)
                }
            }
            .padding(.bottom, 2)
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.time)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary)
                    if let n = entry.note, !n.isEmpty {
                        Text(n)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Map tab (opens external panel)

private struct MapTab: View {
    @ObservedObject var viewModel: BusViewModel
    let line: Line

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "map.fill")
                .font(.system(size: 36))
                .foregroundStyle(EGOTheme.red.opacity(0.7))
            Text("Hat haritası")
                .font(.system(size: 13, weight: .semibold))
            Text("Harita ayrı bir pencerede açılır.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Button(action: open) {
                Text("Haritayı Aç")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(EGOTheme.red)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func open() {
        MapWindowController.shared.open(line: line, anchorStop: viewModel.activeStop)
    }
}
