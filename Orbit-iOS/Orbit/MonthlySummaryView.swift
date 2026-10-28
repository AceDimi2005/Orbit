import SwiftUI

// MARK: - Opening a summary from an alert or a link

/// "Open this month's summary": from a tapped `summary.ready` alert or `orbit://summary?month=YYYY-MM&pc=<id>`.
struct OrbitSummaryRequest: Identifiable, Equatable {
    let id = UUID()
    /// The saved PC that sent the alert (nil: the selected PC).
    let pcID: String?
    let month: OrbitMonthID?

    init(pcID: String?, month: OrbitMonthID?) {
        self.pcID = pcID
        self.month = month
    }

    init(url: URL) {
        let parts = OrbitEnergyAPI.summaryLinkParts(url)
        pcID = parts?.pcID
        month = parts?.month
    }

    /// The link a tapped alert opens: that month's summary for `summary.ready`, nil for every other kind.
    static func link(forKind kind: String?, pcID: String?, deliveredAt date: Date) -> String? {
        OrbitEnergyAPI.alertLink(kind: kind, pcID: pcID, deliveredAt: date)
    }
}

/// The summary opened over the whole app (from an alert), with a Done button and the Pro check.
struct MonthlySummarySheet: View {
    @ObservedObject var vm: OrbitViewModel
    let request: OrbitSummaryRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            OrbitProGate(title: "Monthly Summary", message: MonthlySummaryView.proMessage) {
                MonthlySummaryView(vm: vm, pcID: request.pcID, initialMonth: request.month)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .orbitAppearance()
    }
}

// MARK: - Model

