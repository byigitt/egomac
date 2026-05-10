import SwiftUI
import AppKit

/// Navigation stack for the popover. We deliberately use an array of cases
/// (instead of a router framework) so the back button just pops the last entry
/// and the transitions stay snappy. `list` is always at the bottom.
///
/// Cases:
///   - `.list`        — the main bus list (default)
///   - `.settings`    — user settings
///   - `.search`      — cross-search across stops & lines
///   - `.lineDetail`  — tabs: Otobüsler / Duraklar / Saatler / Harita
///   - `.stopDetail`  — list of buses + lines for a stop discovered via search
enum PopoverScreen: Equatable {
    case list
    case settings
    case search
    case lineDetail(Line)
    case stopDetail(StopSearchResult)
}

// MARK: - EGO Cep'te theme tokens

enum EGOTheme {
    /// Headline EGO red (matches the official Cep'te header bar).
    static let red = Color(red: 0.83, green: 0.18, blue: 0.18)

    /// Light wash backgrounds for bus rows.
    /// "Live & approaching" → soft mint. "Leaving / departed" → soft pink.
    static let liveBg     = Color(red: 0.93, green: 0.97, blue: 0.93)   // #EDF6ED
    static let leavingBg  = Color(red: 0.99, green: 0.93, blue: 0.93)   // #FCEDED
    static let scheduleBg = Color(red: 0.97, green: 0.97, blue: 0.97)   // neutral schedule rows

    static let liveBgDark    = Color(red: 0.13, green: 0.20, blue: 0.13)
    static let leavingBgDark = Color(red: 0.22, green: 0.13, blue: 0.13)
    static let scheduleBgDark = Color(red: 0.15, green: 0.15, blue: 0.15)

    static let separator = Color.primary.opacity(0.06)
}

struct PopoverView: View {
    @ObservedObject var viewModel: BusViewModel
    @State private var stack: [PopoverScreen] = [.list]

    /// Top of stack — what's currently rendered.
    private var current: PopoverScreen { stack.last ?? .list }

    var body: some View {
        ZStack {
            // Cep'te uses solid white surfaces, not glass. We use the system
            // window background color so dark mode flips automatically.
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            Group {
                switch current {
                case .list:
                    ListScreen(viewModel: viewModel,
                               onOpenSettings: { push(.settings) },
                               onOpenSearch:   { push(.search) })
                        .transition(slideTransition)
                case .settings:
                    SettingsView(viewModel: viewModel) { pop() }
                        .transition(slideTransition)
                case .search:
                    SearchView(viewModel: viewModel,
                               onBack: { pop() },
                               onOpenLine: { push(.lineDetail($0)) },
                               onOpenStop: { push(.stopDetail($0)) })
                        .transition(slideTransition)
                case .lineDetail(let line):
                    LineDetailView(viewModel: viewModel, line: line) { pop() }
                        .transition(slideTransition)
                case .stopDetail(let stop):
                    StopDetailView(viewModel: viewModel, stop: stop,
                                   onOpenLine: { push(.lineDetail($0)) },
                                   onBack: { pop() })
                        .transition(slideTransition)
                }
            }
            .id(currentIdentity)
        }
        .frame(width: 380, height: 540)
    }

    /// SwiftUI `.transition` needs a stable identity to fire when we swap
    /// associated-value cases of the same enum (e.g. lineDetail(A) → lineDetail(B)).
    private var currentIdentity: String {
        switch current {
        case .list:                  return "list"
        case .settings:              return "settings"
        case .search:                return "search"
        case .lineDetail(let l):     return "line:\(l.code)"
        case .stopDetail(let s):     return "stop:\(s.stopNo)"
        }
    }

    private var slideTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal:   .move(edge: .leading).combined(with: .opacity)
        )
    }

    private func push(_ screen: PopoverScreen) {
        withAnimation(.spring(duration: 0.3, bounce: 0.16)) {
            stack.append(screen)
        }
    }

    private func pop() {
        guard stack.count > 1 else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0.16)) {
            _ = stack.removeLast()
        }
    }
}

// MARK: - List screen

