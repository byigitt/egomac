import SwiftUI
import AppKit

/// Read-only view for a stop discovered through the search screen. We don't
/// add it to the user's saved stops here — that's still done in Settings —
/// but we do let them peek at the live boards.
///
/// Internally this is just a thin wrapper around the existing `BusRow`s,
/// driven by an ad-hoc `EGOClient.fetchBuses(stopNo:)` call.
struct StopDetailView: View {
    @ObservedObject var viewModel: BusViewModel
    let stop: StopSearchResult
    var onOpenLine: (Line) -> Void
    var onBack: () -> Void

    @State private var buses: [Bus] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            if loading && buses.isEmpty {
                EmptyHint(text: "Yükleniyor…")
            } else if let err = error, buses.isEmpty {
                EmptyHint(text: "Hata: \(err)")
            } else if buses.isEmpty {
                EmptyHint(text: "Bu durakta şu an aktif sefer yok.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(buses) { bus in
                            // Tap a row to jump straight into LineDetailView.
                            Button(action: { jumpToLine(bus) }) {
                                StopDetailBusRow(bus: bus)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider().opacity(0.3)
            HStack(spacing: 8) {
                Button(action: addToSavedStops) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle")
                        Text("Bu durağı kaydet")
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(EGOTheme.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: { Task { await reload() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .help("Yenile")
            }
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(0.03))
        }
        .task(id: stop.stopNo) { await reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            HeaderBack(label: "Geri", action: onBack)
            VStack(spacing: 0) {
                Text(stop.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("DURAK \(stop.stopNo)")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.6)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: 60, height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(EGOTheme.red)
    }

    // MARK: - Actions

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            buses = try await EGOClient().fetchBuses(stopNo: stop.stopNo)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func jumpToLine(_ bus: Bus) {
        let route = bus.route.isEmpty ? bus.line : bus.route
        let line = viewModel.allLines.first(where: { $0.code == bus.line })
            ?? Line(code: bus.line, displayName: route, isOzel: bus.isOzel)
        onOpenLine(line)
    }

    private func addToSavedStops() {
        var c = viewModel.config
        // Skip if already saved.
        if c.stops.contains(where: { $0.stopNo == stop.stopNo }) { return }
        c.stops.append(StopProfile(name: stop.name, stopNo: stop.stopNo, watchedLines: []))
        viewModel.updateConfig(c)
    }
}

// MARK: - Row

private struct StopDetailBusRow: View {
    let bus: Bus

    var body: some View {
        HStack(spacing: 10) {
            Text(bus.line)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(EGOTheme.red)

            VStack(alignment: .leading, spacing: 2) {
                Text(bus.route.isEmpty ? "—" : bus.route)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let plate = bus.plate {
                    Text(plate)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)

            etaCell

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.02))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var etaCell: some View {
        if bus.isPast {
            Text("Geçti")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        } else if let s = bus.etaSeconds {
            HStack(spacing: 2) {
                Text(s < 60 ? "\(s)" : "\(s / 60)")
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                Text(s < 60 ? "sn" : "dk")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        } else if let note = bus.scheduleNote {
            Text(note.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .frame(maxWidth: 100, alignment: .trailing)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}