@MainActor
final class OrbitSummaryModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case olderAgent
        /// `replied`: the PC answered with an error (for example 503 while its ledger starts) rather than not at all.
        case failed(String, replied: Bool)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var summary: OrbitMonthSummary?
    @Published private(set) var currentMonth: OrbitMonthID?
    @Published private(set) var pcName = ""
    @Published private(set) var isConfigured = false
    @Published private(set) var isLoading = false
    /// The months the PC has play for, from the last summary (kept while another month loads or fails, so the
    /// picker stays).
    @Published private(set) var knownMonths: [String] = []
    /// The PC an alert came from, when Orbit can't read it from here: removed from My PCs since, or saved
    /// without the encrypted connection. Nothing of another PC is shown under its alert.
    @Published private(set) var unreachablePC: UnreachablePC?
    private(set) var link: OrbitPCLink?
    private(set) var isDemo = false
    private var requestedMonth: OrbitMonthID?
    private var generation = 0
    private var configuredFor: String?

    struct UnreachablePC: Equatable {
        let id: String
        /// Its name in My PCs; nil once it was removed.
        let savedName: String?
        /// The name its alerts were shown with (kept for a removed PC when Orbit still knows it).
        let lastKnownName: String?
    }

    var pickerMonths: [OrbitMonthID] {
        OrbitMonthID.pickerMonths(available: summary?.available ?? knownMonths, including: summary?.monthID ?? requestedMonth)
    }

    /// The PC's own month is on screen: it still grows while games run, so it's read again now and then.
    var isShowingCurrentMonth: Bool { summary?.monthID != nil && summary?.monthID == currentMonth }

    /// `pcID`: the PC an alert came from; when it isn't the selected one, its own saved connection is used.
    func configure(_ vm: OrbitViewModel, pcID: String?, initialMonth: OrbitMonthID?) {
        let key = "\(vm.isDemoMode)|\(pcID ?? vm.selectedPCID)|\(vm.connectionID)"
        guard key != configuredFor else {
            // Same PC and connection, maybe a new route (LAN address <-> Secondary IP): the next read goes to the
            // address in use; the summary on screen stays.
            if !isDemo, pcID == nil || pcID == vm.selectedPCID, link != nil { link = OrbitPCLink.current(vm) }
            return
        }
        configuredFor = key
        generation += 1
        isConfigured = true
        isDemo = vm.isDemoMode
        requestedMonth = initialMonth
        summary = nil
        currentMonth = nil
        knownMonths = []
        isLoading = false
        phase = .idle
        unreachablePC = nil
        if isDemo {
            link = nil
            pcName = vm.metrics.hostname
        } else if let pcID, pcID != vm.selectedPCID {
            if let other = OrbitPCLink.link(for: pcID) {
                link = other
                pcName = other.name
            } else {
                // Never the selected PC's month under another PC's alert.
                link = nil
                let saved = vm.savedPCs.first { $0.id == pcID }?.name
                unreachablePC = UnreachablePC(id: pcID, savedName: saved, lastKnownName: saved ?? OrbitPushStore.pcName(for: pcID))
                pcName = saved ?? ""
            }
        } else {
            link = OrbitPCLink.current(vm)
            pcName = vm.selectedPCName
        }
    }

    func load() async {
        if isDemo {
            let current = OrbitMonthID.containing(Date())
            currentMonth = current
            var month = requestedMonth ?? summary?.monthID
            if month == nil, !OrbitEnergyDemo.summary(current).hasPlay { month = current.shifted(by: -1) }
            // At the price entered on the demo cost screen, like a PC's summary would be.
            summary = OrbitEnergyDemoEdits.summary(month ?? current)
            knownMonths = summary?.available ?? []
            phase = .ready
            return
        }
        guard let link, !isLoading else { return }
        let version = generation
        isLoading = true
        if summary == nil { phase = .loading }
        defer { if version == generation { isLoading = false } }
        do {
            let features = try await OrbitFeatureStore.shared.features(for: link, maxAge: 60)
            guard version == generation else { return }
            guard features.has(OrbitEnergyAPI.summaryFeature) else { phase = .olderAgent; return }
            let month = requestedMonth ?? summary?.monthID
            var result: OrbitMonthSummary = try await link.client.get(OrbitEnergyAPI.monthSummaryPath, query: OrbitEnergyAPI.monthQuery(month))
            guard version == generation else { return }
            if month == nil {
                currentMonth = result.monthID
                // Early in a month there's little to show: open the newest month that has play instead.
                if !result.hasPlay, let current = result.monthID,
                   let previous = result.available.compactMap(OrbitMonthID.init).filter({ $0 < current }).max() {
                    result = try await link.client.get(OrbitEnergyAPI.monthSummaryPath, query: OrbitEnergyAPI.monthQuery(previous))
                    guard version == generation else { return }
                }
            }
            summary = result
            knownMonths = result.available
            requestedMonth = result.monthID
            phase = .ready
        } catch {
            // Cancelled with the screen's task (the app went inactive): the restarted task reads it again.
            guard version == generation, !Task.isCancelled else { return }
            if summary == nil { phase = .failed(OrbitPlainError.describe(error), replied: OrbitEnergyModel.replied(error)) }
        }
    }

    func select(_ month: OrbitMonthID) async {
        guard month != summary?.monthID else { return }
        requestedMonth = month
        if isDemo {
            summary = OrbitEnergyDemoEdits.summary(month)
            knownMonths = summary?.available ?? knownMonths
            return
        }
        generation += 1
        summary = nil
        isLoading = false
        await load()
    }
}

// MARK: - Screen

/// "Wrapped": one month of play as story pages on iPhone and a grid of cards on iPad, with a picture to share.
struct MonthlySummaryView: View {
    static let proMessage = "Your month in games, with top games, records, temperatures and energy, is part of Orbit Pro."

    @ObservedObject var vm: OrbitViewModel
    var pcID: String? = nil
    var initialMonth: OrbitMonthID? = nil
    @StateObject private var model = OrbitSummaryModel()
    @State private var page: Page = .cover
    @State private var picture: OrbitSummaryPicture?
    /// The person chose the selected PC's summary instead of an alert's PC that Orbit can't read.
    @State private var showsSelectedPC = false
    /// One height for every tile's symbol (they differ in shape), so the tiles of a row come out the same size.
    @ScaledMetric(relativeTo: .subheadline) private var statIconHeight: CGFloat = 20
    /// The story pages' rings grow with the text size (and stay inside the card).
    @ScaledMetric(relativeTo: .title) private var ringSize: CGFloat = 150
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.orbitTheme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum Page: String, CaseIterable, Identifiable {
        case cover, topGame, games, records, temperatures, energy, versus
        var id: String { rawValue }
    }