private struct ListScreen: View {
    @ObservedObject var viewModel: BusViewModel
    var onOpenSettings: () -> Void
    var onOpenSearch: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            EGOHeader(viewModel: viewModel,
                      onOpenSettings: onOpenSettings,
                      onOpenSearch:   onOpenSearch)
            QuickLookupBar(viewModel: viewModel)

            if !viewModel.hasAdhocLookup {
                EGOActiveStopBar(viewModel: viewModel)
                if viewModel.config.stops.count > 1 {
                    StopSwitcher(viewModel: viewModel, onOpenSettings: onOpenSettings)
                }
            } else {
                AdhocStopBar(viewModel: viewModel, onOpenSettings: onOpenSettings)
            }

            content
                .id(viewModel.hasAdhocLookup ? "adhoc-\(viewModel.resolvedAdhoc ?? "")" : (viewModel.activeStop?.id.uuidString ?? "none"))

            ListFooter(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private var content: some View {
        let buses = viewModel.displayedBuses
        let watchedSet: Set<String> = viewModel.hasAdhocLookup
            ? []
            : (viewModel.activeStop?.watchedSet ?? [])
        if buses.isEmpty {
            EmptyState(error: viewModel.displayedError, loading: viewModel.adhocLoading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(buses) { bus in
                        BusRow(
                            bus: bus,
                            allBusesAtStop: buses,
                            watched: watchedSet.contains(bus.line),
                            threshold: viewModel.config.alertThresholdMin
                        )
                    }
                }
            }
        }
    }
}

// MARK: - EGO Header (red banner)

private struct EGOHeader: View {
    @ObservedObject var viewModel: BusViewModel
    var onOpenSettings: () -> Void
    var onOpenSearch: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            HeaderIconButton(symbol: viewModel.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise") {
                Task { await viewModel.refresh() }
            }
            .help("Yenile")

            VStack(spacing: 0) {
                Text("Otobüs Nerede?")
                    .font(.system(size: 14, weight: .semibold))
                Text("ANKARA BÜYÜKŞEHİR BELEDİYESİ")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.6)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)

            HStack(spacing: 4) {
                Button(action: toggleNotifications) {
                    Image(systemName: viewModel.config.notificationsEnabled ? "bell" : "bell.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle().fill(Color.white.opacity(viewModel.config.notificationsEnabled ? 0.10 : 0.22))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(viewModel.config.notificationsEnabled ? "Bildirimleri kapat" : "Bildirimleri aç")

                if let onOpenSearch {
                    HeaderIconButton(symbol: "magnifyingglass", action: onOpenSearch)
                        .help("Hat veya durak ara")
                }
                HeaderIconButton(symbol: "gearshape", action: onOpenSettings)
                    .help("Ayarlar")
                HeaderIconButton(symbol: "power", action: { NSApp.terminate(nil) })
                    .help("Çıkış")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(EGOTheme.red)
    }

    private func toggleNotifications() {
        var c = viewModel.config
        c.notificationsEnabled.toggle()
        viewModel.updateConfig(c, restartFetch: false)
    }
}

private struct HeaderIconButton: View {
    let symbol: String
    let action: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(Color.white.opacity(isHovered ? 0.18 : 0.10))
                )
                .scaleEffect(isPressed ? 0.92 : 1.0)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .onLongPressGesture(minimumDuration: 0, perform: {}) { pressing in
            withAnimation(.easeOut(duration: 0.1)) { isPressed = pressing }
        }
    }
}

// MARK: - Active stop bar (sub-header showing current stop number prominently)

private struct EGOActiveStopBar: View {
    @ObservedObject var viewModel: BusViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(EGOTheme.red)
            Text(viewModel.activeStop?.stopNo ?? "—")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
            Text(viewModel.activeStop?.displayName ?? "Durak yok")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if let count = viewModel.activeStop?.watchedLines.count, count > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 8.5))
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Rectangle()
                .fill(EGOTheme.separator)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Stop switcher (pill tabs)

