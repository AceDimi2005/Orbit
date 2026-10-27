import Charts
import SwiftUI

// MARK: - Model

/// What the Electricity Cost screen shows for one PC: the month's estimate (`/api/energy/summary`), the price
/// (`/api/energy/price`) and the estimate settings (`/api/energy/settings`). Demo mode uses sample data and
/// never calls a PC.
@MainActor
final class OrbitEnergyModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// The PC answered; `report` may still be nil (the ledger isn't running), see `reportError`.
        case ready
        /// The PC's agent predates electricity cost (no "energy" in `/api/capabilities`, or a 404).
        case olderAgent
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report: OrbitEnergyMonth?
    @Published private(set) var reportError: String?
    @Published private(set) var price: OrbitEnergyPrice?
    @Published private(set) var settings: OrbitEnergySettings?
    @Published private(set) var settingsError: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isSavingSettings = false
    /// The PC's own current month, learned from the first report (the phone's clock may disagree).
    @Published private(set) var currentMonth: OrbitMonthID?
    /// The month on screen; nil follows the PC's current month.
    @Published private(set) var selectedMonth: OrbitMonthID?
    /// The months the PC has readings for, from the last report (kept while another month loads or fails,
    /// so the picker stays).
    @Published private(set) var knownMonths: [String] = []
    @Published var notice: String?
    @Published private(set) var isConfigured = false
    private(set) var link: OrbitPCLink?
    private(set) var isDemo = false
    private var generation = 0
    /// The newest `load()`; an older one still on its way is dropped (a month picked during a refresh).
    private var loadToken = 0
    private var settingsTask: Task<Void, Never>?

    var shownMonth: OrbitMonthID? { selectedMonth ?? report?.monthID ?? currentMonth }
    var isCurrentMonth: Bool { shownMonth != nil && shownMonth == currentMonth }
    var pickerMonths: [OrbitMonthID] { OrbitMonthID.pickerMonths(available: report?.available ?? knownMonths, including: shownMonth) }

    func configure(_ vm: OrbitViewModel) {
        let newLink = OrbitPCLink.current(vm)
        if isConfigured, vm.isDemoMode == isDemo, newLink?.id == link?.id, (newLink == nil) == (link == nil) {
            link = newLink
            return
        }
        generation += 1
        settingsTask?.cancel()
        isConfigured = true
        isDemo = vm.isDemoMode
        link = newLink
        phase = .idle
        report = nil; reportError = nil
        price = nil; settings = nil; settingsError = nil
        currentMonth = nil; selectedMonth = nil; knownMonths = []
        notice = nil; isLoading = false; isSavingSettings = false
        if isDemo { loadDemo() }
    }

    private func loadDemo() {
        let month = OrbitEnergyDemo.energyMonth(selectedMonth)
        report = month
        knownMonths = month.available
        currentMonth = OrbitMonthID.containing(Date())
        if price == nil { price = OrbitEnergyDemo.price }
        if settings == nil { settings = OrbitEnergyDemo.settings }
        phase = .ready
    }

    func load() async {
        if isDemo { loadDemo(); return }
        guard let link else { return }
        loadToken += 1
        let token = loadToken
        let version = generation
        isLoading = true
        defer { if token == loadToken { isLoading = false } }
        do {
            let features = try await OrbitFeatureStore.shared.features(for: link, maxAge: 60)
            guard version == generation, token == loadToken else { return }
            guard features.has(OrbitEnergyAPI.energyFeature) else { phase = .olderAgent; return }
        } catch {
            guard version == generation, token == loadToken else { return }
            // Keep what's on screen after a hiccup; only an empty screen shows the failure.
            if report == nil && price == nil { phase = .failed(OrbitPlainError.describe(error)) }
            return
        }
        let client = link.client
        let month = selectedMonth
        async let reportResult = Self.result { () async throws -> OrbitEnergyMonth in
            try await client.get(OrbitEnergyAPI.energySummaryPath, query: OrbitEnergyAPI.monthQuery(month))
        }
        async let priceResult = Self.result { () async throws -> OrbitEnergyPrice in try await client.get(OrbitEnergyAPI.pricePath) }
        async let settingsResult = Self.result { () async throws -> OrbitEnergySettings in try await client.get(OrbitEnergyAPI.settingsPath) }
        let (newReport, newPrice, newSettings) = await (reportResult, priceResult, settingsResult)
        guard version == generation, token == loadToken, month == selectedMonth else { return }
        switch newReport {
        case .success(let value):
            report = value
            reportError = nil
            knownMonths = value.available
            if month == nil { currentMonth = value.monthID }
            if let embedded = value.price, case .failure = newPrice { price = embedded }
        case .failure(let error):
            reportError = OrbitPlainError.describe(error)
        }
        if case .success(let value) = newPrice { price = value }
        // A settings save on its way would otherwise be read back as the old values.
        if case .success(let value) = newSettings, settingsTask == nil { settings = value }
        if case .failure(let error) = newReport, case .failure = newPrice, report == nil {
            phase = .failed(OrbitPlainError.describe(error))
        } else {
            phase = .ready
        }
    }

    private static func result<T>(_ work: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    func select(_ month: OrbitMonthID) async {
        guard month != shownMonth else { return }
        // Picking the PC's own month follows it again (so "Today" keeps showing).
        selectedMonth = month == currentMonth ? nil : month
        if isDemo {
            report = OrbitEnergyDemo.energyMonth(month)
            return
        }
        report = nil
        reportError = nil
        await load()
    }

    /// Saves the user's price (or goes back to the detected one). Returns a sentence when it failed.
    func savePrice(_ change: OrbitEnergyPriceChange) async -> String? {
        if isDemo {
            var updated = price ?? OrbitEnergyDemo.price
            if change.reset == true {
                updated = OrbitEnergyDemo.price
            } else if let value = change.pricePerKWh, let currency = change.currency {
                updated.pricePerKWh = value
                updated.currency = currency
                updated.source = "Your own price"
                updated.period = nil
                updated.isOverride = true
            }
            price = updated
            notice = "Demo mode: nothing was sent to a PC."
            return nil
        }
        guard let link else { return "Connect to your PC to change its price." }
        let version = generation
        do {
            let saved: OrbitEnergyPrice = try await link.client.send(OrbitEnergyAPI.pricePath, method: "PUT", body: change)
            guard version == generation else { return nil }
            price = saved
            OrbitHaptics.success()
            // Costs follow the new price (rows in another currency are re-priced), so read the month again.
            await load()
            return nil
        } catch {
            return OrbitPlainError.describe(error)
        }
    }

    /// Changes the estimate settings on screen at once and saves them on the PC 600 ms after the last change.
    func updateSettings(_ newValue: OrbitEnergySettings) {
        let value = newValue.normalized
        settings = value
        settingsError = nil
        if isDemo {
            notice = "Demo mode: nothing was sent to a PC."
            return
        }
        guard let link else { return }
        let version = generation
        settingsTask?.cancel()
        isSavingSettings = true
        settingsTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            let change = OrbitEnergySettingsChange(baseWatts: value.baseWatts, psuEfficiency: value.psuEfficiency)
            let result: Result<OrbitEnergySettings, Error>
            do { result = .success(try await link.client.send(OrbitEnergyAPI.settingsPath, method: "PUT", body: change)) }
            catch { result = .failure(error) }
            guard let self, version == self.generation, !Task.isCancelled else { return }
            self.isSavingSettings = false
            self.settingsTask = nil
            switch result {
            case .success(let saved): self.settings = saved
            case .failure(let error): self.settingsError = "Not saved on the PC. \(OrbitPlainError.describe(error))"
            }
        }
    }
}

