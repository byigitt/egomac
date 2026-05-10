import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var viewModel: BusViewModel
    var onClose: () -> Void

    /// Local working copy — written back on every change via .onChange.
    @State private var draft: EGOConfig
    @State private var expandedStopId: UUID?

    init(viewModel: BusViewModel, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onClose = onClose
        let cfg = viewModel.config
        self._draft = State(initialValue: cfg)
        self._expandedStopId = State(initialValue: cfg.resolvedActiveStop?.id)
    }

    private var installLocationWarning: Bool {
        Bundle.main.bundlePath.contains("/Desktop/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    stopsSection
                    notificationSection
                    thresholdSection
                    quietHoursSection
                    catalogSection
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
        }
        .frame(width: 380, height: 540)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: draft) { _, new in
            viewModel.updateConfig(new)
        }
    }

    // MARK: Header (red EGO bar)

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .help("Geri")

            Text("Ayarlar")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)

            Color.clear.frame(width: 26, height: 26)   // symmetry placeholder
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(EGOTheme.red)
    }

    // MARK: Stops

    private var stopsSection: some View {
        Section(label: "DURAKLAR") {
            VStack(spacing: 8) {
                ForEach(draft.stops) { stop in
                    StopCard(
                        stop: bindingForStop(id: stop.id),
                        expanded: Binding(
                            get: { expandedStopId == stop.id },
                            set: { isExpanded in
                                withAnimation(.spring(duration: 0.28, bounce: 0.16)) {
                                    expandedStopId = isExpanded ? stop.id : nil
                                }
                            }
                        ),
                        canDelete: draft.stops.count > 1,
                        onDelete: {
                            // Defer the mutation to the next runloop tick so any
                            // bindings into this row finish reading first.
                            // (Direct mutation here crashes via Binding<A>.subscript
                            //  → Array._checkSubscript when the row vanishes.)
                            let idToDelete = stop.id
                            DispatchQueue.main.async {
                                withAnimation(.spring(duration: 0.28, bounce: 0.12)) {
                                    draft.stops.removeAll { $0.id == idToDelete }
                                    if draft.activeStopId == idToDelete {
                                        draft.activeStopId = draft.stops.first?.id
                                    }
                                    if expandedStopId == idToDelete {
                                        expandedStopId = nil
                                    }
                                }
                            }
                        }
                    )
                }
                AddStopButton {
                    let new = StopProfile(
                        name: "Durak \(draft.stops.count + 1)",
                        stopNo: "",
                        watchedLines: []
                    )
                    withAnimation(.spring(duration: 0.32, bounce: 0.18)) {
                        draft.stops.append(new)
                        expandedStopId = new.id
                    }
                }
            }
        }
    }

    /// Crash-safe binding into a stop by id. Returns a no-op fallback if the
    /// stop has been deleted (mid-animation reads).
    private func bindingForStop(id: UUID) -> Binding<StopProfile> {
        Binding(
            get: {
                draft.stops.first(where: { $0.id == id })
                    ?? StopProfile(id: id, name: "", stopNo: "", watchedLines: [])
            },
            set: { newValue in
                if let idx = draft.stops.firstIndex(where: { $0.id == id }) {
                    draft.stops[idx] = newValue
                }
            }
        )
    }

    // MARK: Threshold

    private var notificationSection: some View {
        Section(label: "BİLDİRİM") {
            VStack(alignment: .leading, spacing: 10) {
                if installLocationWarning {
                    InstallLocationWarning()
                }
                if !Notifier.isAuthorized {
                    NotifPermissionDeniedBanner()
                }

                // Master toggle — mute the banners without losing the menu-bar countdown.
                HStack(spacing: 10) {
                    Image(systemName: draft.notificationsEnabled ? "bell.fill" : "bell.slash.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(draft.notificationsEnabled ? EGOTheme.red : .secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(draft.notificationsEnabled ? "Bildirimler açık" : "Bildirimler kapalı")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(draft.notificationsEnabled
                             ? "Eşiğin altına düşen otobüs için banner gelir."
                             : "Sadece menü çubuğundaki sayı güncellenir, banner gelmez.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $draft.notificationsEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(EGOTheme.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

                HStack(spacing: 8) {
                    Button {
                        Notifier.sendTest()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bell.badge")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Test bildirim gönder")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        Notifier.openNotificationSettings()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Sistem Ayarları")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Sistem Ayarları → Bildirimler")
                }
            }
        }
        .onAppear {
            // Refresh auth status when settings opens, so the banner reflects
            // any change the user made in System Settings.
            Notifier.refreshAuthStatus()
        }
    }

    private var thresholdSection: some View {
        Section(label: "BİLDİRİM EŞİĞİ") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "bell")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(draft.alertThresholdMin) dakika kala")
                        .font(.system(size: 12, weight: .medium))
                        .contentTransition(.numericText())
                    Spacer()
                    HStack(spacing: 4) {
                        StepButton(symbol: "minus") {
                            if draft.alertThresholdMin > 1 { draft.alertThresholdMin -= 1 }
                        }
                        StepButton(symbol: "plus") {
                            if draft.alertThresholdMin < 30 { draft.alertThresholdMin += 1 }
                        }
                    }
                }
                Slider(
                    value: Binding(
                        get: { Double(draft.alertThresholdMin) },
                        set: { draft.alertThresholdMin = Int($0.rounded()) }
                    ),
                    in: 1...30,
                    step: 1
                )
                .tint(.accentColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(softCardBackground)
        }
    }

    // MARK: Stop catalog (full EGO sweep)

    /// Surface the on-disk EGO stop catalog state — size, age, refresh button.
    /// `BusViewModel.refreshStopCatalog()` runs on background; the button
    /// either kicks one off or shows the in-flight progress.
    private var catalogSection: some View {
        Section(label: "DURAK LİSTESİ") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(catalogStatusLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if let p = viewModel.catalogProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: p)
                            .progressViewStyle(.linear)
                            .tint(EGOTheme.red)
                        Text("%\(Int(p * 100)) indirildi — EGO sunucusu yanıt verdikçe ilerleyecek.")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Button(action: { Task { await viewModel.refreshStopCatalog() } }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Listeyi yenile")
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(EGOTheme.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(EGOTheme.red.opacity(0.10))
                        )
                    }
                    .buttonStyle(.plain)
                }
                if let err = viewModel.catalogError {
                    Text("Hata: \(err)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(EGOTheme.red.opacity(0.8))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(softCardBackground)
        }
    }

    private var catalogStatusLine: String {
        if let s = viewModel.catalogSummary {
            let ageStr: String
            if let d = s.ageDays {
                ageStr = d == 0 ? "bugün" : "\(d) gün önce"
            } else {
                ageStr = "bilinmiyor"
            }
            return "EGO kataloğu: \(s.count) durak, \(ageStr) güncellendi."
        }
        return "Henüz tam EGO durak listesi indirilmedi (sadece gömülü 2 943 durak)."
    }

    // MARK: Quiet hours

    private var quietHoursSection: some View {
        Section(label: "SESSİZ SAATLER") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "moon")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Bu aralıkta polling durur, bildirim gelmez.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    HourPicker(label: "Başlangıç", value: $draft.quietHoursStart)
                    Text("─")
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(.tertiary)
                    HourPicker(label: "Bitiş", value: $draft.quietHoursEnd)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(softCardBackground)
        }
    }
}