    /// The PC this screen reads: the alert's own PC, or the selected one.
    private var shownPCID: String? { showsSelectedPC ? nil : pcID }

    var body: some View {
        ZStack {
            OrbitAmbientBackground(isOnline: vm.metrics.isOnline || model.isDemo)
            content
        }
        .navigationTitle("Monthly Summary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.pickerMonths.count > 1 { monthMenu }
                if let picture, let summary = model.summary, summary.hasPlay {
                    ShareLink(item: picture, preview: SharePreview("\(summary.monthID?.title() ?? summary.month) in games", image: picture.preview)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share summary picture")
                }
            }
        }
        // The scene phase is part of the id: a task only sees the phase it started with, and an alert tapped
        // while Orbit launches opens this before the app is active. Restarted once it is, it loads.
        .task(id: "\(vm.connectionID)|\(vm.connectionHost())|\(vm.isDemoMode)|\(shownPCID ?? "")|\(scenePhase == .active)") {
            model.configure(vm, pcID: shownPCID, initialMonth: initialMonth)
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if model.summary == nil || model.phase != .ready || model.isShowingCurrentMonth { await model.load() }
                do { try await Task.sleep(for: .seconds(model.phase == .ready ? 120 : 5)) } catch { break }
            }
        }
        .task(id: shareKey) { preparePicture() }
        .onChange(of: model.summary?.month) { _, _ in page = Self.firstPage }
    }

    private var shareKey: String {
        guard let summary = model.summary else { return "none" }
        return "\(summary.month)|\(summary.playSeconds)|\(theme.rawValue)"
    }

    /// The Share button's item. Only a small preview is drawn here; the full picture is drawn when the
    /// person picks where it goes.
    private func preparePicture() {
        guard let summary = model.summary, summary.hasPlay else { picture = nil; return }
        picture = OrbitSummaryPicture.make(summary, accent: theme.accent, secondary: theme.secondary)
    }

    /// The first page after a month loads. Debug builds take `ORBIT_SELFTEST_SUMMARY_PAGE=topGame|games|…`
    /// for screenshots without swipes.
    private static var firstPage: Page {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["ORBIT_SELFTEST_SUMMARY_PAGE"], let page = Page(rawValue: name) { return page }
        #endif
        return .cover
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        if let unreachable = model.unreachablePC, !model.isDemo {
            ScrollView {
                unreachableNotice(unreachable)
                    .frame(maxWidth: 640)
                    .padding(18)
                    .frame(maxWidth: .infinity)
            }
        } else if let notice = blockingNotice {
            ScrollView {
                VStack(spacing: 14) { notice }
                    .frame(maxWidth: 640)
                    .padding(18)
                    .frame(maxWidth: .infinity)
            }
        } else if let summary = model.summary {
            if summary.hasPlay {
                VStack(spacing: 0) {
                    if model.isDemo {
                        OrbitNotice(title: "Demo mode", message: "Sample months for a gaming PC. Nothing is read from a PC.", icon: "sparkles", tint: .orange)
                            .padding(.horizontal, 18)
                            .padding(.top, 6)
                    }
                    if sizeClass == .regular { cardGrid(summary) } else { storyPages(summary) }
                }
            } else {
                ScrollView {
                    emptyMonth(summary)
                        .frame(maxWidth: 640)
                        .padding(18)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Putting \(model.pcName.isEmpty ? "your PC" : model.pcName)'s month together…")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// An alert's PC that Orbit can't read from here: say so, and offer the selected PC only when asked.
    private func unreachableNotice(_ pc: OrbitSummaryModel.UnreachablePC) -> some View {
        let canShowSelected = vm.hasSecureConnection && vm.selectedPCID != pc.id && vm.savedPCs.contains { $0.id == vm.selectedPCID }
        return VStack(spacing: 14) {
            if let name = pc.savedName {
                OrbitNotice(title: "Needs the encrypted connection", message: "Pair \(name) again in My PCs to see its monthly summary.",
                            icon: "lock.trianglebadge.exclamationmark", tint: .orange)
            } else {
                OrbitNotice(title: "\(pc.lastKnownName ?? "This PC") is no longer saved in Orbit",
                            message: "The summary alert came from a PC that isn't in My PCs any more, so Orbit can't read its month.",
                            icon: "desktopcomputer", tint: .orange)
            }
            if canShowSelected {
                Button {
                    OrbitHaptics.tap()
                    showsSelectedPC = true
                } label: {
                    Label("Show \(vm.selectedPCName) Instead", systemImage: "arrow.right.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent))
            }
        }
    }

    private var blockingNotice: OrbitNotice? {
        let name = model.pcName.isEmpty ? vm.selectedPCName : model.pcName
        if model.isDemo { return nil }
        if model.isConfigured && model.link == nil {
            if vm.savedPCs.isEmpty || !vm.isConfigured {
                return OrbitNotice(title: "Pair a PC first", message: "Find and pair your PC in My PCs to see your month in games.", icon: "desktopcomputer", tint: .orange)
            }
            return OrbitNotice(title: "Needs the encrypted connection", message: "Pair \(name) again in My PCs to see its monthly summary.", icon: "lock.trianglebadge.exclamationmark", tint: .orange)
        }
        if model.phase == .olderAgent {
            return OrbitNotice(title: "Update Orbit PC Companion", message: "\(name) runs an older agent without monthly summaries. Update it from Settings › Check for PC Companion Update.", icon: "arrow.down.circle.fill", tint: .orange)
        }
        if model.summary == nil, case .failed(let message, let replied) = model.phase {
            return OrbitNotice(title: replied ? "Can't show the summary yet" : "Couldn't reach \(name)", message: message,
                               icon: "exclamationmark.triangle.fill", tint: .orange)
        }
        return nil
    }

    private func emptyMonth(_ summary: OrbitMonthSummary) -> some View {
        let month = summary.monthID?.name() ?? "this month"
        let first = summary.available.isEmpty
        // The picker sits in the toolbar only when there is another month to pick.
        let pick = model.pickerMonths.count > 1 ? " Pick another month above, or come back after a gaming session." : " Come back after a gaming session."
        return VStack(spacing: 14) {
            OrbitEmptyState(icon: first ? "sparkles" : "gamecontroller",
                            title: first ? "Your first summary is on its way" : "No games recorded in \(month)",
                            message: first
                                ? "Play a game while Orbit PC Companion runs on \(model.pcName). Orbit counts play time, frame rates and temperatures, and your month appears here."
                                : "Orbit PC Companion counts play time while a game runs." + pick,
                            tint: theme.accent)
            if !summary.available.isEmpty, summary.monthID == model.currentMonth {
                Text("You'll also get a notification when a month is ready, if you turned that on in Notifications.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(18)
        .liquidGlass(cornerRadius: 24, tint: theme.accent)
    }

    private var monthMenu: some View {
        Menu {
            ForEach(model.pickerMonths) { month in
                Button {
                    OrbitHaptics.selection()
                    Task { await model.select(month) }
                } label: {
                    if month == model.summary?.monthID {
                        Label(month.title(), systemImage: "checkmark")
                    } else {
                        Text(month.title())
                    }
                }
            }
        } label: {
            Image(systemName: "calendar")
        }
        .accessibilityLabel("Month")
        .accessibilityValue(model.summary?.monthID?.title() ?? "")
    }

    // MARK: Layouts

    private func pages(_ summary: OrbitMonthSummary) -> [Page] {
        Page.allCases.filter { page in
            switch page {
            case .cover, .games: return true
            case .topGame: return summary.topGame != nil
            case .records: return summary.longestSession != nil || summary.busiestDay != nil
            case .temperatures: return summary.peakCPUTemp != nil || summary.peakGPUTemp != nil
            case .energy: return (summary.energy?.kWh ?? 0) > 0
            case .versus: return summary.previous != nil
            }
        }
    }

    private func storyPages(_ summary: OrbitMonthSummary) -> some View {
        // Each card fills the page like a story, its content in the middle; larger text scrolls inside it.
        GeometryReader { proxy in
            TabView(selection: $page) {
                ForEach(pages(summary)) { page in
                    ScrollView(showsIndicators: false) {
                        storyCard(page, summary: summary, minHeight: max(380, proxy.size.height - 70))
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                            .padding(.bottom, 52)
                    }
                    .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
        }
    }

    private func cardGrid(_ summary: OrbitMonthSummary) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 16, alignment: .top)], spacing: 16) {
                ForEach(pages(summary)) { page in storyCard(page, summary: summary, minHeight: 320) }
            }
            .frame(maxWidth: 1200)
            .padding(18)
            .frame(maxWidth: .infinity)
        }
    }

    private func tint(for page: Page) -> Color {
        switch page {
        case .cover: return theme.accent
        case .topGame: return .orange
        case .games: return .pink
        case .records: return .mint
        case .temperatures: return .red
        case .energy: return .yellow
        case .versus: return .purple
        }
    }

    @ViewBuilder
    private func storyCard(_ page: Page, summary: OrbitMonthSummary, minHeight: CGFloat) -> some View {
        let tint = tint(for: page)
        VStack(alignment: .leading, spacing: 16) {
            switch page {
            case .cover: coverPage(summary, tint: tint)
            case .topGame: topGamePage(summary, tint: tint)
            case .games: gamesPage(summary, tint: tint)
            case .records: recordsPage(summary, tint: tint)
            case .temperatures: temperaturesPage(summary, tint: tint)
            case .energy: energyPage(summary, tint: tint)
            case .versus: versusPage(summary, tint: tint)
            }
        }
        .padding(22)
        // `.leading` centres the page's content vertically in a card taller than it.
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.06), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .liquidGlass(cornerRadius: 28, tint: tint, elevated: true)
        .accessibilityElement(children: .contain)
    }

    private func eyebrow(_ text: String, icon: String, tint: Color) -> some View {
        Label(text.uppercased(), systemImage: icon)
            .font(.caption.weight(.heavy))
            .tracking(1.2)
            .foregroundStyle(tint)
            .accessibilityAddTraits(.isHeader)
    }

    private func bigNumber(_ text: String, spoken: String? = nil, tint: Color) -> some View {
        Text(text)
            .font(.system(.largeTitle, design: .rounded).weight(.heavy))
            .foregroundStyle(LinearGradient(colors: [.white, tint], startPoint: .topLeading, endPoint: .bottomTrailing))
            .minimumScaleFactor(0.5)
            .lineLimit(2)
            .accessibilityLabel(spoken ?? text)
    }

    private func statTile(_ title: String, _ value: String, spoken: String? = nil, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.subheadline.weight(.bold)).foregroundStyle(tint)
                .frame(height: statIconHeight, alignment: .leading)
                .accessibilityHidden(true)
            Text(value).font(.title3.weight(.bold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                .accessibilityLabel(spoken ?? value)
            // Two lines kept for every title, so the tiles of a row line up whatever their titles' length.
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func statGrid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10, alignment: .top)], spacing: 10, content: content)
    }

    /// The pages' big visual: a ring filled to `fraction`, with its number in the middle. VoiceOver reads
    /// `spoken` instead of the parts.
    private func ring(_ fraction: Double, value: String, caption: String, tint: Color, spoken: String, scale: CGFloat = 1) -> some View {
        let side = min(ringSize * scale, 220 * scale)
        let line = max(9, side * 0.085)
        return ZStack {
            Circle().stroke(.white.opacity(0.08), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.012, min(1, fraction.isFinite ? fraction : 0)))
                .stroke(LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.35), radius: 10)
            VStack(spacing: 1) {
                Text(value)
                    .font(.system(.title, design: .rounded).weight(.heavy))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(caption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .lineLimit(2)
            }
            .padding(line + side * 0.08)
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// A ring centred in the card, with a little room around it.
    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack { Spacer(minLength: 0); content(); Spacer(minLength: 0) }
            .padding(.vertical, 6)
    }

    // MARK: Pages

    /// Days in the month so far: the whole month once it's over, today's date while it runs.
    private func daysSoFar(_ summary: OrbitMonthSummary) -> Int? {
        guard let month = summary.monthID else { return nil }
        let total = month.dayCount()
        guard month == model.currentMonth else { return total }
        let today = OrbitEnergyFormat.gregorian().component(.day, from: Date())
        return min(total, max(summary.daysPlayed, today))
    }

    private func coverPage(_ summary: OrbitMonthSummary, tint: Color) -> some View {
        let days = daysSoFar(summary)
        let isCurrent = summary.monthID == model.currentMonth
        return Group {
            eyebrow(summary.monthID?.title() ?? summary.month, icon: "calendar", tint: tint)
            Text("Your month in games").font(.title2.weight(.bold))
            VStack(alignment: .leading, spacing: 4) {
                bigNumber(OrbitEnergyFormat.duration(summary.playSeconds), spoken: OrbitEnergyFormat.spokenDuration(summary.playSeconds), tint: tint)
                Text("of play on \(model.pcName)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let days, days > 0 {
                centred {
                    ring(Double(summary.daysPlayed) / Double(days), value: "\(summary.daysPlayed)",
                         caption: "of \(days) days\(isCurrent ? " so far" : "")", tint: tint,
                         spoken: "Played on \(summary.daysPlayed) of \(days) days\(isCurrent ? " so far" : "")")
                }
            }
            statGrid {
                if days == nil { statTile("Days played", "\(summary.daysPlayed)", icon: "calendar.badge.checkmark", tint: tint) }
                statTile(summary.sessions == 1 ? "Session" : "Sessions", "\(summary.sessions)", icon: "play.circle.fill", tint: tint)
                statTile(summary.games.count == 1 ? "Game" : "Games", "\(summary.games.count)", icon: "gamecontroller.fill", tint: tint)
                if let average = summary.averageSessionSeconds {
                    statTile("Average session", OrbitEnergyFormat.duration(average), spoken: OrbitEnergyFormat.spokenDuration(average), icon: "timer", tint: tint)
                }
            }
            if sizeClass != .regular {
                Label("Swipe for your top game", systemImage: "hand.draw")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func topGamePage(_ summary: OrbitMonthSummary, tint: Color) -> some View {
        if let top = summary.topGame {
            eyebrow("Top game", icon: "crown.fill", tint: tint)
            Text(top.name)
                .font(.system(.title, design: .rounded).weight(.heavy))
                .fixedSize(horizontal: false, vertical: true)
            bigNumber(OrbitEnergyFormat.duration(top.playSeconds), spoken: OrbitEnergyFormat.spokenDuration(top.playSeconds), tint: tint)
            if let share = summary.topGameShare {
                centred {
                    ring(share, value: OrbitEnergyFormat.percent(share), caption: "of your play time", tint: tint,
                         spoken: "\(OrbitEnergyFormat.percent(share)) of your play time")
                }
            }
            statGrid {
                statTile("Days played", "\(top.daysPlayed)", icon: "calendar", tint: tint)
                if top.averageFPS != nil { statTile("Average frame rate", OrbitEnergyFormat.fps(top.averageFPS), icon: "speedometer", tint: tint) }
                if top.peakGPUTemp != nil { statTile("Hottest GPU", OrbitEnergyFormat.temperature(top.peakGPUTemp), icon: "thermometer.high", tint: tint) }
                if top.kWh > 0 { statTile("Energy (estimate)", OrbitEnergyFormat.energy(top.kWh), icon: "bolt.fill", tint: tint) }
            }
        }
    }

    private func gamesPage(_ summary: OrbitMonthSummary, tint: Color) -> some View {
        let shown = Array(summary.games.prefix(8))
        return Group {
            eyebrow("Every game", icon: "list.number", tint: tint)
            Text(summary.games.count == 1 ? "One game this month" : "\(summary.games.count) games this month").font(.title2.weight(.bold))
            VStack(spacing: 12) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, game in
                    gameRow(rank: index + 1, game: game, total: summary.playSeconds, tint: tint)
                }
            }
            if summary.games.count > shown.count {
                Text("and \(summary.games.count - shown.count) more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func gameRow(rank: Int, game: OrbitMonthSummary.Game, total: Double, tint: Color) -> some View {
        let share = total > 0 ? min(1, game.playSeconds / total) : 0
        var details = [OrbitEnergyFormat.duration(game.playSeconds)]
        if game.averageFPS != nil { details.append(OrbitEnergyFormat.fps(game.averageFPS)) }
        if game.peakGPUTemp != nil { details.append("GPU up to \(OrbitEnergyFormat.temperature(game.peakGPUTemp))") }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(rank)")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(rank == 1 ? Color.black : Color.white)
                    .frame(width: 24, height: 24)
                    .background(rank == 1 ? AnyShapeStyle(tint) : AnyShapeStyle(Color.white.opacity(0.12)), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name).font(.subheadline.weight(.bold)).lineLimit(2)
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(tint.opacity(0.85)).frame(width: max(5, proxy.size.width * share))
                }
            }
            .frame(height: 5)
            .padding(.leading, 34)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Number \(rank), \(game.name)")
        .accessibilityValue(([OrbitEnergyFormat.spokenDuration(game.playSeconds)] + details.dropFirst()).joined(separator: ", "))
    }

    private func recordsPage(_ summary: OrbitMonthSummary, tint: Color) -> some View {
        Group {
            eyebrow("Records", icon: "trophy.fill", tint: tint)
            if let longest = summary.longestSession {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Longest session").font(.headline)
                    bigNumber(OrbitEnergyFormat.duration(longest.seconds), spoken: OrbitEnergyFormat.spokenDuration(longest.seconds), tint: tint)
                    Text("\(longest.name) · \(OrbitEnergyFormat.longDay(longest.date))")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            if let busiest = summary.busiestDay {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Busiest day").font(.headline)
                    Text(OrbitEnergyFormat.longDay(busiest.day))
                        .font(.system(.title2, design: .rounded).weight(.heavy))
                    Text("\(OrbitEnergyFormat.duration(busiest.playSeconds)) of play")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityLabel("\(OrbitEnergyFormat.spokenDuration(busiest.playSeconds)) of play")
                }
                .padding(.top, 6)
            }
            // How the record compares with a usual session.
            if let longest = summary.longestSession, longest.seconds > 0, let average = summary.averageSessionSeconds {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Session length").font(.headline)
                    comparisonBar(label: "Longest", value: OrbitEnergyFormat.duration(longest.seconds), fraction: 1, color: tint)
                    comparisonBar(label: "Average", value: OrbitEnergyFormat.duration(average), fraction: min(1, average / longest.seconds),
                                  color: .white.opacity(0.35))
                }
                .padding(.top, 6)
            }
            Text("A session ends after its game has been closed for five minutes, so a quick restart stays one session.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Green to red with the heat, for the temperature gauges.
    private func heat(_ celsius: Double) -> Color {
        switch celsius {
        case ..<60: return .green
        case ..<75: return .yellow
        case ..<85: return .orange
        default: return .red
        }
    }

    @ViewBuilder
    private func temperatureGauge(_ title: String, _ celsius: Double?) -> some View {
        if let celsius, celsius.isFinite {
            VStack(spacing: 8) {
                ring(celsius / 100, value: OrbitEnergyFormat.temperature(celsius), caption: "of 100 °C", tint: heat(celsius),
                     spoken: "\(title), \(Int(celsius.rounded())) degrees Celsius", scale: 0.78)
                Text(title).font(.subheadline.weight(.semibold)).accessibilityHidden(true)
            }
        }
    }

    private func temperaturesPage(_ summary: OrbitMonthSummary, tint: Color) -> some View {
        Group {
            eyebrow("Temperatures", icon: "thermometer.medium", tint: tint)
            Text("How hot it got").font(.title2.weight(.bold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    Spacer(minLength: 0)
                    temperatureGauge("Hottest CPU", summary.peakCPUTemp)
                    temperatureGauge("Hottest GPU", summary.peakGPUTemp)
                    Spacer(minLength: 0)
                }
                VStack(spacing: 14) {
                    temperatureGauge("Hottest CPU", summary.peakCPUTemp)
                    temperatureGauge("Hottest GPU", summary.peakGPUTemp)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 4)
            if let hottest = summary.hottestGame, let peak = hottest.peakGPUTemp {
                Text("\(hottest.name) pushed the GPU the hardest, up to \(OrbitEnergyFormat.temperature(peak))\(hottest.averageGPUTemp.map { ", \(OrbitEnergyFormat.temperature($0)) on average" } ?? "").")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Peaks while playing, from the PC's own sensors.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func energyPage(_ summary: OrbitMonthSummary, tint: Color) -> some View {
        if let energy = summary.energy {
            eyebrow("Energy", icon: "bolt.fill", tint: tint)
            Text("What it took").font(.title2.weight(.bold))
            VStack(alignment: .leading, spacing: 4) {
                bigNumber(OrbitEnergyFormat.energy(energy.kWh), spoken: OrbitEnergyFormat.energy(energy.kWh).replacingOccurrences(of: "kWh", with: "kilowatt hours"), tint: tint)
                if energy.cost != nil, energy.currency != nil {
                    Text("\(OrbitEnergyFormat.approximateCost(energy.cost, currency: energy.currency, kWh: energy.kWh, pricePerKWh: summary.averagePricePerKWh)) of electricity")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            if let gaming = energy.gamingKWh, energy.kWh > 0 {
                let share = min(1, gaming / energy.kWh)
                centred {
                    ring(share, value: OrbitEnergyFormat.percent(share), caption: "while gaming", tint: tint,
                         spoken: "\(OrbitEnergyFormat.percent(share)) of it while gaming")
                }
                Text("\(OrbitEnergyFormat.energy(gaming)) of it while gaming; the rest was the desktop, videos and idle time.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("An estimate from the PC's power sensors, the rest of the PC and your electricity price. See Tools › Electricity Cost for the details.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func versusPage(_ summary: OrbitMonthSummary, tint: Color) -> some View {
        if let previous = summary.previous {
            let previousName = OrbitMonthID(previous.month)?.name() ?? "last month"
            eyebrow("Versus \(previousName)", icon: "arrow.left.arrow.right", tint: tint)
            if let headline = summary.versusHeadline(previousName: previousName) {
                Text(headline).font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            comparisonBars(title: "Play time", current: summary.playSeconds, previous: previous.playSeconds,
                           currentText: OrbitEnergyFormat.duration(summary.playSeconds), previousText: OrbitEnergyFormat.duration(previous.playSeconds),
                           currentLabel: summary.monthID?.name() ?? "This month", previousLabel: previousName, tint: tint)
            if let energy = summary.energy, energy.kWh > 0 || previous.kWh > 0 {
                comparisonBars(title: "Energy (estimate)", current: energy.kWh, previous: previous.kWh,
                               currentText: OrbitEnergyFormat.energy(energy.kWh), previousText: OrbitEnergyFormat.energy(previous.kWh),
                               currentLabel: summary.monthID?.name() ?? "This month", previousLabel: previousName, tint: tint)
                if let change = summary.energyChange {
                    Text("Energy: \(change.sentence(versus: previousName).lowercasedFirst)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func comparisonBars(title: String, current: Double, previous: Double, currentText: String, previousText: String,
                                currentLabel: String, previousLabel: String, tint: Color) -> some View {
        // The longer bar fills the row (kWh can be well under 1 in a short month).
        let maximum = max(current, previous)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            comparisonBar(label: previousLabel, value: previousText, fraction: maximum > 0 ? previous / maximum : 0, color: .white.opacity(0.35))
            comparisonBar(label: currentLabel, value: currentText, fraction: maximum > 0 ? current / maximum : 0, color: tint)
        }
    }

    private func comparisonBar(label: String, value: String, fraction: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.weight(.semibold))
                Spacer()
                Text(value).font(.caption.weight(.bold)).monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(color).frame(width: max(6, proxy.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