// MARK: - Screen

/// Electricity Cost opened over the whole app (`orbit://energy`), with a Done button and the Pro check.
struct EnergyCostSheet: View {
    @ObservedObject var vm: OrbitViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            OrbitProGate(title: "Electricity Cost", message: EnergyCostView.proMessage) {
                EnergyCostView(vm: vm)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .orbitAppearance()
    }
}

struct EnergyCostView: View {
    static let proMessage = "What your PC costs to run each month, estimated from its power sensors and your electricity price, is part of Orbit Pro."

    @ObservedObject var vm: OrbitViewModel
    @StateObject private var model = OrbitEnergyModel()
    @State private var metric: Metric = .cost
    @State private var selectedDate: Date?
    @State private var showsPriceEditor = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.orbitTheme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum Metric: String, CaseIterable, Identifiable {
        case cost = "Cost", energy = "kWh"
        var id: String { rawValue }
    }

    private var pcName: String { vm.isDemoMode ? vm.metrics.hostname : vm.selectedPCName }
    private var canEdit: Bool { model.isDemo || (vm.metrics.isOnline && model.link != nil && model.phase == .ready) }
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)] }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                notices
                if let report = model.report {
                    heroCard(report)
                    if report.hasReadings {
                        chartCard(report).id("chart")
                    }
                } else if let error = model.reportError, model.phase == .ready {
                    OrbitNotice(title: "Can't show \(model.shownMonth?.title() ?? "this month")", message: error, icon: "exclamationmark.triangle.fill", tint: .orange)
                    if model.pickerMonths.count > 1 {
                        HStack {
                            Text("Pick another month").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            monthMenu
                        }
                    }
                } else if model.isLoading || (model.phase == .idle && model.link != nil && vm.metrics.isOnline) {
                    loadingCard
                }
                if model.phase == .ready || model.isDemo {
                    LazyVGrid(columns: sizeClass == .regular ? columns : [GridItem(.flexible())], alignment: .leading, spacing: 14) {
                        if let report = model.report, report.hasReadings { gamesCard(report).id("games") }
                        priceCard.id("price")
                        settingsCard.id("settings")
                        aboutCard.id("about")
                    }
                }
            }
            .frame(maxWidth: 1000)
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(OrbitAmbientBackground(isOnline: vm.metrics.isOnline))
        .navigationTitle("Electricity Cost")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .task(id: vm.connectionID) {
            model.configure(vm)
            while !Task.isCancelled {
                // The PC writes its energy ledger every minute.
                if scenePhase == .active, vm.metrics.isOnline || model.isDemo { await model.load() }
                do { try await Task.sleep(for: .seconds(model.phase == .ready ? 60 : 5)) } catch { break }
            }
        }
        .onChange(of: model.report?.month) { _, _ in selectedDate = nil }
        #if DEBUG
        // `ORBIT_SELFTEST_SCROLL=chart|games|price|settings|about` and `ORBIT_SELFTEST_PRICE_EDITOR=1`:
        // screenshots of the lower cards and the editor without taps.
        .modifier(OrbitSelfTestScroll())
        .task {
            guard ProcessInfo.processInfo.environment["ORBIT_SELFTEST_PRICE_EDITOR"] != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            if model.price != nil { showsPriceEditor = true }
        }
        #endif
        .sheet(isPresented: $showsPriceEditor) {
            if let price = model.price {
                NavigationStack {
                    EnergyPriceEditorView(price: price, pcName: pcName) { change in await model.savePrice(change) }
                }
                .orbitAppearance()
            }
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        if vm.isDemoMode {
            OrbitNotice(title: "Demo mode", message: "Sample numbers for a gaming PC in Romania. Nothing is sent to a PC.", icon: "sparkles", tint: .orange)
        } else if vm.savedPCs.isEmpty || !vm.isConfigured {
            OrbitNotice(title: "Pair a PC first", message: "Find and pair your PC in My PCs to see what it costs to run.", icon: "desktopcomputer", tint: .orange)
        } else if !vm.hasSecureConnection || (model.isConfigured && model.link == nil) {
            OrbitNotice(title: "Needs the encrypted connection", message: "Pair \(pcName) again in My PCs to see its electricity cost.", icon: "lock.trianglebadge.exclamationmark", tint: .orange)
        } else if !vm.metrics.isOnline {
            OrbitNotice(title: "\(pcName) is offline", message: model.report == nil
                        ? "Wake it to see its electricity cost. It keeps counting whenever Orbit PC Companion runs."
                        : "Showing the last numbers Orbit read. They update when the PC is back.", icon: "wifi.slash", tint: .orange)
        } else if model.phase == .olderAgent {
            OrbitNotice(title: "Update Orbit PC Companion", message: "\(pcName) runs an older agent without electricity cost. Update it from Settings › Check for PC Companion Update.", icon: "arrow.down.circle.fill", tint: .orange)
        } else if case .failed(let message) = model.phase {
            OrbitNotice(title: "Couldn't reach \(pcName)", message: message, icon: "exclamationmark.triangle.fill", tint: .orange)
        }
        if let notice = model.notice {
            Text(notice).font(.caption).foregroundStyle(.orange)
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Reading \(pcName)'s energy use…").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 22, tint: .yellow)
    }

    // MARK: Hero

    private func heroCard(_ report: OrbitEnergyMonth) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                OrbitIconBadge(systemName: "bolt.fill", tint: .yellow, size: 40, filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isCurrentMonth ? "This month so far" : (report.monthID?.title() ?? report.month))
                        .font(.headline.weight(.bold))
                    Text(pcName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                monthMenu
            }
            if report.hasReadings {
                heroNumbers(report)
            } else {
                OrbitEmptyState(icon: "bolt.slash", title: "No readings for \(report.monthID?.name() ?? "this month")",
                                message: "Orbit PC Companion counts energy while it runs on \(pcName). Check back after you've used the PC for a while.",
                                tint: .yellow)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 24, tint: .yellow, elevated: true)
    }

    @ViewBuilder
    private func heroNumbers(_ report: OrbitEnergyMonth) -> some View {
        let hasCost = report.cost != nil && report.currency != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(hasCost ? OrbitEnergyFormat.cost(report.cost, currency: report.currency, kWh: report.kWh) : OrbitEnergyFormat.energy(report.kWh))
                    .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                OrbitStatusPill(text: "Estimate", tint: .yellow, icon: "info.circle.fill")
            }
            Text(hasCost ? "\(OrbitEnergyFormat.energy(report.kWh)) · \(trackedText(report))" : trackedText(report))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heroAccessibility(report))
        if !hasCost {
            Button {
                showsPriceEditor = true
            } label: {
                Label("Add your electricity price to see the cost", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(OrbitGlassButtonStyle(tint: .yellow))
            .disabled(!canEdit || model.price == nil)
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { heroChips(report) }
            VStack(alignment: .leading, spacing: 8) { heroChips(report) }
        }
        Text("Estimated from the CPU and GPU power \(pcName) reports, plus the rest of the PC and power supply losses, at the price below. Your bill also includes monitors, other devices and standby, so it will be higher.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func heroChips(_ report: OrbitEnergyMonth) -> some View {
        if model.isCurrentMonth, let today = report.today {
            OrbitStatChip(label: "Today", value: amountText(kWh: today.kWh, cost: today.cost, currency: report.currency), tint: .yellow, icon: "sun.max.fill")
        }
        if let average = report.averageDailyKWh, report.days.count > 1 {
            OrbitStatChip(label: "Per day", value: OrbitEnergyFormat.energy(average), icon: "calendar")
        }
        if report.gamingHours > 0 {
            OrbitStatChip(label: "Gaming", value: OrbitEnergyFormat.hours(report.gamingHours), icon: "gamecontroller.fill")
        }
    }

    private func trackedText(_ report: OrbitEnergyMonth) -> String {
        guard let hours = report.trackedHours, hours > 0 else { return "no tracked time yet" }
        return "\(OrbitEnergyFormat.hours(hours)) tracked"
    }

    private func amountText(kWh: Double, cost: Double?, currency: String?) -> String {
        guard cost != nil, currency != nil else { return OrbitEnergyFormat.energy(kWh) }
        return "\(OrbitEnergyFormat.energy(kWh)) · \(OrbitEnergyFormat.cost(cost, currency: currency, kWh: kWh))"
    }

    private func heroAccessibility(_ report: OrbitEnergyMonth) -> String {
        var parts = ["Estimated"]
        if report.cost != nil, report.currency != nil { parts.append("cost \(OrbitEnergyFormat.cost(report.cost, currency: report.currency, kWh: report.kWh))") }
        parts.append("energy \(OrbitEnergyFormat.energy(report.kWh).replacingOccurrences(of: "kWh", with: "kilowatt hours"))")
        parts.append(trackedText(report).replacingOccurrences(of: " h ", with: " hours "))
        return parts.joined(separator: ", ")
    }

    private var monthMenu: some View {
        Menu {
            ForEach(model.pickerMonths) { month in
                Button {
                    OrbitHaptics.selection()
                    Task { await model.select(month) }
                } label: {
                    if month == model.shownMonth {
                        Label(month.title(), systemImage: "checkmark")
                    } else {
                        Text(month.title())
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.shownMonth?.shortTitle() ?? "Month")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.yellow.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.yellow.opacity(0.25), lineWidth: 1))
            .foregroundStyle(.yellow)
        }
        .disabled(model.pickerMonths.count < 2 && model.shownMonth != nil)
        .accessibilityLabel("Month")
        .accessibilityValue(model.shownMonth?.title() ?? "")
        .accessibilityHint("Shows the estimate for another month")
    }

    // MARK: Daily chart

    private struct ChartDay: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let label: String
    }

    private func chartDays(_ report: OrbitEnergyMonth, metric: Metric) -> [ChartDay] {
        report.days.compactMap { day in
            guard let date = OrbitEnergyFormat.date(fromDay: day.day) else { return nil }
            switch metric {
            case .cost:
                return ChartDay(id: day.day, date: date, value: day.cost ?? 0,
                                label: OrbitEnergyFormat.cost(day.cost ?? 0, currency: report.currency, kWh: day.kWh))
            case .energy:
                return ChartDay(id: day.day, date: date, value: day.kWh, label: OrbitEnergyFormat.energy(day.kWh))
            }
        }
    }

    private func chartCard(_ report: OrbitEnergyMonth) -> some View {
        let hasCost = report.cost != nil && report.currency != nil
        let shownMetric: Metric = hasCost ? metric : .energy
        let days = chartDays(report, metric: shownMetric)
        let selected = selectedDate.flatMap { date in days.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }
        let todayID = model.isCurrentMonth ? report.days.last?.day : nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                OrbitSectionHeader("Day by day", icon: "chart.bar.fill", tint: .yellow)
                if hasCost {
                    Picker("Show", selection: $metric) {
                        ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 150)
                }
            }
            Chart {
                ForEach(days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value(shownMetric.rawValue, day.value))
                        .foregroundStyle(barStyle(isToday: day.id == todayID, isSelected: day.id == selected?.id))
                        .cornerRadius(3)
                        .accessibilityLabel(OrbitEnergyFormat.longDay(day.id))
                        .accessibilityValue(day.label)
                }
                if let selected {
                    RuleMark(x: .value("Selected day", selected.date, unit: .day))
                        .foregroundStyle(.white.opacity(0.18))
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            VStack(spacing: 2) {
                                Text(selected.label).font(.caption.weight(.bold)).monospacedDigit()
                                Text(OrbitEnergyFormat.shortDay(selected.id)).font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(7)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartXSelection(value: $selectedDate)
            .frame(height: 210)
            .accessibilityLabel("Daily \(shownMetric == .cost ? "cost" : "energy") for \(report.monthID?.title() ?? report.month)")
            if let peak = report.peakDay {
                Text("Highest: \(OrbitEnergyFormat.longDay(peak.day)), \(amountText(kWh: peak.kWh, cost: peak.cost, currency: report.currency)). Drag across the chart to see any day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 22, tint: .yellow)
    }

    private func barStyle(isToday: Bool, isSelected: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.white) }
        if isToday { return AnyShapeStyle(Color.yellow.opacity(0.55)) }
        return AnyShapeStyle(LinearGradient(colors: [Color.yellow, Color.orange], startPoint: .top, endPoint: .bottom))
    }

    // MARK: Games

    private func gamesCard(_ report: OrbitEnergyMonth) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            OrbitSectionHeader("By game", icon: "gamecontroller.fill", tint: .orange)
            if report.games.isEmpty {
                Text("No games ran this month. Everything below was the desktop, videos and idle time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(report.games) { game in
                usageRow(title: game.name, detail: OrbitEnergyFormat.hours(game.hours) + " played",
                         kWh: game.kWh, cost: game.cost, currency: report.currency, total: report.kWh, tint: .orange)
            }
            usageRow(title: "Desktop & everything else", detail: "Apps, videos and idle time",
                     kWh: report.otherKWh, cost: report.currency == nil ? nil : report.otherCost, currency: report.currency,
                     total: report.kWh, tint: .gray)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 22, tint: .orange)
    }

    private func usageRow(title: String, detail: String, kWh: Double, cost: Double?, currency: String?, total: Double, tint: Color) -> some View {
        let share = total > 0 ? min(1, kWh / total) : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(cost != nil && currency != nil ? OrbitEnergyFormat.cost(cost, currency: currency, kWh: kWh) : OrbitEnergyFormat.energy(kWh))
                        .font(.subheadline.weight(.bold)).monospacedDigit()
                    if cost != nil && currency != nil {
                        Text(OrbitEnergyFormat.energy(kWh)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.07))
                    Capsule().fill(tint.opacity(0.8)).frame(width: max(4, proxy.size.width * share))
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(OrbitEnergyFormat.percent(share)) of the month")
    }

    // MARK: Price

    private var priceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                OrbitSectionHeader("Electricity price", icon: "dollarsign.circle.fill", tint: .green)
                if model.price?.isOverride == true { OrbitStatusPill(text: "Your price", tint: .green) }
            }
            if let price = model.price {
                if let text = OrbitEnergyFormat.pricePerKWh(price) {
                    Text(text)
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                } else {
                    Text("No price yet")
                        .font(.title3.weight(.bold))
                }
                if let country = OrbitEnergyFormat.countryName(price.country) {
                    Label {
                        Text("\(country), from the region set in Windows")
                    } icon: {
                        Text(OrbitEnergyFormat.flag(price.country))
                    }
                    .font(.caption.weight(.semibold))
                } else {
                    Label("No country set in Windows (Settings › Time & language › Language & region)", systemImage: "globe")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(OrbitEnergyFormat.sourceExplanation(price))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !price.isOverride, let source = price.source {
                    Text("Source: \(source)").font(.caption2).foregroundStyle(.secondary)
                }
                if price.isOverride, let detected = price.detectedPrice, let value = detected.pricePerKWh, let currency = detected.currency {
                    Text("Published average: \(OrbitEnergyFormat.unitPrice(value, currency: currency)) per kWh\(OrbitEnergyFormat.period(detected.period).map { " (\($0))" } ?? "")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    OrbitHaptics.tap()
                    showsPriceEditor = true
                } label: {
                    Label(price.hasPrice ? "Change Price" : "Set Your Price", systemImage: "pencil")
                }
                .buttonStyle(OrbitGlassButtonStyle(tint: .green))
                .disabled(!canEdit)
            } else if model.isLoading {
                HStack(spacing: 10) { ProgressView(); Text("Reading the price…").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("The price shows up when \(pcName) answers.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 22, tint: .green)
    }

    // MARK: Estimate settings

    private func settingsBinding<T>(_ keyPath: WritableKeyPath<OrbitEnergySettings, T>) -> Binding<T> {
        Binding(
            get: { (model.settings ?? .defaults)[keyPath: keyPath] },
            set: { value in
                var settings = model.settings ?? .defaults
                settings[keyPath: keyPath] = value
                OrbitHaptics.selection()
                model.updateSettings(settings)
            }
        )
    }

    private var settingsCard: some View {
        let settings = model.settings ?? .defaults
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                OrbitSectionHeader("How Orbit estimates", icon: "slider.horizontal.3", tint: .cyan)
                if model.isSavingSettings { ProgressView().controlSize(.mini) }
            }
            Stepper(value: settingsBinding(\.baseWatts), in: OrbitEnergySettings.baseWattsRange, step: 5) {
                LabeledContent("Rest of the PC", value: "\(Int(settings.baseWatts.rounded())) W")
            }
            .accessibilityValue("\(Int(settings.baseWatts.rounded())) watts")
            Text("Power the sensors don't report: motherboard, memory, drives, fans and lights. Most gaming PCs use 40–80 W for these.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.4)
            Stepper(value: settingsBinding(\.psuEfficiency), in: OrbitEnergySettings.efficiencyRange, step: 0.01) {
                LabeledContent("Power supply efficiency", value: OrbitEnergyFormat.percent(settings.psuEfficiency))
            }
            .accessibilityValue(OrbitEnergyFormat.efficiencyLabel(settings.psuEfficiency))
            Text("The power supply turns some electricity into heat. At \(OrbitEnergyFormat.efficiencyLabel(settings.psuEfficiency)), the PC draws \(OrbitEnergyFormat.percent(max(0, 1 / max(settings.psuEfficiency, 0.5) - 1))) more from the wall than its parts use.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.settingsError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Text("Saved on \(pcName). Changes apply to new readings; days already counted keep their estimate.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .disabled(!canEdit || model.settings == nil)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 22, tint: .cyan)
    }

    // MARK: About

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            OrbitSectionHeader("About this estimate", icon: "info.circle.fill", tint: .purple)
            Text("Every few seconds Orbit adds up the CPU and GPU power the PC reports, adds the rest of the PC, divides by the power supply efficiency and multiplies by the price per kWh.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let report = model.report, let breakdown = report.breakdown, breakdown.total > 0 {
                breakdownBar(breakdown)
            }
            if let coverage = model.report?.coverage {
                Label("Power sensors answered \(OrbitEnergyFormat.percent(coverage)) of the time\(coverage < 0.9 ? "; the rest counts only the rest of the PC, so the estimate is low" : "").",
                      systemImage: coverage < 0.9 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(coverage < 0.9 ? .orange : .secondary)
            }
            Text("Not counted: monitors, speakers, the time the PC sleeps or is off, and anything while Orbit PC Companion isn't running.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 22, tint: .purple)
    }

    private struct BreakdownPart: Identifiable {
        let id: String
        let kWh: Double
        let color: Color
    }

    private func breakdownBar(_ breakdown: OrbitEnergyMonth.Breakdown) -> some View {
        let parts = [BreakdownPart(id: "GPU", kWh: breakdown.gpuKWh, color: .purple),
                     BreakdownPart(id: "CPU", kWh: breakdown.cpuKWh, color: .cyan),
                     BreakdownPart(id: "Rest of the PC", kWh: breakdown.baseKWh, color: .gray),
                     BreakdownPart(id: "Power supply losses", kWh: breakdown.lossKWh, color: .orange)]
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(parts.filter { $0.kWh > 0 }) { part in
                        Rectangle().fill(part.color).frame(width: max(3, proxy.size.width * part.kWh / breakdown.total - 2))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            ForEach(parts) { part in
                HStack(spacing: 8) {
                    Circle().fill(part.color).frame(width: 7, height: 7)
                    Text(part.id).font(.caption)
                    Spacer()
                    Text(OrbitEnergyFormat.energy(part.kWh)).font(.caption.weight(.semibold)).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Price editor

/// "Change price": the person's own price per kWh and its currency, or back to the published average.
struct EnergyPriceEditorView: View {
    let price: OrbitEnergyPrice
    let pcName: String
    let onSave: (OrbitEnergyPriceChange) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var currency: String
    @State private var error: String?
    @State private var isSaving = false
    @FocusState private var priceFocused: Bool

    init(price: OrbitEnergyPrice, pcName: String, onSave: @escaping (OrbitEnergyPriceChange) async -> String?) {
        self.price = price
        self.pcName = pcName
        self.onSave = onSave
        _text = State(initialValue: price.pricePerKWh.map { $0.formatted(.number.precision(.fractionLength(0...4)).grouping(.never)) } ?? "")
        let fallback = Locale.current.currency?.identifier ?? "EUR"
        _currency = State(initialValue: (price.currency ?? price.defaultPrice?.currency ?? fallback).uppercased())
    }

    /// Accepts "1.07" and "1,07" whatever the region's decimal separator is (and a pasted "1,234.56").
    private var parsedPrice: Double? { OrbitEnergyPriceChange.parse(text) }
    private var isValid: Bool { parsedPrice.map { OrbitEnergyPriceChange.isValid(price: $0, currency: currency) } ?? false }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("Price", text: $text)
                        .keyboardType(.decimalPad)
                        .focused($priceFocused)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .accessibilityLabel("Price per kilowatt hour")
                    Text("\(currency) per kWh").foregroundStyle(.secondary)
                }
                NavigationLink {
                    OrbitCurrencyPicker(selection: $currency, suggested: suggestedCurrencies)
                } label: {
                    LabeledContent("Currency", value: OrbitEnergyFormat.currencyName(currency))
                }
            } header: {
                Text("Your price per kWh")
            } footer: {
                Text("Use the price on your electricity bill, with taxes and fees included. The new price counts from now on: days already recorded keep their price, unless you pick another currency, which shows the whole history at this price.")
            }
            .orbitRow()

            if price.isOverride, let detected = price.detectedPrice, let value = detected.pricePerKWh, let detectedCurrency = detected.currency {
                Section {
                    Button {
                        Task { await save(.resetToDetected) }
                    } label: {
                        Label("Use the Published Average", systemImage: "arrow.uturn.backward.circle")
                    }
                    .disabled(isSaving)
                } footer: {
                    Text("\(OrbitEnergyFormat.unitPrice(value, currency: detectedCurrency)) per kWh · \(detected.source ?? "Published average")")
                }
                .orbitRow()
            }

            if let error {
                Section { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                    .orbitRow(tint: .orange)
            }
        }
        .orbitListChrome()
        .navigationTitle("Electricity Price")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") {
                        guard let value = parsedPrice else { return }
                        Task { await save(.set(value, currency: currency)) }
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
        }
        .onAppear { if !price.hasPrice { priceFocused = true } }
        .interactiveDismissDisabled(isSaving)
    }

    private var suggestedCurrencies: [String] {
        var codes: [String] = []
        for code in [price.currency, price.defaultPrice?.currency, Locale.current.currency?.identifier, "EUR", "USD", "GBP"] {
            if let code = code?.uppercased(), code.count == 3, !codes.contains(code) { codes.append(code) }
        }
        return codes
    }

    private func save(_ change: OrbitEnergyPriceChange) async {
        isSaving = true
        error = nil
        let failure = await onSave(change)
        isSaving = false
        if let failure {
            error = failure
            OrbitHaptics.error()
        } else {
            dismiss()
        }
    }
}

/// Searchable list of currencies, suggestions first.
struct OrbitCurrencyPicker: View {
    @Binding var selection: String
    let suggested: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private static let all: [String] = OrbitEnergyPriceChange.offeredCurrencies
        .sorted { OrbitEnergyFormat.currencyName($0) < OrbitEnergyFormat.currencyName($1) }

    private var filtered: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Self.all }
        return Self.all.filter { $0.localizedCaseInsensitiveContains(query) || OrbitEnergyFormat.currencyName($0).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if search.isEmpty {
                Section("Suggested") { ForEach(suggested, id: \.self, content: row) }
                    .orbitRow()
            }
            Section(search.isEmpty ? "All currencies" : "Results") { ForEach(filtered, id: \.self, content: row) }
                .orbitRow()
        }
        .orbitListChrome()
        .searchable(text: $search, prompt: "Currency or code")
        .navigationTitle("Currency")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ code: String) -> some View {
        Button {
            OrbitHaptics.selection()
            selection = code
            dismiss()
        } label: {
            HStack {
                Text(OrbitEnergyFormat.currencyName(code)).foregroundStyle(.white)
                Spacer()
                if code == selection { Image(systemName: "checkmark").foregroundStyle(.green).fontWeight(.semibold) }
            }
        }
        .accessibilityAddTraits(code == selection ? [.isSelected] : [])
    }
}
