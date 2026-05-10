import SwiftUI
import MapKit

/// MapKit view shown in the standalone "Hat Haritası" panel window.
///
/// Phase 4b implementation: stops + polyline. Phase 4c will overlay live
/// buses with a 20 s polling timer. Phase 4d wires up bidirectional
/// stop ↔ side-list highlighting.
///
/// Stops + their coordinates are reconstructed from `RouteIndex`, which
/// itself is fed by every `EGOClient.fetchLineBuses(...)` call. So the more
/// the user uses the app, the more complete the map becomes.
struct LineMapView: View {
    let line: Line
    let anchorStop: StopProfile?

    @State private var stops: [LineStop] = []
    @State private var liveBuses: [Bus] = []
    @State private var camera: MapCameraPosition = .automatic
    @State private var loading = true
    @State private var pollTimer: Timer?

    /// `LineMapView` runs outside the popover, so we own a small ad-hoc
    /// EGOClient instance instead of going through `BusViewModel`.
    private let client = EGOClient()

    var body: some View {
        VStack(spacing: 0) {
            header

            // The actual map — content varies by available data.
            ZStack {
                Map(position: $camera) {
                    // Polyline connecting all known stops in sequence order.
                    let coords = stops.compactMap { stop -> CLLocationCoordinate2D? in
                        guard let lat = stop.latitude, let lng = stop.longitude else { return nil }
                        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
                    }
                    if coords.count >= 2 {
                        MapPolyline(coordinates: coords)
                            .stroke(EGOTheme.red.opacity(0.7), lineWidth: 3)
                    }

                    // Numbered stop markers — only those with coords. Unknown
                    // stops just don't get drawn (the side panel in Duraklar
                    // tab is the better place to surface gaps).
                    ForEach(stops) { stop in
                        if let lat = stop.latitude, let lng = stop.longitude {
                            Annotation(
                                stop.name,
                                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng)
                            ) {
                                NumberedStopMarker(
                                    sequence: stop.sequence,
                                    isUserStop: stop.stopNo == anchorStop?.stopNo
                                )
                            }
                        }
                    }

                    // Every live bus on this line, with rotation == heading.
                    ForEach(liveBuses) { bus in
                        if let lat = bus.latitude, let lng = bus.longitude {
                            Annotation(
                                bus.plate ?? "?",
                                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng)
                            ) {
                                BusMarker(headingDegrees: bus.headingDegrees ?? 0,
                                          isPast: bus.isPast)
                            }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .onAppear { fitInitialCamera() }

                if loading && stops.isEmpty && liveBuses.isEmpty {
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.regular)
                        Text("Hat verisi yükleniyor…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(.regularMaterial)
                }
            }
        }
        .task(id: line.code) { await initialLoad() }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Hat \(line.code)")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                Text(line.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(liveBuses.count) canlı")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Button(action: { Task { await refreshLive() } }) {
                Image(systemName: "arrow.clockwise")
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Loading

    private func initialLoad() async {
        loading = true
        defer { loading = false }
        // 1. Authoritative stop list from HareketSaatleri — names + sequence,
        //    no GPS yet.
        if let schedule = try? await client.fetchLineSchedule(line: line.code) {
            stops = await mergeWithRouteIndexCoords(schedule.routeStops)
        }
        // 2. Live bus snapshot — also feeds RouteIndex with GPS, which we then
        //    merge into stops.latitude/longitude on subsequent polls.
        await refreshLive()
        fitInitialCamera()
    }

    private func refreshLive() async {
        guard let stop = anchorStop else { return }
        if let buses = try? await client.fetchLineBuses(line: line.code, atStop: stop.stopNo) {
            liveBuses = buses.filter { $0.latitude != nil && $0.longitude != nil }
            // RouteIndex now has fresher GPS for some sequences — fold those
            // back into the schedule-sourced stop list.
            stops = await mergeWithRouteIndexCoords(stops)
        }
    }

    /// Take the schedule-sourced `[LineStop]` (which only has names) and fill
    /// in `latitude`/`longitude` for any sequence we've observed via
    /// `RouteIndex` (which carries the bus's GPS at sample time).
    private func mergeWithRouteIndexCoords(_ base: [LineStop]) async -> [LineStop] {
        let observed = await RouteIndex.shared.orderedStops(forLine: line.code)
        let bySeq = Dictionary(uniqueKeysWithValues: observed.map { ($0.sequence, $0) })
        return base.map { stop in
            guard stop.latitude == nil, let s = bySeq[stop.sequence],
                  let lat = s.latitude, let lng = s.longitude else { return stop }
            return LineStop(
                lineCode: stop.lineCode,
                sequence: stop.sequence,
                stopNo: stop.stopNo,
                name: stop.name,
                latitude: lat,
                longitude: lng
            )
        }
    }

    private func fitInitialCamera() {
        let coords: [CLLocationCoordinate2D] = (stops + liveBuses.map { _ in nil }).compactMap { stop in
            guard let stop, let lat = stop.latitude, let lng = stop.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        } + liveBuses.compactMap { bus in
            guard let lat = bus.latitude, let lng = bus.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        guard !coords.isEmpty else {
            // Default to Ankara centre — Kızılay-ish.
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 39.92, longitude: 32.85),
                span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
            ))
            return
        }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude:  (lats.min()! + lats.max()!) / 2,
                longitude: (lons.min()! + lons.max()!) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta:  max(0.02, (lats.max()! - lats.min()!) * 1.4),
                longitudeDelta: max(0.02, (lons.max()! - lons.min()!) * 1.4)
            )
        )
        camera = .region(region)
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in await refreshLive() }
        }
    }
    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

// MARK: - Markers

/// Numbered circle for a stop annotation. Index is the route sequence number.
/// Highlighted ring + larger size when the stop matches the user's anchor.
private struct NumberedStopMarker: View {
    let sequence: Int
    let isUserStop: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isUserStop ? EGOTheme.red : Color.white)
                .frame(width: isUserStop ? 22 : 18, height: isUserStop ? 22 : 18)
            Circle()
                .stroke(EGOTheme.red, lineWidth: isUserStop ? 0 : 1.5)
                .frame(width: 18, height: 18)
            Text("\(sequence)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(isUserStop ? .white : EGOTheme.red)
        }
        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
    }
}

/// Bus annotation — red SF Symbol rotated by heading. Past buses go gray.
private struct BusMarker: View {
    let headingDegrees: Int
    let isPast: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isPast ? Color.secondary : EGOTheme.red)
                .frame(width: 22, height: 22)
            Image(systemName: "bus.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(Double(headingDegrees)))
        }
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}