private struct StopSwitcher: View {
    @ObservedObject var viewModel: BusViewModel
    var onOpenSettings: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.config.stops) { stop in
                    StopPill(
                        stop: stop,
                        isActive: viewModel.activeStop?.id == stop.id,
                        unreadCount: unread(for: stop)
                    ) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            viewModel.setActiveStop(stop.id)
                        }
                    }
                }
                AddStopPill(action: onOpenSettings)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Rectangle()
                .fill(EGOTheme.separator)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func unread(for stop: StopProfile) -> Int {
        let watched = stop.watchedSet
        let buses = viewModel.busesByStop[stop.stopNo] ?? []
        return buses.filter {
            guard let eta = $0.etaMin else { return false }
            return watched.contains($0.line) && eta <= viewModel.config.alertThresholdMin
        }.count
    }
}

private struct StopPill: View {
    let stop: StopProfile
    let isActive: Bool
    let unreadCount: Int
    let action: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(stop.displayName)
                    .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? Color.white : Color.primary)
                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(isActive ? EGOTheme.red : Color.white)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(
                            Circle().fill(isActive ? Color.white : EGOTheme.red)
                        )
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive
                          ? AnyShapeStyle(EGOTheme.red)
                          : AnyShapeStyle(Color.primary.opacity(isHovered ? 0.07 : 0.04)))
            )
            .scaleEffect(isPressed ? 0.96 : 1.0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .onLongPressGesture(minimumDuration: 0, perform: {}) { pressing in
            withAnimation(.easeOut(duration: 0.1)) { isPressed = pressing }
        }
    }
}

private struct AddStopPill: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text("durak ekle")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.05 : 0.02))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(0.15),
                        style: StrokeStyle(lineWidth: 0.8, dash: [2.5, 2.5])
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Empty state

private struct EmptyState: View {
    let error: String?
    var loading: Bool = false

