import SwiftUI

// Electricity cost and the monthly summary on the Mac: a compact "This Month" card in Sessions (which is
// already behind Orbit Pro) and a Monthly Summary sheet. Models, formatting and demo data are shared with
// the iPhone (`Shared/OrbitEnergy.swift`); the share picture too (`Shared/OrbitSummaryShareCard.swift`).

private struct MacEnergyCapabilities: Decodable {
    var features: [String]?
}

/// An error in plain words: the PC's own sentence, or what to check when it didn't answer.
private func macEnergyErrorText(_ error: Error, pcName: String) -> String {
    if let orbit = error as? OrbitError { return orbit.message }
    if let url = error as? URLError {
        switch url.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet, .dnsLookupFailed:
            return "\(pcName) didn't answer. Check that it's awake, on the same network, and that Orbit PC Companion is running."
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .secureConnectionFailed:
            return "\(pcName)'s identity didn't match. Pair it again in My PCs."
        default: break
        }
    }
    if error is DecodingError { return "\(pcName) sent a reply Orbit doesn't understand. Update Orbit PC Companion and Orbit." }
    return error.localizedDescription
}

/// This month's estimate and summary for the selected PC.
@MainActor
final class MacThisMonthModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case olderAgent
        case offline
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var energy: OrbitEnergyMonth?
    @Published private(set) var summary: OrbitMonthSummary?
    @Published private(set) var hasSummaryFeature = false
    private var loadedKey: String?
    private var isLoading = false

    func load(_ vm: OrbitMacViewModel) async {
        let key = "\(vm.isDemoMode)|\(vm.selectedPCID)|\(vm.generation)"
        if key != loadedKey {
            loadedKey = key
            energy = nil
            summary = nil
            hasSummaryFeature = false
            phase = .idle
            isLoading = false
        }
        if vm.isDemoMode {
            energy = OrbitEnergyDemo.energyMonth()
            summary = OrbitEnergyDemo.summary()
            hasSummaryFeature = true
            phase = .ready
            return
        }
        guard vm.currentPC != nil else { phase = .idle; return }
        guard vm.metrics.isOnline else {
            if energy == nil && summary == nil { phase = .offline }
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { if key == loadedKey { isLoading = false } }
        if energy == nil && summary == nil { phase = .loading }
        do {
            let client = try vm.client()
            let features: Set<String>
            do {
                let reply: MacEnergyCapabilities = try await client.get("/api/capabilities")
                features = Set(reply.features ?? [])
            } catch let error as OrbitError where error.statusCode == 404 {
                features = []
            }
            guard key == loadedKey else { return }
            let hasEnergy = features.contains(OrbitEnergyAPI.energyFeature)
            let hasSummary = features.contains(OrbitEnergyAPI.summaryFeature)
            guard hasEnergy || hasSummary else { phase = .olderAgent; return }
            hasSummaryFeature = hasSummary
            async let energyReply = Self.fetch(OrbitEnergyMonth.self, from: client, OrbitEnergyAPI.energySummaryPath, when: hasEnergy)
            async let summaryReply = Self.fetch(OrbitMonthSummary.self, from: client, OrbitEnergyAPI.monthSummaryPath, when: hasSummary)
            let (newEnergy, newSummary) = try await (energyReply, summaryReply)
            guard key == loadedKey else { return }
            energy = newEnergy
            summary = newSummary
            phase = .ready
        } catch {
            guard key == loadedKey else { return }
            if energy == nil && summary == nil { phase = .failed(macEnergyErrorText(error, pcName: vm.selectedPCName)) }
        }
    }

    private nonisolated static func fetch<T: Decodable>(_ type: T.Type, from client: OrbitAPIClient, _ path: String, when enabled: Bool) async throws -> T? {
        guard enabled else { return nil }
        let value: T = try await client.get(path)
        return value
    }
}

// MARK: - This Month card