// MARK: - Stop card

private struct StopCard: View {
    @Binding var stop: StopProfile
    @Binding var expanded: Bool
    let canDelete: Bool
    let onDelete: () -> Void

    @State private var stopQuery: String = ""
    @FocusState private var stopQueryFocused: Bool
    @State private var lineQuery: String = ""
    @FocusState private var lineQueryFocused: Bool
    @StateObject private var index = SearchIndex.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed row — always visible
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 10) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stop.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        HStack(spacing: 4) {
                            Image(systemName: "mappin")
                                .font(.system(size: 8))
                            Text(stop.stopNo.isEmpty ? "durak yok" : stop.stopNo)
                                .font(.system(size: 9.5, design: .monospaced))
                            if !stop.watchedLines.isEmpty {
                                Text("·").foregroundStyle(.tertiary)
                                Text("\(stop.watchedLines.count) hat")
                                    .font(.system(size: 9.5))
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if expanded {
                Divider().opacity(0.4)
                expandedFields
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(softCardBackground)
    }

    @ViewBuilder
    private var expandedFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Name (free text)
            LabeledField(label: "AD") {
                TextField("Ev, İş, …", text: $stop.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
            }

            // Stop search (replaces raw "Durak No" textfield)
            stopSearchField

            // Watched lines
            linesSearchField

            // Footer actions
            HStack {
                Spacer()
                if canDelete {
                    Button(role: .destructive, action: onDelete) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Durağı sil")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.red.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    // MARK: Stop search field

    private var stopSearchField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DURAK")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(stop.stopNo.isEmpty ? "durak adı veya numarası (örn. Kızılay, 12207)" : "değiştirmek için ara…",
                          text: $stopQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .focused($stopQueryFocused)
                if !stop.stopNo.isEmpty && stopQuery.isEmpty {
                    Text(stop.stopNo)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if !stopQuery.isEmpty {
                    Button {
                        stopQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        stopQueryFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            )

            if !stopQuery.isEmpty {
                let results = index.searchStops(stopQuery, limit: 6)
                if results.isEmpty {
                    SearchEmptyResult(
                        message: "sonuç yok — manuel girmek için 5 haneli numarayı yaz, sonra Enter",
                        manualValue: stopQuery.allSatisfy(\.isNumber) && stopQuery.count == 5 ? stopQuery : nil,
                        onPickManual: { stop.stopNo = stopQuery; stopQuery = ""; stopQueryFocused = false }
                    )
                } else {
                    VStack(spacing: 2) {
                        ForEach(results) { r in
                            StopResultRow(result: r) {
                                stop.stopNo = r.stopNo
                                if stop.name.trimmingCharacters(in: .whitespaces).isEmpty
                                    || stop.name.hasPrefix("Durak ") {
                                    stop.name = r.name
                                }
                                stopQuery = ""
                                stopQueryFocused = false
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Lines search field (chips + add via search)

    private var linesSearchField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HATLAR")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            FlowLayout(spacing: 5, lineSpacing: 5) {
                ForEach(stop.watchedLines, id: \.self) { line in
                    LineChip(line: line) {
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.18)) {
                                stop.watchedLines.removeAll { $0 == line }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("hat ekle (örn. 481, balgat)", text: $lineQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .focused($lineQueryFocused)
                    .onSubmit { fallbackAddLine() }
                if !lineQuery.isEmpty {
                    Button { lineQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        lineQueryFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            )
            .task(id: lineQueryFocused) {
                if lineQueryFocused { await index.ensureLinesLoaded() }
            }

            if !lineQuery.isEmpty {
                let results = index.searchLines(lineQuery, limit: 6)
                if results.isEmpty {
                    SearchEmptyResult(
                        message: index.linesLoaded
                            ? "sonuç yok — manuel eklemek için Enter"
                            : "hat listesi yükleniyor…",
                        manualValue: lineQuery.uppercased(),
                        onPickManual: { fallbackAddLine() }
                    )
                } else {
                    VStack(spacing: 2) {
                        ForEach(results) { r in
                            LineResultRow(result: r) { addLineCode(r.lineNo) }
                        }
                    }
                }
            }
        }
    }

    private func addLineCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty, !stop.watchedLines.contains(trimmed) else {
            lineQuery = ""
            return
        }
        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.28, bounce: 0.18)) {
                stop.watchedLines.append(trimmed)
            }
        }
        lineQuery = ""
    }

    private func fallbackAddLine() {
        addLineCode(lineQuery)
    }

}

// MARK: - Search result rows

private struct StopResultRow: View {
    let result: StopSearchResult
    let onPick: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(result.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                Spacer()
                Text(result.stopNo)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0.0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct LineResultRow: View {
    let result: LineSearchResult
    let onPick: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 8) {
                Text(result.lineNo)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .frame(minWidth: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                Text(result.route)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0.0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct SearchEmptyResult: View {
    let message: String
    let manualValue: String?
    let onPickManual: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            if let v = manualValue, !v.isEmpty {
                Button(action: onPickManual) {
                    HStack(spacing: 4) {
                        Image(systemName: "return")
                            .font(.system(size: 9))
                        Text("“\(v)” olarak ekle")
                            .font(.system(size: 10.5))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }
}

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            content()
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
    }
}

// MARK: - Notification permission denied banner

private struct NotifPermissionDeniedBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 12))
                .foregroundStyle(EGOTheme.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Bildirim izni kapalı")
                    .font(.system(size: 11, weight: .semibold))
                Text("Otobüs yaklaştığında banner görünmez. macOS bir kez reddedilen izni programatik olarak yeniden soramaz — elle açman lazım.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Notifier.openNotificationSettings()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9))
                        Text("Sistem Ayarları → Bildirimler")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(EGOTheme.red)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(EGOTheme.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(EGOTheme.red.opacity(0.30), lineWidth: 1)
        )
    }
}

// MARK: - Install location warning

private struct InstallLocationWarning: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Uygulama Desktop'tan çalışıyor")
                    .font(.system(size: 11, weight: .semibold))
                Text("macOS bu konumdan açılan uygulamaları kısıtlar; bildirimler bazen görünmez ve TCC izin penceresi açılır. Eninde sonunda /Applications klasörüne taşı.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    moveToApplications()
                } label: {
                    Text("Otomatik taşı ve yeniden başlat")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(EGOTheme.red)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.30), lineWidth: 1)
        )
    }

    private func moveToApplications() {
        let src = Bundle.main.bundleURL
        let dst = URL(fileURLWithPath: "/Applications/\(src.lastPathComponent)")
        // Use Process so we can ditto + relaunch from a copy that's already detached.
        let script = """
        rm -rf '\(dst.path)' 2>/dev/null
        cp -R '\(src.path)' '/Applications/'
        sleep 0.4
        open '\(dst.path)'
        sleep 0.4
        kill \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null
        """
        let proc = Process()
        proc.launchPath = "/bin/bash"
        proc.arguments = ["-c", script]
        try? proc.run()
    }
}

// MARK: - Add stop button

private struct AddStopButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("Yeni durak ekle")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(isHovered ? Color.primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.05 : 0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isHovered ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.15),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

// MARK: - Section wrapper

private struct Section<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

private var softCardBackground: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.primary.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
}

// MARK: - Chips

private struct LineChip: View {
    let line: String
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Text(line)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isHovered ? Color.red : Color.secondary)
                    .frame(width: 12, height: 12)
                    .background(
                        Circle().fill(isHovered ? Color.red.opacity(0.15) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
}

// MARK: - Step button

private struct StepButton: View {
    let symbol: String
    let action: () -> Void
    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(Color.primary.opacity(isHovered ? 0.12 : 0.07))
                )
                .scaleEffect(isPressed ? 0.92 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onLongPressGesture(minimumDuration: 0, perform: {}) { pressing in
            withAnimation(.easeOut(duration: 0.1)) { isPressed = pressing }
        }
    }
}

// MARK: - Hour picker

private struct HourPicker: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Picker("", selection: $value) {
                ForEach(0..<24) { hour in
                    Text(String(format: "%02d:00", hour)).tag(hour)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(.system(size: 11, design: .monospaced))
        }
    }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var currentRowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var currentRowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            let needed = currentRowWidth + (rows.last!.isEmpty ? 0 : spacing) + size.width
            if needed > maxWidth, !rows.last!.isEmpty {
                totalHeight += currentRowHeight + lineSpacing
                rows.append([])
                currentRowWidth = 0
                currentRowHeight = 0
            }
            rows[rows.count - 1].append(size)
            currentRowWidth += (rows.last!.count == 1 ? 0 : spacing) + size.width
            currentRowHeight = max(currentRowHeight, size.height)
        }
        totalHeight += currentRowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
