import SwiftUI

// Electricity cost and the monthly summary on the Mac: a compact "This Month" card in Sessions (which is
// already behind Orbit Pro) and a Monthly Summary sheet. Models, formatting and demo data are shared with
// the iPhone (`Shared/OrbitEnergy.swift`); the share picture too (`Shared/OrbitSummaryShareCard.swift`).

private struct MacEnergyCapabilities: Decodable {
    var features: [String]?
}

/// An error in plain words: the PC's own sentence, or what to check when it didn't answer. Nil for a
/// cancelled request (the card's task restarted): what's on screen stays.
private func macEnergyErrorText(_ error: Error, pcName: String) -> String? {
    if error is CancellationError { return nil }
    if let orbit = error as? OrbitError { return orbit.message }
    if let url = error as? URLError {
        switch url.code {
        case .cancelled: return nil
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
    @Published private(set) var hasEnergyFeature = false
    private var loadedKey: String?
    private var isLoading = false
    /// The PC's features for `loadedKey` (nil set: an agent older than `/api/capabilities`), read again
    /// after a few minutes or when the card's task restarts (a reconnect can bring a newer agent).
    private var features: (set: Set<String>?, checkedAt: Date)?
    private static let featuresMaxAge: TimeInterval = 300
    /// Failed reads in a row, for the retry backoff.
    private var failures = 0
    private var reloadRequested = false

    /// How long the card waits before reading the PC again.
    var retryDelay: Duration {
        switch phase {
        // The PC writes its energy ledger every minute; the month changes slowly.
        case .ready: return .seconds(120)
        // A newer agent comes with a reconnect, which restarts the card's task anyway.
        case .olderAgent: return .seconds(300)
        // 10, 20, 40, 80 s, then every two minutes.
        case .failed: return .seconds(min(120, 10 << min(4, max(0, failures - 1))))
        case .idle, .loading, .offline: return .seconds(10)
        }
    }

    /// Forgets the PC's features: the card's task restarted (another PC, or the PC came back online).
    func forgetFeatures() { features = nil }

    func load(_ vm: OrbitMacViewModel) async {
        let key = "\(vm.isDemoMode)|\(vm.selectedPCID)|\(vm.generation)"
        if key != loadedKey {
            loadedKey = key
            energy = nil
            summary = nil
            hasSummaryFeature = false
            hasEnergyFeature = false
            features = nil
            failures = 0
            phase = .idle
            isLoading = false
            reloadRequested = false
        }
        if vm.isDemoMode {
            // At the price entered in demo mode (see `OrbitEnergyDemoEdits`).
            energy = OrbitEnergyDemoEdits.energyMonth()
            summary = OrbitEnergyDemoEdits.summary()
            hasSummaryFeature = true
            hasEnergyFeature = true
            phase = .ready
            return
        }
        guard vm.currentPC != nil else { phase = .idle; return }
        guard vm.metrics.isOnline else {
            if energy == nil && summary == nil { phase = .offline }
            return
        }
        // A read already on its way reads once more when it's done (a price saved meanwhile shows at once).
        guard !isLoading else { reloadRequested = true; return }
        isLoading = true
        defer { if key == loadedKey { isLoading = false } }
        repeat {
            reloadRequested = false
            await read(vm, key: key)
        } while reloadRequested && key == loadedKey && !Task.isCancelled
    }

    private func read(_ vm: OrbitMacViewModel, key: String) async {
        if energy == nil && summary == nil { phase = .loading }
        do {
            let client = try vm.client()
            let known: Set<String>?
            if let cached = features, Date().timeIntervalSince(cached.checkedAt) < Self.featuresMaxAge {
                known = cached.set
            } else {
                do {
                    let reply: MacEnergyCapabilities = try await client.get("/api/capabilities")
                    known = Set(reply.features ?? [])
                } catch let error as OrbitError where error.statusCode == 404 {
                    known = nil
                }
                guard key == loadedKey, !Task.isCancelled else { return }
                features = (known, Date())
            }
            let hasEnergy = known?.contains(OrbitEnergyAPI.energyFeature) ?? false
            let hasSummary = known?.contains(OrbitEnergyAPI.summaryFeature) ?? false
            guard hasEnergy || hasSummary else { phase = .olderAgent; failures = 0; return }
            hasSummaryFeature = hasSummary
            hasEnergyFeature = hasEnergy
            async let energyReply = Self.fetch(OrbitEnergyMonth.self, from: client, OrbitEnergyAPI.energySummaryPath, when: hasEnergy)
            async let summaryReply = Self.fetch(OrbitMonthSummary.self, from: client, OrbitEnergyAPI.monthSummaryPath, when: hasSummary)
            let (newEnergy, newSummary) = try await (energyReply, summaryReply)
            guard key == loadedKey, !Task.isCancelled else { return }
            energy = newEnergy
            summary = newSummary
            failures = 0
            phase = .ready
        } catch {
            // Cancelled with the card's task (the PC went offline, another PC): the restarted task decides.
            guard key == loadedKey, !Task.isCancelled, let message = macEnergyErrorText(error, pcName: vm.selectedPCName) else { return }
            failures += 1
            if energy == nil && summary == nil { phase = .failed(message) }
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
    /// The price the editor opened with (kept while the card reads the PC again behind it).
    @State private var editingPrice: OrbitEnergyPrice?

    private var pcName: String { vm.selectedPCName }
    /// The PC's price, from this month's report (the same object as `GET /api/energy/price`).
    private var price: OrbitEnergyPrice? { model.energy?.price }
    private var canSetPrice: Bool { model.phase == .ready && model.hasEnergyFeature && price != nil && (vm.isDemoMode || vm.metrics.isOnline) }

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
            if canSetPrice {
                Button {
                    editingPrice = price
                } label: {
                    Label(price?.hasPrice == true ? "Price…" : "Set Price…", systemImage: "pencil")
                }
                .buttonStyle(MacHoverButtonStyle(tint: .yellow))
                .help(price?.hasPrice == true ? "Change the electricity price Orbit uses for \(pcName)" : "Enter your electricity price to see what \(pcName) costs to run")
            }
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
            // Another PC, or the PC came back (perhaps with a newer agent): read its features again.
            model.forgetFeatures()
            while !Task.isCancelled {
                await model.load(vm)
                do { try await Task.sleep(for: model.retryDelay) } catch { break }
            }
        }
        .sheet(isPresented: $showsSummary) {
            MacMonthlySummarySheet(initial: model.summary)
                .environmentObject(vm)
                .macAppearance()
        }
        .sheet(isPresented: Binding(get: { editingPrice != nil }, set: { if !$0 { editingPrice = nil } })) {
            if let editingPrice {
                MacEnergyPriceSheet(price: editingPrice) {
                    // Costs follow the new price (a new currency re-prices the month), so read it again.
                    await model.load(vm)
                }
                .environmentObject(vm)
                .macAppearance()
            }
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
                    MacStatChip(label: "Cost", value: OrbitEnergyFormat.cost(energy.cost, currency: energy.currency, kWh: energy.kWh,
                                                                             pricePerKWh: energy.price?.pricePerKWh),
                                icon: "bolt.fill", tint: .yellow)
                } else {
                    MacStatChip(label: "Cost", value: "No price yet", icon: "bolt.fill", tint: .yellow)
                        .help("Orbit has no electricity price for this PC's country. Click Set Price… to enter the one on your bill.")
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

// MARK: - Electricity price sheet

/// The Mac's "Change price": the person's own price per kWh and its currency, or back to the published
/// average (`PUT /api/energy/price`, the same body as the iPhone's editor). Demo mode keeps it in memory.
struct MacEnergyPriceSheet: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.dismiss) private var dismiss
    let price: OrbitEnergyPrice
    let onSaved: () async -> Void
    @State private var text: String
    @State private var currency: String
    @State private var error: String?
    @State private var isSaving = false
    @FocusState private var priceFocused: Bool

    init(price: OrbitEnergyPrice, onSaved: @escaping () async -> Void) {
        self.price = price
        self.onSaved = onSaved
        _text = State(initialValue: price.pricePerKWh.map { $0.formatted(.number.precision(.fractionLength(0...4)).grouping(.never)) } ?? "")
        let fallback = Locale.current.currency?.identifier ?? "EUR"
        _currency = State(initialValue: (price.currency ?? price.defaultPrice?.currency ?? fallback).uppercased())
    }

    private var pcName: String { vm.selectedPCName }
    private var parsedPrice: Double? { OrbitEnergyPriceChange.parse(text) }
    private var isValid: Bool { parsedPrice.map { OrbitEnergyPriceChange.isValid(price: $0, currency: currency) } ?? false }

    /// Suggestions first (the PC's currency, its country's, this Mac's), then every other offered currency.
    private var suggested: [String] {
        var codes: [String] = []
        for code in [price.currency, price.defaultPrice?.currency, Locale.current.currency?.identifier, "EUR", "USD", "GBP"] {
            if let code = code?.uppercased(), code.count == 3, OrbitEnergyPriceChange.offeredCurrencies.contains(code), !codes.contains(code) { codes.append(code) }
        }
        if !codes.contains(currency) { codes.insert(currency, at: 0) }
        return codes
    }

    private static let all: [String] = OrbitEnergyPriceChange.offeredCurrencies
        .sorted { OrbitEnergyFormat.currencyName($0) < OrbitEnergyFormat.currencyName($1) }

    /// What Save would store, written out with the currency, so a mistyped mark shows before it's saved.
    private var preview: (text: String, isProblem: Bool)? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let value = parsedPrice else { return ("Enter the price as a number, for example 1.07.", true) }
        guard OrbitEnergyPriceChange.priceRange.contains(value) else {
            return ("Orbit accepts prices up to \(OrbitEnergyPriceChange.priceRange.upperBound.formatted(.number.precision(.fractionLength(0)))) per kWh.", true)
        }
        return ("Saves as \(OrbitEnergyFormat.unitPrice(value, currency: currency)) per kWh.", false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MacIconBadge(systemName: "bolt.fill", tint: .yellow, size: 36, filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Electricity Price").font(.title2.weight(.bold))
                    Text(vm.isDemoMode ? "Demo mode · sample PC" : pcName).font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let current = OrbitEnergyFormat.pricePerKWh(price) {
                    Text("Now: \(current)").font(.callout.weight(.semibold))
                }
                Text(OrbitEnergyFormat.sourceExplanation(price))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Your price per kWh").font(.headline)
                HStack(spacing: 10) {
                    TextField("Price", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3.monospacedDigit())
                        .frame(width: 150)
                        .focused($priceFocused)
                        .onSubmit { if isValid, !isSaving { save() } }
                        .accessibilityLabel("Price per kilowatt hour")
                    Picker("Currency", selection: $currency) {
                        Section("Suggested") {
                            ForEach(suggested, id: \.self) { Text(OrbitEnergyFormat.currencyName($0)).tag($0) }
                        }
                        Section("All currencies") {
                            ForEach(Self.all.filter { !suggested.contains($0) }, id: \.self) { Text(OrbitEnergyFormat.currencyName($0)).tag($0) }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                    .accessibilityLabel("Currency")
                    Text("per kWh").foregroundStyle(.secondary)
                }
                if let preview {
                    Text(preview.text)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(preview.isProblem ? Color.orange : Color.secondary)
                }
                Text("Use the price on your electricity bill, with taxes and fees included. The new price counts from now on: days already recorded keep their price, unless you pick another currency, which shows the whole history at this price.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if price.isOverride, let detected = price.detectedPrice, let value = detected.pricePerKWh, let detectedCurrency = detected.currency {
                HStack(spacing: 10) {
                    Button {
                        save(.resetToDetected)
                    } label: {
                        Label("Use the Published Average", systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(MacHoverButtonStyle(tint: .green))
                    .disabled(isSaving)
                    Text("\(OrbitEnergyFormat.unitPrice(value, currency: detectedCurrency)) per kWh · \(detected.source ?? "Published average")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(MacHoverButtonStyle(tint: .white))
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(MacHoverButtonStyle(tint: .yellow, prominent: true))
                    .disabled(!isValid || isSaving)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(MacAmbientBackground(isOnline: true))
        .onAppear { priceFocused = true }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        guard let value = parsedPrice else { return }
        save(.set(value, currency: currency))
    }

    private func save(_ change: OrbitEnergyPriceChange) {
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            if vm.isDemoMode {
                OrbitEnergyDemoEdits.apply(change)
            } else {
                do {
                    let _: OrbitEnergyPrice = try await vm.client().send(OrbitEnergyAPI.pricePath, method: "PUT", body: change)
                } catch {
                    self.error = macEnergyErrorText(error, pcName: pcName) ?? "Not saved. Try again."
                    return
                }
            }
            await onSaved()
            dismiss()
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
        // Only a small preview is drawn here; the full picture is drawn when the person picks where it goes.
        .task(id: pictureKey) {
            guard let summary, summary.hasPlay else { picture = nil; return }
            picture = OrbitSummaryPicture.make(summary, accent: theme.accent, secondary: theme.secondary)
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
                ShareLink(item: picture, preview: SharePreview("\(summary.monthID?.title() ?? summary.month) in games", image: picture.preview)) {
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
            summary = OrbitEnergyDemoEdits.summary(month)
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
                                // The month picker is in the header only when there is another month to pick.
                                : "Orbit PC Companion counts play time while a game runs." + (months.count > 1 ? " Pick another month above." : " Come back after a gaming session."),
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
                if let energy = summary.energy, energy.kWh > 0 { energyCard(energy, summary: summary) }
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
                        if hasCost { Text(OrbitEnergyFormat.cost(game.cost, currency: summary.energy?.currency, kWh: game.kWh, pricePerKWh: summary.averagePricePerKWh)) }
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

    private func energyCard(_ energy: OrbitMonthSummary.Energy, summary: OrbitMonthSummary) -> some View {
        card("Energy (estimate)", icon: "bolt.fill", tint: .yellow) {
            Text(OrbitEnergyFormat.energy(energy.kWh)).font(.title3.weight(.bold))
            if energy.cost != nil, energy.currency != nil {
                Text("\(OrbitEnergyFormat.approximateCost(energy.cost, currency: energy.currency, kWh: energy.kWh, pricePerKWh: summary.averagePricePerKWh)) of electricity")
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
            if let headline = summary.versusHeadline(previousName: name) {
                Text(headline).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            Text("\(OrbitEnergyFormat.duration(previous.playSeconds)) of play in \(name)").font(.caption).foregroundStyle(.secondary)
            if let change = summary.energyChange {
                Text("Energy: \(change.percentText())").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
