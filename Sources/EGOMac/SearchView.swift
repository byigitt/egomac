import SwiftUI
import AppKit

/// Cross-search across both stops (embedded blob) and lines (HatListesi).
/// Single text field; results are split into two sections so the user can
/// jump straight into either a `LineDetailView` or a `StopDetailView`.
///
/// - Numeric / dashed queries (e.g. "481", "263-7", "10940") match line codes
///   first, then stop refs.
/// - Text queries match stop names and route descriptions.
struct SearchView: View {
    @ObservedObject var viewModel: BusViewModel
    var onBack: () -> Void
    var onOpenLine: (Line) -> Void
    var onOpenStop: (StopSearchResult) -> Void

    @State private var query: String = ""
    @State private var stopHits: [StopSearchResult] = []
    @State private var lineHits: [LineSearchResult] = []
    @State private var queryDebounce: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 8) {
                searchField

                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    EmptyHint(text: "Hat numarası, hat adı veya durak ismi yazın")
                } else if stopHits.isEmpty && lineHits.isEmpty {
                    EmptyHint(text: "Sonuç yok")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if !lineHits.isEmpty {
                                Section(header: SectionLabel(symbol: "tram", text: "Hatlar")) {
                                    ForEach(lineHits) { hit in
                                        LineHitRow(hit: hit) { openLine(hit) }
                                    }
                                }
                            }
                            if !stopHits.isEmpty {
                                Section(header: SectionLabel(symbol: "mappin.circle", text: "Duraklar")) {
                                    ForEach(stopHits) { hit in
                                        StopHitRow(hit: hit) { onOpenStop(hit) }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                }
            }
            .padding(.top, 10)
        }
        .task {
            // Pre-warm the line catalog so the first query is fast.
            await viewModel.loadAllLines()
            await SearchIndex.shared.ensureLinesLoaded()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            HeaderBack(label: "Geri", action: onBack)
            VStack(spacing: 0) {
                Text("Ara")
                    .font(.system(size: 14, weight: .semibold))
                Text("HAT VEYA DURAK")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.6)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            // Keep the header symmetric with the back button.
            Color.clear.frame(width: 60, height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(EGOTheme.red)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Ör. 481, Kızılay, 10940", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onChange(of: query) { _, _ in scheduleSearch() }
            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 12)
    }

    // MARK: - Search dispatch

    /// Debounce 180 ms so each keystroke doesn't trigger a fresh sort/regex
    /// pass over 2 943 stops + 600+ lines.
    private func scheduleSearch() {
        queryDebounce?.cancel()
        queryDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            if Task.isCancelled { return }
            await runSearch()
        }
    }

    @MainActor
    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            stopHits = []; lineHits = []
            return
        }
        // Both indices are local (line list is fetched lazily by SearchIndex).
        stopHits = SearchIndex.shared.searchStops(q, limit: 8)
        lineHits = SearchIndex.shared.searchLines(q, limit: 8)
    }

    /// Resolve a `LineSearchResult` to the richer `Line` model and push.
    /// If the catalog hasn't loaded the matching code yet we synthesise a
    /// minimal `Line` so navigation still works (LineDetailView refreshes anyway).
    private func openLine(_ hit: LineSearchResult) {
        if let full = viewModel.allLines.first(where: { $0.code == hit.lineNo }) {
            onOpenLine(full)
        } else {
            onOpenLine(Line(code: hit.lineNo, displayName: hit.route, isOzel: hit.route.contains("ÖHO")))
        }
    }
}

// MARK: - Result rows

private struct LineHitRow: View {
    let hit: LineSearchResult
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(hit.lineNo)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(EGOTheme.red)
                    // Pill-style — mirrors the existing badge in BusRow.
                Text(hit.route)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovered ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct StopHitRow: View {
    let hit: StopSearchResult
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(EGOTheme.red.opacity(0.85))
                VStack(alignment: .leading, spacing: 1) {
                    Text(hit.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text("durak no: \(hit.stopNo)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovered ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Shared little widgets

struct SectionLabel: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HeaderBack: View {
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.18 : 0.10))
            )
            .frame(width: 60, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