    var body: some View {
        VStack(spacing: 10) {
            if loading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: error == nil ? "tram" : "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            Text(loading ? "Sorgulanıyor…" : (error ?? "Otobüs verisi yok"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }
}

// MARK: - Quick lookup search bar

private struct QuickLookupBar: View {
    @ObservedObject var viewModel: BusViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("durak numarası ile sorgula … (örn. 11524)",
                      text: $viewModel.adhocStopNo)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($isFocused)
                .onChange(of: viewModel.adhocStopNo) { _, new in
                    // Restrict to 5 digits.
                    let digits = new.filter(\.isNumber).prefix(5)
                    if digits != new {
                        viewModel.adhocStopNo = String(digits)
                    }
                }
            if viewModel.adhocLoading {
                ProgressView().controlSize(.mini)
            }
            if !viewModel.adhocStopNo.isEmpty {
                Button {
                    viewModel.adhocStopNo = ""
                    isFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Temizle")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isFocused ? EGOTheme.red.opacity(0.5) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Adhoc stop bar (shown when quick-lookup is active)

private struct AdhocStopBar: View {
    @ObservedObject var viewModel: BusViewModel
    var onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(EGOTheme.red)
            Text(viewModel.resolvedAdhoc ?? "")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
            Text("geçici sorgu")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            Spacer()
            Button {
                if let stopNo = viewModel.resolvedAdhoc {
                    var newConfig = viewModel.config
                    let label = "Durak \(stopNo)"
                    let new = StopProfile(name: label, stopNo: stopNo, watchedLines: [])
                    newConfig.stops.append(new)
                    newConfig.activeStopId = new.id
                    viewModel.updateConfig(newConfig)
                    viewModel.adhocStopNo = ""
                    onOpenSettings()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 10))
                    Text("durak olarak kaydet")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(EGOTheme.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Rectangle()
                .fill(EGOTheme.separator)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Bus row (Cep'te-style)

private struct BusRow: View {
    let bus: Bus
    let allBusesAtStop: [Bus]
    let watched: Bool
    let threshold: Int

    @State private var isHovered = false
    @State private var isExpanded = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggleExpand) {
                HStack(alignment: .center, spacing: 10) {
                    badge
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bus.route)
                            .font(.system(size: 11.5, weight: watched ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        meta
                    }
                    Spacer(minLength: 4)
                    etaBlock
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
            }

            if isExpanded {
                ExpandedSchedule(bus: bus, allBusesAtStop: allBusesAtStop)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(rowBackground)
    }

    private func toggleExpand() {
        withAnimation(.spring(duration: 0.28, bounce: 0.16)) {
            isExpanded.toggle()
        }
    }

    /// Cep'te color logic:
    /// - Stationary buses past your stop ("leaving") → pink
    /// - Live & approaching → soft mint (especially watched lines)
    /// - Scheduled (no ETA) → neutral
    private var rowBackground: some View {
        let dark = colorScheme == .dark
        let base: Color
        if bus.etaMin == nil {
            base = dark ? EGOTheme.scheduleBgDark : EGOTheme.scheduleBg
        } else if isLeaving {
            base = dark ? EGOTheme.leavingBgDark : EGOTheme.leavingBg
        } else {
            base = dark ? EGOTheme.liveBgDark : EGOTheme.liveBg
        }
        return base.opacity(isHovered ? 0.7 : 1.0)
    }

    /// "Leaving" heuristic: speed reported AND bus is past the user's stop.
    /// queue format: "TOTAL/CURRENT". User stop is at TOTAL position; bus at CURRENT.
    /// If CURRENT >= TOTAL the bus is at or past the stop.
    private var isLeaving: Bool {
        guard let pos = bus.stopPosition else { return false }
        let parts = pos.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        return parts[1] >= parts[0]
    }

    private var badge: some View {
        // Cep'te-style: solid red square, white text. ÖHO buses have a darker tone.
        Text(bus.line)
            .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(minWidth: 54, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(EGOTheme.red)
            )
    }

    @ViewBuilder
    private var meta: some View {
        if let note = bus.scheduleNote {
            Text(note.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                if let plate = bus.plate, let vid = bus.vehicleId {
                    Text("\(plate), [\(vid)]")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if !bus.attributes.isEmpty || bus.speedKmh != nil {
                    HStack(spacing: 4) {
                        if let speed = bus.speedKmh {
                            Text("Hız: \(speed) km")
                                .font(.system(size: 9.5))
                        }
                        if !bus.attributes.isEmpty {
                            Text(bus.attributes.joined(separator: ", "))
                                .font(.system(size: 9.5))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var etaBlock: some View {
        if isLeaving {
            VStack(alignment: .trailing, spacing: -1) {
                Text("Gidiyor")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(EGOTheme.red)
                if let pos = bus.stopPosition {
                    Text(pos)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 54, alignment: .trailing)
        } else if let secs = bus.etaSeconds {
            // Sub-minute ETAs come back from EGO as "36 sn" — render them in seconds
            // so a bus 30 s away doesn't look like 30 minutes away. Anything ≥ 60 s
            // shows as whole minutes like before.
            let etaMinutes = bus.etaMin ?? 0
            let isCritical = etaMinutes <= threshold && watched
            let showSeconds = secs < 60
            let value = showSeconds ? secs : etaMinutes
            let unit = showSeconds ? "sn" : "dk"
            VStack(alignment: .trailing, spacing: -1) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(value)")
                        .font(.system(size: 18, weight: .bold).monospacedDigit())
                        .foregroundStyle(isCritical ? EGOTheme.red : Color.primary)
                        .contentTransition(.numericText())
                    Text(unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isCritical ? EGOTheme.red : Color.secondary)
                }
                if let pos = bus.stopPosition {
                    Text(pos)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 54, alignment: .trailing)
        } else {
            Text("—")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 54, alignment: .trailing)
        }
    }
}

// MARK: - Expanded schedule (under the tapped bus)

private struct ExpandedSchedule: View {
    let bus: Bus
    let allBusesAtStop: [Bus]

    /// Lazy fetch of every live bus on this line, against this stop.
    /// `LineBusesLoader` calls `EGOClient.fetchLineBuses(line:atStop:)` and
    /// caches the result for the lifetime of this expanded panel.
    @StateObject private var loader = LineBusesLoader()

    /// The summary response for the stop (`FNC=Otobusler`) returns one row per
    /// line: a live row OR a scheduled row. The scheduled rows show the next
    /// departure note for the line, surfaced here.
    private var upcomingDepartures: [String] {
        let line = bus.line
        return allBusesAtStop.compactMap { other in
            guard other.line == line, other.etaSeconds == nil, let note = other.scheduleNote else { return nil }
            return note
        }
    }

    /// Live buses fetched on-demand via the per-line endpoint.
    /// We exclude past-and-tapped duplicates so the tapped row isn't repeated.
    private var liveOnLine: [Bus] {
        loader.buses.filter { $0.id != bus.id && $0.etaSeconds != nil }
    }

    /// Same row pool but for buses that already passed the user's stop.
    private var pastOnLine: [Bus] {
        loader.buses.filter { $0.id != bus.id && $0.isPast }
    }

    /// Unit-aware ETA formatting used by both the main row and this list.
    fileprivate static func etaText(for b: Bus) -> String {
        if b.isPast { return "Geçti" }
        guard let secs = b.etaSeconds else { return "—" }
        if secs < 60 { return "\(secs) sn" }
        if secs < 3600 { return "\(secs / 60) dk" }
        let h = secs / 3600, m = (secs % 3600) / 60
        return m > 0 ? "\(h) sa \(m) dk" : "\(h) sa"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 6) {
                ScheduleSectionLabel(symbol: "info.circle", text: "Hat \(bus.line) detayları")
                detailGrid
            }

            // --- All live buses on this line, fetched from the per-line endpoint ---
            Divider().opacity(0.3)
            VStack(alignment: .leading, spacing: 6) {
                ScheduleSectionLabel(
                    symbol: "bus.fill",
                    text: "Hat \(bus.line) üzerindeki canlı otobüsler"
                )

                if loader.isLoading && loader.buses.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                        Text("Hattın diğer otobüsleri yükleniyor…")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                } else if let err = loader.error, loader.buses.isEmpty {
                    Text("Hat detayı alınamadı: \(err)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if liveOnLine.isEmpty && pastOnLine.isEmpty {
                    Text("Şu an hatta sadece taptığınız otobüs canlı.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(liveOnLine) { o in LineBusRow(bus: o) }
                    ForEach(pastOnLine) { o in LineBusRow(bus: o) }
                }
            }

            if !upcomingDepartures.isEmpty {
                Divider().opacity(0.3)
                VStack(alignment: .leading, spacing: 6) {
                    ScheduleSectionLabel(symbol: "calendar", text: "Bu duraktan yaklaşan kalkışlar")
                    ForEach(Array(upcomingDepartures.enumerated()), id: \.offset) { _, d in
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.tertiary)
                            Text(cleanScheduleNote(d))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.025))
        .task(id: "\(bus.line)|\(bus.stopNo)") {
            await loader.load(line: bus.line, atStop: bus.stopNo)
        }
    }

    private var detailGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let plate = bus.plate {
                ScheduleDetailRow(label: "Plaka", value: plate, mono: true)
            }
            if let vid = bus.vehicleId {
                ScheduleDetailRow(label: "Araç ID", value: vid, mono: true)
            }
            if let speed = bus.speedKmh {
                ScheduleDetailRow(label: "Hız", value: "\(speed) km/s", mono: false)
            }
            if let pos = bus.stopPosition {
                let parts = pos.split(separator: "/").compactMap { Int($0) }
                let detail = parts.count == 2
                    ? "\(parts[1]) / \(parts[0]) (durağına \(max(parts[0] - parts[1], 0)) durak kaldı)"
                    : pos
                ScheduleDetailRow(label: "Konum", value: detail, mono: false)
            }
            if !bus.attributes.isEmpty {
                ScheduleDetailRow(label: "Özellik", value: bus.attributes.joined(separator: ", "), mono: false)
            }
        }
    }

    private func cleanScheduleNote(_ note: String) -> String {
        note
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "Sonraki Hareket Saati İlk Duraktan ", with: "İlk duraktan ")
            .replacingOccurrences(of: "Bugün İçin Son Hareket Saati ", with: "Son sefer · ")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// One row in the "hat üzerindeki canlı otobüsler" list. Compact, single-line.
private struct LineBusRow: View {
    let bus: Bus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: bus.isPast ? "checkmark.circle.fill" : "circle.fill")
                .font(.system(size: 5.5))
                .foregroundStyle(bus.isPast ? Color.secondary.opacity(0.4) : EGOTheme.red.opacity(0.7))

            // ETA — monospaced so all rows align
            Text(ExpandedSchedule.etaText(for: bus))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(bus.isPast ? .tertiary : .primary)
                .frame(width: 56, alignment: .leading)

            // Plate
            Text(bus.plate ?? "—")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)

            // Stop position (e.g. "42/57" — bus at sequence 42, you're at 57)
            if let pos = bus.stopPosition {
                Text("· \(pos)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // Occupancy chip (text only, no rounded background — per AGENTS.md)
            if let occ = bus.occupancy, !occ.isEmpty {
                Text("· \(occ)")
                    .font(.system(size: 10))
                    .foregroundStyle(occupancyColor(occ))
            }

            Spacer()
        }
        .opacity(bus.isPast ? 0.65 : 1.0)
    }

    /// Subtle hue based on the raw occupancy label. Kept text-only on purpose.
    private func occupancyColor(_ raw: String) -> Color {
        switch raw.lowercased() {
        case let s where s.contains("dolu"):  return EGOTheme.red.opacity(0.85)
        case let s where s.contains("orta"):  return Color.orange.opacity(0.9)
        case let s where s.contains("boş"):   return Color.green.opacity(0.85)
        default: return Color.secondary.opacity(0.6)
        }
    }
}

/// Per-popover-open cache for `EGOClient.fetchLineBuses` results.
/// Lifetime is tied to one `ExpandedSchedule` instance — collapsing the row
/// destroys it, expanding again triggers a fresh fetch (which is what we want
/// since the menu bar is usually opened briefly and we want fresh ETAs).
@MainActor
private final class LineBusesLoader: ObservableObject {
    @Published var buses: [Bus] = []
    @Published var isLoading = false
    @Published var error: String?

    private let client = EGOClient()
    private var lastKey: String?

    func load(line: String, atStop stopNo: String) async {
        let key = "\(line)|\(stopNo)"
        if lastKey == key && !buses.isEmpty { return }   // already loaded for this combo
        lastKey = key
        isLoading = true
        error = nil
        do {
            let fetched = try await client.fetchLineBuses(line: line, atStop: stopNo)
            // The view may have moved on (different line tapped); only commit if still relevant.
            guard self.lastKey == key else { return }
            self.buses = fetched
            DebugLog.log("line fetch ok: hat=\(line) durak=\(stopNo) → \(fetched.count) satır")
        } catch {
            guard self.lastKey == key else { return }
            self.error = error.localizedDescription
            DebugLog.log("line fetch fail: hat=\(line) durak=\(stopNo) → \(error.localizedDescription)")
        }
        isLoading = false
    }
}

private struct ScheduleSectionLabel: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.4)
        }
        .foregroundStyle(.tertiary)
    }
}

private struct ScheduleDetailRow: View {
    let label: String
    let value: String
    let mono: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, design: mono ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
        }
    }
}

// MARK: - Footer

private struct ListFooter: View {
    @ObservedObject var viewModel: BusViewModel
    @State private var ticker = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(viewModel.activeError == nil ? Color.green : Color.red)
                .frame(width: 5, height: 5)
            if let last = viewModel.lastUpdate {
                Text("son sorgu: " + relativeTimeString(from: last))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("bekleniyor…")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let err = viewModel.activeError {
                Text(err)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                Text("EGO Mac")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Rectangle()
                .fill(EGOTheme.separator)
                .frame(height: 1),
            alignment: .top
        )
        .onReceive(timer) { ticker = $0 }
    }

    private func relativeTimeString(from date: Date) -> String {
        let elapsed = Int(ticker.timeIntervalSince(date))
        if elapsed < 5 { return "az önce" }
        if elapsed < 60 { return "\(elapsed) sn önce" }
        let mins = elapsed / 60
        return "\(mins) dk önce"
    }
}

// MARK: - Shared icon button (exposed for SettingsView too)

struct IconButton: View {
    let symbol: String
    var tint: Color = .primary
    let action: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(Color.primary.opacity(isHovered ? 0.10 : 0.0))
                )
                .scaleEffect(isPressed ? 0.92 : 1.0)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .onLongPressGesture(minimumDuration: 0, perform: {}) { pressing in
            withAnimation(.easeOut(duration: 0.1)) { isPressed = pressing }
        }
    }
}