struct MacThisMonthCard: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @StateObject private var model = MacThisMonthModel()
    @State private var showsSummary = false

    private var pcName: String { vm.selectedPCName }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            MacIconBadge(systemName: "calendar", tint: .orange, size: 44)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text("This Month")
                        .font(.system(.title3, weight: .bold))
                    if let month = (model.energy?.monthID ?? model.summary?.monthID) {
                        Text(month.title()).font(.callout).foregroundStyle(.secondary)
                    }
                    if model.energy != nil { MacStatusPill(text: "Estimate", tint: .yellow, icon: "info.circle.fill") }
                }
                details
            }
            Spacer(minLength: 8)
            if model.phase == .loading { ProgressView().controlSize(.small) }
            Button {
                showsSummary = true
            } label: {
                Label("Monthly Summary", systemImage: "sparkles")
            }
            .buttonStyle(MacHoverButtonStyle(tint: .orange, prominent: model.hasSummaryFeature))
            .disabled(!model.hasSummaryFeature)
            .help(model.hasSummaryFeature ? "Your month in games: top games, records, temperatures and energy" : "Needs a newer Orbit PC Companion on the PC")
        }
        .padding(18)
        .macGlass(cornerRadius: 22, tint: .orange)
        .task(id: "\(vm.selectedPCID)|\(vm.metrics.isOnline)|\(vm.isDemoMode)") {
            while !Task.isCancelled {
                await model.load(vm)
                // The PC writes its energy ledger every minute.
                do { try await Task.sleep(for: .seconds(model.phase == .ready ? 120 : 10)) } catch { break }
            }
        }
        .sheet(isPresented: $showsSummary) {
            MacMonthlySummarySheet(initial: model.summary)
                .environmentObject(vm)
                .macAppearance()
        }
    }

    @ViewBuilder
    private var details: some View {
        switch model.phase {
        case .ready:
            // The top game's name can be long: drop chips rather than overflow a narrow window.
            ViewThatFits(in: .horizontal) {
                chips(showsTopGame: true, showsEnergy: true)
                chips(showsTopGame: false, showsEnergy: true)
                chips(showsTopGame: false, showsEnergy: false)
            }
        case .olderAgent:
            Text("Update Orbit PC Companion on \(pcName) to see electricity cost and monthly summaries.")
                .font(.caption).foregroundStyle(.secondary)
        case .offline:
            Text("Connect to \(pcName) to see what this month cost and what you played.")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
        case .idle, .loading:
            Text("Reading this month from \(pcName)…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chips(showsTopGame: Bool, showsEnergy: Bool) -> some View {
        HStack(spacing: 8) {
            if let energy = model.energy {
                if energy.cost != nil, energy.currency != nil {
                    MacStatChip(label: "Cost", value: OrbitEnergyFormat.cost(energy.cost, currency: energy.currency, kWh: energy.kWh), icon: "bolt.fill", tint: .yellow)
                } else {
                    MacStatChip(label: "Cost", value: "Set a price on iPhone", icon: "bolt.fill", tint: .yellow)
                        .help("Orbit has no electricity price for this PC's country yet. Set yours in Orbit on iPhone or iPad: Tools › Electricity Cost.")
                }
                if showsEnergy { MacStatChip(label: "Energy", value: OrbitEnergyFormat.energy(energy.kWh), icon: "powerplug.fill") }
            }
            if let summary = model.summary {
                MacStatChip(label: "Played", value: OrbitEnergyFormat.duration(summary.playSeconds), icon: "gamecontroller.fill", tint: .orange)
                if showsTopGame, let top = summary.topGame {
                    MacStatChip(label: "Top game", value: top.name, icon: "crown.fill", tint: .orange)
                }
            }
        }
    }
}

// MARK: - Monthly Summary sheet

struct MacMonthlySummarySheet: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let initial: OrbitMonthSummary?
    @State private var summary: OrbitMonthSummary?
    @State private var error: String?
    @State private var isLoading = false
    @State private var picture: OrbitSummaryPicture?
    @State private var loadedInitial = false

    private var months: [OrbitMonthID] { OrbitMonthID.pickerMonths(available: summary?.available ?? [], including: summary?.monthID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                content
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 780, idealWidth: 880, minHeight: 600, idealHeight: 720)
        .background(MacAmbientBackground(isOnline: true))
        .task {
            guard !loadedInitial else { return }
            loadedInitial = true
            if let initial { summary = initial } else { await load(nil) }
            // Early in a month there's little to show: open the newest month with play instead.
            if let shown = summary, !shown.hasPlay, let current = shown.monthID,
               let previous = shown.available.compactMap(OrbitMonthID.init).filter({ $0 < current }).max() {
                await load(previous)
            }
        }
        .task(id: pictureKey) {
            guard let summary, summary.hasPlay else { picture = nil; return }
            picture = OrbitSummaryPicture.render(summary, accent: theme.accent, secondary: theme.secondary)
        }
    }

    private var pictureKey: String { "\(summary?.month ?? "")|\(summary?.playSeconds ?? 0)|\(theme.rawValue)" }

    private var header: some View {
        HStack(spacing: 12) {
            MacIconBadge(systemName: "sparkles", tint: .orange, size: 36, filled: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Monthly Summary").font(.title2.weight(.bold))
                Text(vm.isDemoMode ? "Demo mode · sample months" : vm.selectedPCName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            if months.count > 1 {
                Picker("Month", selection: Binding(get: { summary?.monthID ?? months.first! }, set: { month in Task { await load(month) } })) {
                    ForEach(months) { Text($0.title()).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
                .disabled(isLoading)
            }
            if let picture, let summary, summary.hasPlay {
                ShareLink(item: picture, preview: SharePreview("\(summary.monthID?.title() ?? summary.month) in games", image: picture.image)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(MacHoverButtonStyle(tint: theme.accent))
                .help("Share a picture of this month")
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(MacHoverButtonStyle(tint: .white))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func load(_ month: OrbitMonthID?) async {
        if vm.isDemoMode {
            summary = OrbitEnergyDemo.summary(month)
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let reply: OrbitMonthSummary = try await vm.client().get(OrbitEnergyAPI.monthSummaryPath, query: OrbitEnergyAPI.monthQuery(month))
            summary = reply
            error = nil
        } catch {
            self.error = macEnergyErrorText(error, pcName: vm.selectedPCName)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let error {
            MacNotice(title: "Couldn't read the summary", message: error, icon: "exclamationmark.triangle.fill", tint: .orange)
                .padding(.bottom, 14)
        }
        if let summary {
            if summary.hasPlay {
                filled(summary)
            } else {
                MacEmptyState(icon: summary.available.isEmpty ? "sparkles" : "gamecontroller",
                              title: summary.available.isEmpty ? "Your first summary is on its way" : "No games recorded in \(summary.monthID?.name() ?? "this month")",
                              message: summary.available.isEmpty
                                ? "Play a game while Orbit PC Companion runs on \(vm.selectedPCName). Orbit counts play time, frame rates and temperatures, and your month appears here."
                                : "Orbit PC Companion counts play time while a game runs. Pick another month above.",
                              tint: .orange)
                    .macGlass(cornerRadius: 22, tint: .orange)
            }
        } else if isLoading {
            ProgressView("Putting the month together…").frame(maxWidth: .infinity).padding(.vertical, 80)
        }
    }

    private func filled(_ summary: OrbitMonthSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            hero(summary)
            HStack(alignment: .top, spacing: 14) {
                if let top = summary.topGame { topGameCard(top, summary: summary) }
                recordsCard(summary)
            }
            gamesTable(summary)
            HStack(alignment: .top, spacing: 14) {
                if summary.peakCPUTemp != nil || summary.peakGPUTemp != nil { temperaturesCard(summary) }
                if let energy = summary.energy, energy.kWh > 0 { energyCard(energy) }
                if let previous = summary.previous { versusCard(summary, previous: previous) }
            }
        }
    }

    private func card<Content: View>(_ title: String, icon: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MacSectionHeader(title, icon: icon, tint: tint)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .macGlass(cornerRadius: 20, tint: tint)
    }

    private func hero(_ summary: OrbitMonthSummary) -> some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text((summary.monthID?.title() ?? summary.month).uppercased())
                    .font(.caption.weight(.heavy)).tracking(1.2).foregroundStyle(theme.accent)
                Text(OrbitEnergyFormat.duration(summary.playSeconds))
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white, theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .accessibilityLabel(OrbitEnergyFormat.spokenDuration(summary.playSeconds))
                Text("of play").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                heroStat("\(summary.daysPlayed)", "days played", icon: "calendar.badge.checkmark")
                heroStat("\(summary.sessions)", summary.sessions == 1 ? "session" : "sessions", icon: "play.circle.fill")
                heroStat("\(summary.games.count)", summary.games.count == 1 ? "game" : "games", icon: "gamecontroller.fill")
            }
        }
        .padding(20)
        .macGlass(cornerRadius: 22, tint: theme.accent, elevated: true)
    }

    private func heroStat(_ value: String, _ label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).foregroundStyle(theme.accent).accessibilityHidden(true)
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 110, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func topGameCard(_ top: OrbitMonthSummary.Game, summary: OrbitMonthSummary) -> some View {
        card("Top game", icon: "crown.fill", tint: .orange) {
            Text(top.name).font(.title2.weight(.heavy)).lineLimit(2)
            Text("\(OrbitEnergyFormat.duration(top.playSeconds))\(summary.topGameShare.map { " · \(OrbitEnergyFormat.percent($0)) of your play time" } ?? "")")
                .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                MacStatChip(label: "Days", value: "\(top.daysPlayed)", icon: "calendar")
                if top.averageFPS != nil { MacStatChip(label: "Avg", value: OrbitEnergyFormat.fps(top.averageFPS), icon: "speedometer") }
                if top.peakGPUTemp != nil { MacStatChip(label: "GPU peak", value: OrbitEnergyFormat.temperature(top.peakGPUTemp), icon: "thermometer.high", tint: .red) }
            }
        }
    }

    private func recordsCard(_ summary: OrbitMonthSummary) -> some View {
        card("Records", icon: "trophy.fill", tint: .mint) {
            if let longest = summary.longestSession {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Longest session").font(.caption).foregroundStyle(.secondary)
                    Text(OrbitEnergyFormat.duration(longest.seconds)).font(.title3.weight(.bold))
                    Text("\(longest.name) · \(OrbitEnergyFormat.longDay(longest.date))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let busiest = summary.busiestDay {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Busiest day").font(.caption).foregroundStyle(.secondary)
                    Text(OrbitEnergyFormat.longDay(busiest.day)).font(.title3.weight(.bold))
                    Text("\(OrbitEnergyFormat.duration(busiest.playSeconds)) of play").font(.caption).foregroundStyle(.secondary)
                }
            }
            if summary.longestSession == nil && summary.busiestDay == nil {
                Text("No session lasted a minute yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func gamesTable(_ summary: OrbitMonthSummary) -> some View {
        let hasCost = summary.energy?.currency != nil && summary.games.contains { $0.cost != nil }
        return card("Every game", icon: "list.number", tint: .pink) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Game")
                    Text("Play time").gridColumnAlignment(.trailing)
                    Text("Days").gridColumnAlignment(.trailing)
                    Text("Avg FPS").gridColumnAlignment(.trailing)
                    Text("GPU peak").gridColumnAlignment(.trailing)
                    Text("Energy").gridColumnAlignment(.trailing)
                    if hasCost { Text("Cost").gridColumnAlignment(.trailing) }
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                Divider().opacity(0.4)
                ForEach(summary.games) { game in
                    GridRow {
                        Text(game.name).fontWeight(.semibold).lineLimit(1)
                        Text(OrbitEnergyFormat.duration(game.playSeconds))
                        Text("\(game.daysPlayed)")
                        Text(game.averageFPS.map { "\(Int($0.rounded()))" } ?? "—")
                        Text(OrbitEnergyFormat.temperature(game.peakGPUTemp))
                        Text(OrbitEnergyFormat.energy(game.kWh))
                        if hasCost { Text(OrbitEnergyFormat.cost(game.cost, currency: summary.energy?.currency, kWh: game.kWh)) }
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
    }

    private func temperaturesCard(_ summary: OrbitMonthSummary) -> some View {
        card("Temperatures", icon: "thermometer.medium", tint: .red) {
            HStack(spacing: 8) {
                if summary.peakCPUTemp != nil { MacStatChip(label: "CPU peak", value: OrbitEnergyFormat.temperature(summary.peakCPUTemp), icon: "cpu", tint: .red) }
                if summary.peakGPUTemp != nil { MacStatChip(label: "GPU peak", value: OrbitEnergyFormat.temperature(summary.peakGPUTemp), icon: "thermometer.high", tint: .red) }
            }
            if let hottest = summary.hottestGame, let peak = hottest.peakGPUTemp {
                Text("\(hottest.name) pushed the GPU the hardest, up to \(OrbitEnergyFormat.temperature(peak)).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func energyCard(_ energy: OrbitMonthSummary.Energy) -> some View {
        card("Energy (estimate)", icon: "bolt.fill", tint: .yellow) {
            Text(OrbitEnergyFormat.energy(energy.kWh)).font(.title3.weight(.bold))
            if energy.cost != nil, energy.currency != nil {
                Text("about \(OrbitEnergyFormat.cost(energy.cost, currency: energy.currency, kWh: energy.kWh)) of electricity")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let gaming = energy.gamingKWh, energy.kWh > 0 {
                Text("\(OrbitEnergyFormat.energy(gaming)) while gaming (\(OrbitEnergyFormat.percent(min(1, gaming / energy.kWh))))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func versusCard(_ summary: OrbitMonthSummary, previous: OrbitMonthSummary.Previous) -> some View {
        let name = OrbitMonthID(previous.month)?.name() ?? "last month"
        return card("Versus \(name)", icon: "arrow.left.arrow.right", tint: .purple) {
            if let change = summary.playChange {
                Text(change.sentence(versus: name)).font(.headline).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Your first month with Orbit counting").font(.headline)
            }
            Text("\(OrbitEnergyFormat.duration(previous.playSeconds)) of play in \(name)").font(.caption).foregroundStyle(.secondary)
            if let change = summary.energyChange {
                Text("Energy: \(change.percentText())").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
