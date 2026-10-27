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
    private(set) var link: OrbitPCLink?
    private(set) var isDemo = false
    private var requestedMonth: OrbitMonthID?
    private var generation = 0
    private var configuredFor: String?

    var pickerMonths: [OrbitMonthID] {
        OrbitMonthID.pickerMonths(available: summary?.available ?? knownMonths, including: summary?.monthID ?? requestedMonth)
    }

    /// `pcID`: the PC an alert came from; when it isn't the selected one, its own saved connection is used.
    func configure(_ vm: OrbitViewModel, pcID: String?, initialMonth: OrbitMonthID?) {
        let key = "\(vm.isDemoMode)|\(pcID ?? vm.selectedPCID)|\(vm.connectionID)"
        guard key != configuredFor else { return }
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
        if isDemo {
            link = nil
            pcName = vm.metrics.hostname
        } else if let pcID, pcID != vm.selectedPCID, let other = OrbitPCLink.link(for: pcID) {
            link = other
            pcName = other.name
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
            summary = OrbitEnergyDemo.summary(month ?? current)
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
            guard version == generation else { return }
            if summary == nil { phase = .failed(OrbitPlainError.describe(error), replied: (error as? OrbitError)?.statusCode != nil) }
        }
    }

    func select(_ month: OrbitMonthID) async {
        guard month != summary?.monthID else { return }
        requestedMonth = month
        if isDemo {
            summary = OrbitEnergyDemo.summary(month)
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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.orbitTheme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum Page: String, CaseIterable, Identifiable {
        case cover, topGame, games, records, temperatures, energy, versus
        var id: String { rawValue }
    }

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
                    ShareLink(item: picture, preview: SharePreview("\(summary.monthID?.title() ?? summary.month) in games", image: picture.image)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share summary picture")
                }
            }
        }
        .task(id: "\(vm.connectionID)|\(vm.isDemoMode)|\(pcID ?? "")") {
            model.configure(vm, pcID: pcID, initialMonth: initialMonth)
            while !Task.isCancelled {
                if scenePhase == .active, model.summary == nil || model.phase != .ready { await model.load() }
                do { try await Task.sleep(for: .seconds(model.phase == .ready ? 120 : 5)) } catch { break }
            }
        }
        .task(id: shareKey) { renderPicture() }
        .onChange(of: model.summary?.month) { _, _ in page = Self.firstPage }
    }

    private var shareKey: String {
        guard let summary = model.summary else { return "none" }
        return "\(summary.month)|\(summary.playSeconds)|\(theme.rawValue)"
    }

    private func renderPicture() {
        guard let summary = model.summary, summary.hasPlay else { picture = nil; return }
        picture = OrbitSummaryPicture.render(summary, accent: theme.accent, secondary: theme.secondary)
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
        if let notice = blockingNotice {
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
        return VStack(spacing: 14) {
            OrbitEmptyState(icon: first ? "sparkles" : "gamecontroller",
                            title: first ? "Your first summary is on its way" : "No games recorded in \(month)",
                            message: first
                                ? "Play a game while Orbit PC Companion runs on \(model.pcName). Orbit counts play time, frame rates and temperatures, and your month appears here."
                                : "Orbit PC Companion counts play time while a game runs. Pick another month above, or come back after a gaming session.",
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
        // Each card fills the page like a story; larger text scrolls inside it.
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
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
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

    private func statTile(_ title: String, _ value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.subheadline.weight(.bold)).foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(value).font(.title3.weight(.bold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func statGrid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10, content: content)
    }

    // MARK: Pages

    private func coverPage(_ summary: OrbitMonthSummary, tint: Color) -> some View {
        Group {
            eyebrow(summary.monthID?.title() ?? summary.month, icon: "calendar", tint: tint)
            Text("Your month in games").font(.title2.weight(.bold))
            VStack(alignment: .leading, spacing: 4) {
                bigNumber(OrbitEnergyFormat.duration(summary.playSeconds), spoken: OrbitEnergyFormat.spokenDuration(summary.playSeconds), tint: tint)
                Text("of play on \(model.pcName)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            statGrid {
                statTile("Days played", "\(summary.daysPlayed)", icon: "calendar.badge.checkmark", tint: tint)
                statTile("Sessions", "\(summary.sessions)", icon: "play.circle.fill", tint: tint)
                statTile(summary.games.count == 1 ? "Game" : "Games", "\(summary.games.count)", icon: "gamecontroller.fill", tint: tint)
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
            VStack(alignment: .leading, spacing: 4) {
                bigNumber(OrbitEnergyFormat.duration(top.playSeconds), spoken: OrbitEnergyFormat.spokenDuration(top.playSeconds), tint: tint)
                if let share = summary.topGameShare {
                    Text("\(OrbitEnergyFormat.percent(share)) of your play time").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
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
            Text("A session ends after its game has been closed for five minutes, so a quick restart stays one session.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func temperaturesPage(_ summary: OrbitMonthSummary, tint: Color) -> some View {
        Group {
            eyebrow("Temperatures", icon: "thermometer.medium", tint: tint)
            Text("How hot it got").font(.title2.weight(.bold))
            statGrid {
                if summary.peakCPUTemp != nil { statTile("Hottest CPU", OrbitEnergyFormat.temperature(summary.peakCPUTemp), icon: "cpu", tint: tint) }
                if summary.peakGPUTemp != nil { statTile("Hottest GPU", OrbitEnergyFormat.temperature(summary.peakGPUTemp), icon: "rectangle.3.group.fill", tint: tint) }
            }
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
                    Text("about \(OrbitEnergyFormat.cost(energy.cost, currency: energy.currency, kWh: energy.kWh)) of electricity")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            if let gaming = energy.gamingKWh, energy.kWh > 0 {
                Text("\(OrbitEnergyFormat.energy(gaming)) of it while gaming (\(OrbitEnergyFormat.percent(min(1, gaming / energy.kWh)))).")
                    .font(.subheadline)
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
            if let change = summary.playChange {
                Text(change.sentence(versus: previousName)).font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Your first month with Orbit counting").font(.title2.weight(.bold))
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
