import Foundation

// Electricity cost (DESIGN F6) and the monthly summary "Wrapped" (F7): the PC's JSON, formatting and
// demo data. Shared by the iPhone/iPad and Mac apps and compiled on its own by
// `Tests/check_energy_summary.py` (which decodes the real agent payloads with it), so it uses
// Foundation only.
//
// Routes (main token, HTTPS only; feature strings "energy" and "summary" in `GET /api/capabilities`):
// - `GET /api/energy/price` and `PUT /api/energy/price` `{"pricePerKWh", "currency"}` or `{"reset": true}`
// - `GET/PUT /api/energy/settings` `{"baseWatts", "psuEfficiency"}`
// - `GET /api/energy/summary?month=YYYY-MM`
// - `GET /api/summary?month=YYYY-MM`
// - `GET /api/history/sessions/{id}` adds `"energy"` (see `OrbitSessionEnergy`).

enum OrbitEnergyAPI {
    static let energyFeature = "energy"
    static let summaryFeature = "summary"
    static let pricePath = "/api/energy/price"
    static let settingsPath = "/api/energy/settings"
    static let energySummaryPath = "/api/energy/summary"
    static let monthSummaryPath = "/api/summary"
    /// The passive event the PC sends on the 1st (or within the first week) for the month that ended.
    static let summaryReadyKind = "summary.ready"

    /// `month=YYYY-MM`, or nothing for the PC's current month.
    static func monthQuery(_ month: OrbitMonthID?) -> [URLQueryItem] {
        month.map { [URLQueryItem(name: "month", value: $0.text)] } ?? []
    }

    /// `orbit://summary?month=YYYY-MM&pc=<saved PC id>`: opens a monthly summary in the iPhone app.
    static func summaryLink(month: OrbitMonthID?, pcID: String?) -> String {
        var components = URLComponents()
        components.scheme = "orbit"
        components.host = "summary"
        var items: [URLQueryItem] = []
        if let month { items.append(URLQueryItem(name: "month", value: month.text)) }
        if let pcID, !pcID.isEmpty { items.append(URLQueryItem(name: "pc", value: pcID)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.string ?? "orbit://summary"
    }

    /// The parts of a summary link; nil for any other link.
    static func summaryLinkParts(_ url: URL) -> (pcID: String?, month: OrbitMonthID?)? {
        guard url.scheme?.lowercased() == "orbit", url.host?.lowercased() == "summary" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pc = items.first { $0.name == "pc" }?.value.flatMap { $0.isEmpty ? nil : $0 }
        return (pc, items.first { $0.name == "month" }?.value.flatMap(OrbitMonthID.init))
    }

    /// The month a `summary.ready` alert is about. The PC announces the month that just ended during the
    /// first seven days of the next one, and an alert carries no month of its own, so it's the month before
    /// the one the alert arrived in. The date is moved a day and two hours forward first: a phone in a time
    /// zone behind the PC's can still be on the last day of the old month when the PC's month has turned
    /// (and an announcement from day 7, shown up to 12 hours late, still lands before day 10).
    static func summaryMonth(forAlertDeliveredAt date: Date, calendar: Calendar = OrbitEnergyFormat.gregorian()) -> OrbitMonthID {
        OrbitMonthID.containing(date.addingTimeInterval(26 * 3600), calendar: calendar).shifted(by: -1)
    }

    /// The link a tapped PC alert opens instead of its own: that month's summary for `summary.ready`, nil for
    /// every other kind.
    static func alertLink(kind: String?, pcID: String?, deliveredAt date: Date, calendar: Calendar = OrbitEnergyFormat.gregorian()) -> String? {
        guard kind == summaryReadyKind else { return nil }
        return summaryLink(month: summaryMonth(forAlertDeliveredAt: date, calendar: calendar), pcID: pcID)
    }
}

// MARK: - Months

/// A calendar month as the PC names it ("2026-10").
struct OrbitMonthID: Hashable, Comparable, Sendable, Identifiable, CustomStringConvertible {
    let year: Int
    let month: Int

    init?(year: Int, month: Int) {
        guard (2000...2100).contains(year), (1...12).contains(month) else { return nil }
        self.year = year
        self.month = month
    }

    /// Strict `YYYY-MM`, like the agent's `parse_month`.
    init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              parts[0].allSatisfy(\.isASCII), parts[1].allSatisfy(\.isASCII),
              let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
        self.init(year: year, month: month)
    }

    var text: String { String(format: "%04d-%02d", year, month) }
    var id: String { text }
    var description: String { text }

    static func < (lhs: OrbitMonthID, rhs: OrbitMonthID) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    func shifted(by months: Int) -> OrbitMonthID {
        let index = year * 12 + (month - 1) + months
        let year = Int((Double(index) / 12).rounded(.down))
        return OrbitMonthID(year: min(2100, max(2000, year)), month: index - year * 12 + 1) ?? self
    }

    static func containing(_ date: Date, calendar: Calendar = OrbitEnergyFormat.gregorian()) -> OrbitMonthID {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return OrbitMonthID(year: parts.year ?? 2026, month: parts.month ?? 1) ?? OrbitMonthID(year: 2026, month: 1)!
    }

    func firstDay(calendar: Calendar = OrbitEnergyFormat.gregorian()) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12)) ?? Date(timeIntervalSince1970: 0)
    }

    func dayCount(calendar: Calendar = OrbitEnergyFormat.gregorian()) -> Int {
        calendar.range(of: .day, in: .month, for: firstDay(calendar: calendar))?.count ?? 30
    }

    /// "October 2026".
    func title(locale: Locale = .current) -> String {
        firstDay(calendar: OrbitEnergyFormat.gregorian(locale: locale))
            .formatted(Date.FormatStyle(locale: locale, calendar: OrbitEnergyFormat.gregorian(locale: locale)).month(.wide).year())
    }

    /// "Oct 2026".
    func shortTitle(locale: Locale = .current) -> String {
        firstDay(calendar: OrbitEnergyFormat.gregorian(locale: locale))
            .formatted(Date.FormatStyle(locale: locale, calendar: OrbitEnergyFormat.gregorian(locale: locale)).month(.abbreviated).year())
    }

    /// "October".
    func name(locale: Locale = .current) -> String {
        let symbols = OrbitEnergyFormat.gregorian(locale: locale).standaloneMonthSymbols
        return symbols.indices.contains(month - 1) ? symbols[month - 1] : text
    }

    /// The months to offer in a picker: what the PC has data for plus the one on screen, newest first.
    static func pickerMonths(available: [String], including shown: OrbitMonthID?) -> [OrbitMonthID] {
        var months = Set(available.compactMap(OrbitMonthID.init))
        if let shown { months.insert(shown) }
        return months.sorted(by: >)
    }
}

// MARK: - PC payloads

/// `GET/PUT /api/energy/price`. Without a price row `pricePerKWh` and `source` are null and `currency`
/// may hold Windows' currency for the country (a hint for the editor).
struct OrbitEnergyPrice: Codable, Equatable, Sendable {
    /// The table price (Eurostat or another public average); still reported while the user's own price wins.
    struct TablePrice: Codable, Equatable, Sendable {
        var pricePerKWh: Double?
        var currency: String?
        var source: String?
        var period: String?
    }

    var country: String?
    var pricePerKWh: Double?
    var currency: String?
    var source: String?
    var period: String?
    var isOverride: Bool
    var defaultPrice: TablePrice?

    init(country: String?, pricePerKWh: Double?, currency: String?, source: String?, period: String?,
         isOverride: Bool, defaultPrice: TablePrice?) {
        self.country = country
        self.pricePerKWh = pricePerKWh
        self.currency = currency
        self.source = source
        self.period = period
        self.isOverride = isOverride
        self.defaultPrice = defaultPrice
    }

    private enum CodingKeys: String, CodingKey { case country, pricePerKWh, currency, source, period, isOverride, defaultPrice }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        pricePerKWh = try c.decodeIfPresent(Double.self, forKey: .pricePerKWh)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        period = try c.decodeIfPresent(String.self, forKey: .period)
        isOverride = try c.decodeIfPresent(Bool.self, forKey: .isOverride) ?? false
        // An odd table row must not hide the price itself.
        defaultPrice = (try? c.decodeIfPresent(TablePrice.self, forKey: .defaultPrice)) ?? nil
    }

    /// A price Orbit can multiply by: a number and a currency.
    var hasPrice: Bool { pricePerKWh != nil && (currency?.isEmpty == false) }
    /// The table price, when there is one with a number.
    var detectedPrice: TablePrice? {
        guard let table = defaultPrice, table.pricePerKWh != nil, table.currency?.isEmpty == false else { return nil }
        return table
    }
}

/// `GET/PUT /api/energy/settings`: what Orbit adds to the CPU and GPU readings.
struct OrbitEnergySettings: Codable, Equatable, Sendable {
    /// Motherboard, memory, drives, fans: power the sensors don't report (0–500 W).
    var baseWatts: Double
    /// Share of the wall power that reaches the components (0.5–1).
    var psuEfficiency: Double

    static let baseWattsRange: ClosedRange<Double> = 0...500
    static let efficiencyRange: ClosedRange<Double> = 0.5...1
    static let defaults = OrbitEnergySettings(baseWatts: 60, psuEfficiency: 0.88)
}

/// Body of `PUT /api/energy/price`: a new price, or `{"reset": true}` for the detected one.
struct OrbitEnergyPriceChange: Encodable, Equatable, Sendable {
    var pricePerKWh: Double?
    var currency: String?
    var reset: Bool?

    static func set(_ price: Double, currency: String) -> OrbitEnergyPriceChange {
        OrbitEnergyPriceChange(pricePerKWh: price, currency: currency.uppercased(), reset: nil)
    }
    static let resetToDetected = OrbitEnergyPriceChange(pricePerKWh: nil, currency: nil, reset: true)

    /// What the PC accepts (`orbit_energy.validate_price_update`): 0–100000 and a three-letter code.
    static let priceRange: ClosedRange<Double> = 0...100_000
    /// Codes Apple still lists that ISO 4217 dropped (the PC refuses them): the Cuban convertible peso and
    /// the old Venezuelan bolívar.
    static let withdrawnCurrencies: Set<String> = ["CUC", "VEF"]
    /// The currencies the price editor offers: Apple's common ISO 4217 codes that the PC accepts.
    static var offeredCurrencies: [String] {
        Locale.commonISOCurrencyCodes.filter { $0.count == 3 && !withdrawnCurrencies.contains($0.uppercased()) }
    }

    static func isValid(price: Double, currency: String) -> Bool {
        price.isFinite && priceRange.contains(price) && currency.count == 3 && currency.allSatisfy { $0.isASCII && $0.isLetter }
            && !withdrawnCurrencies.contains(currency.uppercased())
    }

    /// A typed or pasted price: "1.07", "1,07", "1 444,70", "1,234.56" or "1.234,56". With both marks the
    /// last one is the decimal separator; one mark used once is the decimal separator; a mark used several
    /// times groups thousands. Digits of other scripts ("١٫٥" from an Arabic keyboard, "１.５") count like
    /// 0–9. Nil for anything else.
    static func parse(_ text: String) -> Double? {
        var cleaned = ""
        for scalar in text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            switch scalar {
            case " ", "\u{00A0}", "\u{202F}", "'", "\u{2019}", "\u{066C}":
                continue  // Spaces, apostrophes and the Arabic thousands mark only group digits.
            case "\u{066B}":
                cleaned.append(",")  // The Arabic decimal mark; decided below like a comma.
            default:
                if !scalar.isASCII, scalar.properties.numericType == .decimal, let digit = scalar.properties.numericValue {
                    cleaned.append(String(Int(digit)))
                } else {
                    cleaned.unicodeScalars.append(scalar)
                }
            }
        }
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }) else { return nil }
        let dots = cleaned.filter { $0 == "." }.count, commas = cleaned.filter { $0 == "," }.count
        if dots > 0 && commas > 0 {
            let decimal: Character = cleaned.lastIndex(of: ".")! > cleaned.lastIndex(of: ",")! ? "." : ","
            cleaned = String(cleaned.filter { $0 != (decimal == "." ? "," : ".") })
            cleaned = cleaned.replacingOccurrences(of: String(decimal), with: ".")
        } else if commas == 1 {
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
        } else if commas > 1 || dots > 1 {
            cleaned = String(cleaned.filter { $0 != "," && $0 != "." })
        }
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }
}

/// Body of `PUT /api/energy/settings` (either key may be left out).
struct OrbitEnergySettingsChange: Encodable, Equatable, Sendable {
    var baseWatts: Double?
    var psuEfficiency: Double?
}

/// `GET /api/energy/summary?month=YYYY-MM`.
struct OrbitEnergyMonth: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Sendable, Identifiable {
        var day: String
        var kWh: Double
        var cost: Double?
        var id: String { day }
    }

    struct Game: Codable, Equatable, Sendable, Identifiable {
        var game: String
        var name: String
        var kWh: Double
        var cost: Double?
        var hours: Double
        var id: String { game }
    }

    struct Amount: Codable, Equatable, Sendable {
        var kWh: Double
        var cost: Double?
    }

    /// Where the estimated energy went: the two measured parts, the rest of the PC and the power supply's losses.
    struct Breakdown: Codable, Equatable, Sendable {
        var cpuKWh: Double
        var gpuKWh: Double
        var baseKWh: Double
        var lossKWh: Double
        var total: Double { cpuKWh + gpuKWh + baseKWh + lossKWh }
    }

    var month: String
    var kWh: Double
    var cost: Double?
    var currency: String?
    var isEstimate: Bool
    /// Share of the tracked time with a CPU or GPU power reading (nil without tracked time).
    var coverage: Double?
    /// Every day from the 1st to today (or the month's end), zeros included.
    var days: [Day]
    var games: [Game]
    var today: Amount?
    var price: OrbitEnergyPrice?
    var breakdown: Breakdown?
    var trackedHours: Double?
    var available: [String]

    init(month: String, kWh: Double, cost: Double?, currency: String?, isEstimate: Bool = true, coverage: Double?,
         days: [Day], games: [Game], today: Amount?, price: OrbitEnergyPrice?, breakdown: Breakdown?,
         trackedHours: Double?, available: [String]) {
        self.month = month
        self.kWh = kWh
        self.cost = cost
        self.currency = currency
        self.isEstimate = isEstimate
        self.coverage = coverage
        self.days = days
        self.games = games
        self.today = today
        self.price = price
        self.breakdown = breakdown
        self.trackedHours = trackedHours
        self.available = available
    }

    private enum CodingKeys: String, CodingKey {
        case month, kWh, cost, currency, isEstimate, coverage, days, games, today, price, breakdown, trackedHours, available
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = try c.decode(String.self, forKey: .month)
        kWh = try c.decode(Double.self, forKey: .kWh)
        cost = try c.decodeIfPresent(Double.self, forKey: .cost)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        isEstimate = try c.decodeIfPresent(Bool.self, forKey: .isEstimate) ?? true
        coverage = try c.decodeIfPresent(Double.self, forKey: .coverage)
        days = try c.decodeIfPresent([Day].self, forKey: .days) ?? []
        games = try c.decodeIfPresent([Game].self, forKey: .games) ?? []
        today = try c.decodeIfPresent(Amount.self, forKey: .today)
        price = (try? c.decodeIfPresent(OrbitEnergyPrice.self, forKey: .price)) ?? nil
        breakdown = (try? c.decodeIfPresent(Breakdown.self, forKey: .breakdown)) ?? nil
        trackedHours = try c.decodeIfPresent(Double.self, forKey: .trackedHours)
        available = try c.decodeIfPresent([String].self, forKey: .available) ?? []
    }

    var monthID: OrbitMonthID? { OrbitMonthID(month) }
    /// False for a month the PC recorded nothing in (the agent wasn't running, or it's in the future).
    var hasReadings: Bool { kWh > 0 || (trackedHours ?? 0) > 0 }
    /// Energy outside games: the desktop, videos, idle time.
    var otherKWh: Double { max(0, kWh - games.reduce(0) { $0 + $1.kWh }) }
    var otherCost: Double? {
        guard let cost else { return nil }
        let games = self.games.compactMap(\.cost).reduce(0, +)
        return max(0, cost - games)
    }
    var gamingHours: Double { games.reduce(0) { $0 + $1.hours } }
    /// The day with the most energy (nil when every day is zero).
    var peakDay: Day? {
        guard let day = days.max(by: { $0.kWh < $1.kWh }), day.kWh > 0 else { return nil }
        return day
    }
    /// Average per day over the days listed (the month so far for the current month).
    var averageDailyKWh: Double? { days.isEmpty ? nil : kWh / Double(days.count) }
}

/// `GET /api/summary?month=YYYY-MM`.
struct OrbitMonthSummary: Codable, Equatable, Sendable {
    struct Game: Codable, Equatable, Sendable, Identifiable {
        var game: String
        var name: String
        var playSeconds: Double
        var averageFPS: Double?
        var peakGPUTemp: Double?
        var peakCPUTemp: Double?
        var averageGPUTemp: Double?
        var averageCPUTemp: Double?
        /// Days with at least a minute of this game.
        var daysPlayed: Int
        var kWh: Double
        var cost: Double?
        var id: String { game }

        init(game: String, name: String, playSeconds: Double, averageFPS: Double?, peakGPUTemp: Double?, peakCPUTemp: Double?,
             averageGPUTemp: Double?, averageCPUTemp: Double?, daysPlayed: Int, kWh: Double, cost: Double?) {
            self.game = game
            self.name = name
            self.playSeconds = playSeconds
            self.averageFPS = averageFPS
            self.peakGPUTemp = peakGPUTemp
            self.peakCPUTemp = peakCPUTemp
            self.averageGPUTemp = averageGPUTemp
            self.averageCPUTemp = averageCPUTemp
            self.daysPlayed = daysPlayed
            self.kWh = kWh
            self.cost = cost
        }

        private enum CodingKeys: String, CodingKey {
            case game, name, playSeconds, averageFPS, peakGPUTemp, peakCPUTemp, averageGPUTemp, averageCPUTemp, daysPlayed, kWh, cost
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            game = try c.decode(String.self, forKey: .game)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? game
            playSeconds = try c.decode(Double.self, forKey: .playSeconds)
            averageFPS = try c.decodeIfPresent(Double.self, forKey: .averageFPS)
            peakGPUTemp = try c.decodeIfPresent(Double.self, forKey: .peakGPUTemp)
            peakCPUTemp = try c.decodeIfPresent(Double.self, forKey: .peakCPUTemp)
            averageGPUTemp = try c.decodeIfPresent(Double.self, forKey: .averageGPUTemp)
            averageCPUTemp = try c.decodeIfPresent(Double.self, forKey: .averageCPUTemp)
            daysPlayed = try c.decodeIfPresent(Int.self, forKey: .daysPlayed) ?? 0
            kWh = try c.decodeIfPresent(Double.self, forKey: .kWh) ?? 0
            cost = try c.decodeIfPresent(Double.self, forKey: .cost)
        }
    }

    struct Session: Codable, Equatable, Sendable {
        var game: String
        var name: String
        var seconds: Double
        /// `YYYY-MM-DD`, the PC's local day the session started.
        var date: String
    }

    struct BusyDay: Codable, Equatable, Sendable {
        var day: String
        var playSeconds: Double
    }

    struct Energy: Codable, Equatable, Sendable {
        var kWh: Double
        var cost: Double?
        var currency: String?
        var gamingKWh: Double?
        var isEstimate: Bool

        init(kWh: Double, cost: Double?, currency: String?, gamingKWh: Double?, isEstimate: Bool = true) {
            self.kWh = kWh
            self.cost = cost
            self.currency = currency
            self.gamingKWh = gamingKWh
            self.isEstimate = isEstimate
        }

        private enum CodingKeys: String, CodingKey { case kWh, cost, currency, gamingKWh, isEstimate }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kWh = try c.decode(Double.self, forKey: .kWh)
            cost = try c.decodeIfPresent(Double.self, forKey: .cost)
            currency = try c.decodeIfPresent(String.self, forKey: .currency)
            gamingKWh = try c.decodeIfPresent(Double.self, forKey: .gamingKWh)
            isEstimate = try c.decodeIfPresent(Bool.self, forKey: .isEstimate) ?? true
        }
    }

    struct Previous: Codable, Equatable, Sendable {
        var month: String
        var playSeconds: Double
        var kWh: Double
    }

    var month: String
    var playSeconds: Double
    /// Days with at least a minute of play.
    var daysPlayed: Int
    /// Play spans of at least a minute that started this month (spans of different games may overlap).
    var sessions: Int
    var topGame: Game?
    /// Sorted by play time, longest first.
    var games: [Game]
    var longestSession: Session?
    var busiestDay: BusyDay?
    var peakCPUTemp: Double?
    var peakGPUTemp: Double?
    var energy: Energy?
    var previous: Previous?
    var available: [String]

    init(month: String, playSeconds: Double, daysPlayed: Int, sessions: Int, topGame: Game?, games: [Game],
         longestSession: Session?, busiestDay: BusyDay?, peakCPUTemp: Double?, peakGPUTemp: Double?,
         energy: Energy?, previous: Previous?, available: [String]) {
        self.month = month
        self.playSeconds = playSeconds
        self.daysPlayed = daysPlayed
        self.sessions = sessions
        self.topGame = topGame
        self.games = games
        self.longestSession = longestSession
        self.busiestDay = busiestDay
        self.peakCPUTemp = peakCPUTemp
        self.peakGPUTemp = peakGPUTemp
        self.energy = energy
        self.previous = previous
        self.available = available
    }

    private enum CodingKeys: String, CodingKey {
        case month, playSeconds, daysPlayed, sessions, topGame, games, longestSession, busiestDay, peakCPUTemp, peakGPUTemp,
             energy, previous, available
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = try c.decode(String.self, forKey: .month)
        playSeconds = try c.decode(Double.self, forKey: .playSeconds)
        daysPlayed = try c.decodeIfPresent(Int.self, forKey: .daysPlayed) ?? 0
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        topGame = try c.decodeIfPresent(Game.self, forKey: .topGame)
        games = try c.decodeIfPresent([Game].self, forKey: .games) ?? []
        longestSession = (try? c.decodeIfPresent(Session.self, forKey: .longestSession)) ?? nil
        busiestDay = (try? c.decodeIfPresent(BusyDay.self, forKey: .busiestDay)) ?? nil
        peakCPUTemp = try c.decodeIfPresent(Double.self, forKey: .peakCPUTemp)
        peakGPUTemp = try c.decodeIfPresent(Double.self, forKey: .peakGPUTemp)
        energy = (try? c.decodeIfPresent(Energy.self, forKey: .energy)) ?? nil
        previous = (try? c.decodeIfPresent(Previous.self, forKey: .previous)) ?? nil
        available = try c.decodeIfPresent([String].self, forKey: .available) ?? []
    }

    var monthID: OrbitMonthID? { OrbitMonthID(month) }
    /// The PC counts a month as played from one minute of play (like a day played).
    var hasPlay: Bool { playSeconds >= 60 && !games.isEmpty }
    /// The game with the hottest GPU this month.
    var hottestGame: Game? {
        games.filter { $0.peakGPUTemp != nil }.max { ($0.peakGPUTemp ?? 0) < ($1.peakGPUTemp ?? 0) }
    }
    /// Share of the month's play time that went to the top game (0…1).
    var topGameShare: Double? {
        guard let top = topGame, playSeconds > 0 else { return nil }
        return min(1, top.playSeconds / playSeconds)
    }
    var playChange: OrbitChange? { previous.flatMap { OrbitChange(current: playSeconds, previous: $0.playSeconds) } }
    var energyChange: OrbitChange? {
        guard let energy, let previous else { return nil }
        return OrbitChange(current: energy.kWh, previous: previous.kWh)
    }
}

/// `"energy"` in `GET /api/history/sessions/{id}`: the session's estimated wall energy and cost. Left out
/// by older agents, or when the PC could not work it out.
struct OrbitSessionEnergy: Codable, Equatable, Sendable {
    var kWh: Double
    var cost: Double?
    var currency: String?
    var coverage: Double?
}

/// A month compared with the one before it.
struct OrbitChange: Equatable, Sendable {
    /// −0.12 for 12 % less.
    let fraction: Double

    /// Nil when there is nothing to compare with (the previous month had nothing).
    init?(current: Double, previous: Double) {
        guard previous > 0, current.isFinite, previous.isFinite else { return nil }
        fraction = current / previous - 1
    }

    var isSame: Bool { abs(fraction) < 0.005 }
    var isUp: Bool { fraction > 0 && !isSame }

    /// "+23 %", "−12 %" or "Same".
    func percentText(locale: Locale = .current) -> String {
        if isSame { return "Same" }
        let percent = (abs(fraction)).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        return (fraction > 0 ? "+" : "−") + percent
    }

    /// "23% more than September", "12% less than September", "about the same as September".
    func sentence(versus month: String, locale: Locale = .current) -> String {
        if isSame { return "About the same as \(month)" }
        let percent = (abs(fraction)).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        return "\(percent) \(fraction > 0 ? "more" : "less") than \(month)"
    }
}

// MARK: - Formatting

enum OrbitEnergyFormat {
    static func gregorian(locale: Locale = .current, timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }

    /// An amount in the PC's currency, formatted with its ISO code (the locale decides symbol or code).
    static func money(_ amount: Double, currency: String, locale: Locale = .current) -> String {
        amount.formatted(.currency(code: currency.uppercased()).locale(locale))
    }

    /// The month's or a game's cost: "RON 18.10"; "less than RON 0.01" for a tiny non-zero use; "—" without a price.
    static func cost(_ amount: Double?, currency: String?, kWh: Double? = nil, locale: Locale = .current) -> String {
        guard let amount, let currency, !currency.isEmpty, amount.isFinite else { return "—" }
        if amount < 0.005, (kWh ?? 0) > 0 { return "less than " + money(0.01, currency: currency, locale: locale) }
        return money(amount, currency: currency, locale: locale)
    }

    /// A price per kWh keeps up to four decimals ("RON 1.4573").
    static func unitPrice(_ price: Double, currency: String, locale: Locale = .current) -> String {
        price.formatted(.currency(code: currency.uppercased()).precision(.fractionLength(2...4)).locale(locale))
    }

    /// "RON 1.4573 per kWh".
    static func pricePerKWh(_ price: OrbitEnergyPrice, locale: Locale = .current) -> String? {
        guard let value = price.pricePerKWh, let currency = price.currency, !currency.isEmpty else { return nil }
        return unitPrice(value, currency: currency, locale: locale) + " per kWh"
    }

    /// "12.4 kWh", "0.056 kWh", "312 kWh".
    static func energy(_ kWh: Double, locale: Locale = .current) -> String {
        let value = max(0, kWh.isFinite ? kWh : 0)
        let digits: ClosedRange<Int> = value == 0 ? 0...0 : (value < 1 ? 0...3 : (value < 100 ? 0...1 : 0...0))
        return value.formatted(.number.precision(.fractionLength(digits)).locale(locale)) + " kWh"
    }

    /// "0.015 kWh · RON 0.02" for a session.
    static func energyAndCost(_ energy: OrbitSessionEnergy, locale: Locale = .current) -> String {
        let kWh = self.energy(energy.kWh, locale: locale)
        guard energy.cost != nil, energy.currency != nil else { return kWh }
        return kWh + " · " + cost(energy.cost, currency: energy.currency, kWh: energy.kWh, locale: locale)
    }

    /// The line under a session's estimated energy.
    static func sessionEnergyNote(_ energy: OrbitSessionEnergy, locale: Locale = .current) -> String {
        var text = "From the CPU and GPU power readings plus the rest of the PC"
        if energy.cost != nil, energy.currency != nil { text += ", at your electricity price" }
        if let coverage = energy.coverage, coverage < 0.9 {
            text += ". Power sensors answered \(percent(coverage, locale: locale)) of the time, so it's on the low side"
        }
        return text + "."
    }

    /// "42 h 10 min", "45 min", "under a minute" (same words as the PC's own notification).
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 30 else { return seconds > 0 ? "under a minute" : "0 min" }
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60, rest = minutes % 60
        if hours >= 100 || (hours > 0 && rest == 0) { return "\(hours) h" }
        return hours > 0 ? "\(hours) h \(rest) min" : "\(rest) min"
    }

    /// The same duration for VoiceOver: "42 hours 10 minutes".
    static func spokenDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 30 else { return seconds > 0 ? "under a minute" : "no time" }
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60, rest = minutes % 60
        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        let minuteText = rest == 1 ? "1 minute" : "\(rest) minutes"
        if hours == 0 { return minuteText }
        return rest == 0 || hours >= 100 ? hourText : "\(hourText) \(minuteText)"
    }

    /// "9.2 h" for the cost list's hours.
    static func hours(_ hours: Double, locale: Locale = .current) -> String {
        hours.formatted(.number.precision(.fractionLength(hours < 10 ? 0...1 : 0...0)).locale(locale)) + " h"
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return "—" }
        return "\(Int(celsius.rounded())) °C"
    }

    static func fps(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        return "\(Int(value.rounded())) FPS"
    }

    static func percent(_ fraction: Double, locale: Locale = .current) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// Local noon of a PC day (`YYYY-MM-DD`): stable for charts across DST changes.
    static func date(fromDay text: String, calendar: Calendar = gregorian()) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    /// "Saturday, October 12".
    static func longDay(_ text: String, locale: Locale = .current) -> String {
        let calendar = gregorian(locale: locale)
        guard let date = date(fromDay: text, calendar: calendar) else { return text }
        return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).weekday(.wide).month(.wide).day())
    }

    /// "Sat, Oct 12".
    static func shortDay(_ text: String, locale: Locale = .current) -> String {
        let calendar = gregorian(locale: locale)
        guard let date = date(fromDay: text, calendar: calendar) else { return text }
        return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).weekday(.abbreviated).month(.abbreviated).day())
    }

    /// "Romania" for "RO" (in the person's language).
    static func countryName(_ code: String?, locale: Locale = .current) -> String? {
        guard let code, code.count == 2 else { return nil }
        return locale.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }

    /// 🇷🇴 for "RO".
    static func flag(_ code: String?) -> String {
        guard let code, code.count == 2 else { return "" }
        var flag = ""
        for scalar in code.uppercased().unicodeScalars {
            guard ("A"..."Z").contains(scalar), let indicator = UnicodeScalar(127_397 + scalar.value) else { return "" }
            flag.unicodeScalars.append(indicator)
        }
        return flag
    }

    /// "Romanian Leu (RON)".
    static func currencyName(_ code: String, locale: Locale = .current) -> String {
        let upper = code.uppercased()
        guard let name = locale.localizedString(forCurrencyCode: upper), name.uppercased() != upper else { return upper }
        return "\(name) (\(upper))"
    }

    /// "Jan–Jun 2026" for Eurostat's "2026-S1", "Oct–Dec 2026" for "2026-Q4", "2025" for a year.
    static func period(_ period: String?, locale: Locale = .current) -> String? {
        guard let period, !period.isEmpty else { return nil }
        let symbols = gregorian(locale: locale).shortStandaloneMonthSymbols
        let parts = period.split(separator: "-")
        guard let year = parts.first.flatMap({ Int($0) }), symbols.count == 12 else { return period }
        if parts.count == 1 { return String(year) }
        let kind = parts[1].prefix(1), number = Int(parts[1].dropFirst()) ?? 0
        let range: (Int, Int)?
        switch (kind, number) {
        case ("S", 1...2): range = ((number - 1) * 6, (number - 1) * 6 + 5)
        case ("Q", 1...4): range = ((number - 1) * 3, (number - 1) * 3 + 2)
        default: range = nil
        }
        guard let range else { return period }
        return "\(symbols[range.0])–\(symbols[range.1]) \(year)"
    }

    /// Who publishes the price, in plain words.
    static func sourceExplanation(_ price: OrbitEnergyPrice, locale: Locale = .current) -> String {
        if price.isOverride { return "You entered this price. Orbit uses it instead of the published average." }
        guard price.hasPrice, let source = price.source else {
            return "Orbit doesn't know an average electricity price for this country. Enter the price from your bill."
        }
        let country = countryName(price.country, locale: locale) ?? "your country"
        let when = period(price.period, locale: locale).map { " for \($0)" } ?? ""
        if source.hasPrefix("Eurostat") {
            return "The average household price in \(country)\(when), with all taxes and fees, published by Eurostat."
        }
        if source.contains("EIA") { return "The U.S. average residential price\(when), from the Energy Information Administration." }
        if source.contains("Ofgem") { return "The Great Britain average price cap\(when), from Ofgem." }
        if source.contains("ElCom") { return "The Swiss median household tariff\(when), from ElCom." }
        return "\(source)\(when)."
    }

    /// The efficiency as a percentage, with the nearest 80 PLUS rating (115 V, 50 % load) as a guide.
    static func efficiencyLabel(_ efficiency: Double, locale: Locale = .current) -> String {
        let percent = self.percent(efficiency, locale: locale)
        let rating: String?
        switch efficiency {
        case 0.935...: rating = "like 80 PLUS Titanium"
        case 0.915..<0.935: rating = "like 80 PLUS Platinum"
        case 0.895..<0.915: rating = "like 80 PLUS Gold"
        case 0.865..<0.895: rating = "like 80 PLUS Silver"
        case 0.835..<0.865: rating = "like 80 PLUS Bronze"
        case 0.795..<0.835: rating = "like 80 PLUS"
        default: rating = nil
        }
        return rating.map { "\(percent), \($0)" } ?? percent
    }
}

// MARK: - Demo data

/// Sample numbers for demo mode: about three months of a gaming PC in Romania, generated the same way
/// every time (no randomness), so the cost screen and the summary agree with each other.
enum OrbitEnergyDemo {
    static let country = "RO"
    static let currency = "RON"
    static let pricePerKWh = 1.4573
    static let source = "Eurostat nrg_pc_204 (2026-S1)"
    static let period = "2026-S1"
    /// The months with sample data: this month and the two before it.
    static let historyMonths = 3

    static var price: OrbitEnergyPrice {
        OrbitEnergyPrice(country: country, pricePerKWh: pricePerKWh, currency: currency, source: source, period: period,
                         isOverride: false,
                         defaultPrice: .init(pricePerKWh: pricePerKWh, currency: currency, source: source, period: period))
    }

    static let settings = OrbitEnergySettings.defaults

    struct Title: Sendable {
        let key: String
        let name: String
        /// Whole-PC wall power while it runs.
        let wallWatts: Double
        let fps: Double
        let gpuTemp: Double
        let cpuTemp: Double
        let weight: Double
    }

    static let titles: [Title] = [
        Title(key: "cyberpunk2077", name: "Cyberpunk 2077", wallWatts: 545, fps: 94, gpuTemp: 78, cpuTemp: 81, weight: 0.34),
        Title(key: "eldenring", name: "ELDEN RING", wallWatts: 455, fps: 60, gpuTemp: 74, cpuTemp: 77, weight: 0.28),
        Title(key: "cs2", name: "Counter-Strike 2", wallWatts: 390, fps: 288, gpuTemp: 69, cpuTemp: 84, weight: 0.24),
        Title(key: "bg3", name: "Baldur's Gate 3", wallWatts: 470, fps: 112, gpuTemp: 75, cpuTemp: 79, weight: 0.14),
    ]
    static let desktopWatts = 128.0

    struct Play: Sendable {
        let title: Int
        let seconds: Double
    }

    struct DayPlan: Sendable {
        let day: String
        let desktopSeconds: Double
        let plays: [Play]
        var playSeconds: Double { plays.reduce(0) { $0 + $1.seconds } }
        var gamingWh: Double { plays.reduce(0) { $0 + $1.seconds / 3600 * OrbitEnergyDemo.titles[$1.title].wallWatts } }
        var wallWh: Double { gamingWh + desktopSeconds / 3600 * OrbitEnergyDemo.desktopWatts }
        var trackedSeconds: Double { desktopSeconds + playSeconds }
    }

    /// A stable number in 0..<1 for a day and a purpose.
    private static func unit(_ month: OrbitMonthID, _ day: Int, _ salt: UInt64) -> Double {
        var z = UInt64(month.year * 10_000 + month.month * 100 + day) &* 0x9E37_79B9_7F4A_7C15 &+ salt &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }

    private static func pickTitle(_ value: Double, excluding: Int? = nil) -> Int {
        let choices = titles.indices.filter { $0 != excluding }
        let total = choices.reduce(0) { $0 + titles[$1].weight }
        var cursor = value * total
        for index in choices {
            cursor -= titles[index].weight
            if cursor < 0 { return index }
        }
        return choices.last ?? 0
    }

    /// One day of the sample PC; `fraction` scales today (the day isn't over yet).
    static func plan(_ month: OrbitMonthID, day: Int, fraction: Double = 1, calendar: Calendar = OrbitEnergyFormat.gregorian()) -> DayPlan {
        let text = String(format: "%04d-%02d-%02d", month.year, month.month, day)
        let date = calendar.date(from: DateComponents(year: month.year, month: month.month, day: day, hour: 12)) ?? Date()
        let weekday = calendar.component(.weekday, from: date)
        let weekend = weekday == 1 || weekday == 7
        let desktopHours = weekend ? 1.2 + 1.8 * unit(month, day, 7) : 3.0 + 3.5 * unit(month, day, 8)
        var plays: [Play] = []
        if unit(month, day, 1) < (weekend ? 0.9 : 0.58) {
            let hours = weekend ? 2.2 + 3.4 * unit(month, day, 2) : 0.7 + 1.9 * unit(month, day, 3)
            let first = pickTitle(unit(month, day, 4))
            if unit(month, day, 5) < 0.32 {
                let second = pickTitle(unit(month, day, 6), excluding: first)
                plays = [Play(title: first, seconds: hours * 0.68 * 3600), Play(title: second, seconds: hours * 0.32 * 3600)]
            } else {
                plays = [Play(title: first, seconds: hours * 3600)]
            }
        }
        let scale = min(1, max(0, fraction))
        return DayPlan(day: text, desktopSeconds: (desktopHours * 3600 * scale).rounded(),
                       plays: plays.map { Play(title: $0.title, seconds: ($0.seconds * scale).rounded()) }.filter { $0.seconds > 0 })
    }

    static func availableMonths(today: Date, calendar: Calendar = OrbitEnergyFormat.gregorian()) -> [String] {
        let current = OrbitMonthID.containing(today, calendar: calendar)
        return (0..<historyMonths).reversed().map { current.shifted(by: -$0).text }
    }

    /// The days of `month` the sample PC has, with today cut at the current time.
    static func plans(_ month: OrbitMonthID, today: Date, calendar: Calendar = OrbitEnergyFormat.gregorian()) -> [DayPlan] {
        let current = OrbitMonthID.containing(today, calendar: calendar)
        guard month <= current, month > current.shifted(by: -historyMonths) else { return [] }
        let lastDay = month == current ? calendar.component(.day, from: today) : month.dayCount(calendar: calendar)
        let parts = calendar.dateComponents([.hour, .minute], from: today)
        let todayFraction = (Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60) / 23
        return (1...max(1, lastDay)).map { day in
            plan(month, day: day, fraction: month == current && day == lastDay ? todayFraction : 1, calendar: calendar)
        }
    }

    private static func round(_ value: Double, _ digits: Int) -> Double {
        let scale = pow(10, Double(digits))
        return (value * scale).rounded() / scale
    }

    static func energyMonth(_ month: OrbitMonthID? = nil, today: Date = Date(), calendar: Calendar = OrbitEnergyFormat.gregorian()) -> OrbitEnergyMonth {
        let current = OrbitMonthID.containing(today, calendar: calendar)
        let month = month ?? current
        let plans = plans(month, today: today, calendar: calendar)
        // Every day of the month up to today, zeros included, like the PC's own report.
        let lastListed = month < current ? month.dayCount(calendar: calendar) : (month == current ? calendar.component(.day, from: today) : 0)
        var days: [OrbitEnergyMonth.Day] = []
        if lastListed > 0 {
            for day in 1...lastListed {
                let text = String(format: "%04d-%02d-%02d", month.year, month.month, day)
                let kWh = (plans.first { $0.day == text }?.wallWh ?? 0) / 1000
                days.append(.init(day: text, kWh: round(kWh, 3), cost: round(kWh * pricePerKWh, 2)))
            }
        }
        var gameWh: [Int: (wh: Double, seconds: Double)] = [:]
        for plan in plans {
            for play in plan.plays {
                let wh = play.seconds / 3600 * titles[play.title].wallWatts
                gameWh[play.title, default: (0, 0)].wh += wh
                gameWh[play.title, default: (0, 0)].seconds += play.seconds
            }
        }
        let games = gameWh.map { index, value in
            OrbitEnergyMonth.Game(game: titles[index].key, name: titles[index].name, kWh: round(value.wh / 1000, 3),
                                  cost: round(value.wh / 1000 * pricePerKWh, 2), hours: round(value.seconds / 3600, 2))
        }.sorted { ($0.kWh, $1.name) > ($1.kWh, $0.name) }
        let totalWh = plans.reduce(0) { $0 + $1.wallWh }
        let seconds = plans.reduce(0) { $0 + $1.trackedSeconds }
        let todayPlan = Self.plans(current, today: today, calendar: calendar).last
        let todayKWh = (todayPlan?.wallWh ?? 0) / 1000
        // Wall = (CPU + GPU + base) / efficiency; the base is 60 W of every tracked second.
        let wall = totalWh / 1000
        let base = min(wall * settings.psuEfficiency, settings.baseWatts * seconds / 3600 / 1000)
        let measured = max(0, wall * settings.psuEfficiency - base)
        return OrbitEnergyMonth(
            month: month.text, kWh: round(wall, 3), cost: round(wall * pricePerKWh, 2), currency: currency,
            coverage: seconds > 0 ? 0.97 : nil, days: days, games: games,
            today: .init(kWh: round(todayKWh, 3), cost: round(todayKWh * pricePerKWh, 2)), price: price,
            breakdown: .init(cpuKWh: round(measured * 0.32, 3), gpuKWh: round(measured * 0.68, 3), baseKWh: round(base, 3),
                             lossKWh: round(wall * (1 - settings.psuEfficiency), 3)),
            trackedHours: round(seconds / 3600, 2), available: availableMonths(today: today, calendar: calendar))
    }

    static func summary(_ month: OrbitMonthID? = nil, today: Date = Date(), calendar: Calendar = OrbitEnergyFormat.gregorian()) -> OrbitMonthSummary {
        let current = OrbitMonthID.containing(today, calendar: calendar)
        let month = month ?? current
        let plans = plans(month, today: today, calendar: calendar)
        struct Totals { var seconds = 0.0; var wh = 0.0; var days = 0 }
        var totals: [Int: Totals] = [:]
        var longest: (play: Play, day: String)?
        var sessions = 0
        for plan in plans {
            for play in plan.plays {
                totals[play.title, default: Totals()].seconds += play.seconds
                totals[play.title, default: Totals()].wh += play.seconds / 3600 * titles[play.title].wallWatts
                if play.seconds >= 60 {
                    totals[play.title, default: Totals()].days += 1
                    sessions += play.seconds > 3.2 * 3600 ? 2 : 1
                }
                if play.seconds > (longest?.play.seconds ?? 0) { longest = (play, plan.day) }
            }
        }
        let games = totals.map { index, value -> OrbitMonthSummary.Game in
            let title = titles[index]
            let wobble = unit(month, index + 1, 11)
            return OrbitMonthSummary.Game(
                game: title.key, name: title.name, playSeconds: value.seconds.rounded(),
                averageFPS: round(title.fps * (0.96 + 0.06 * wobble), 1),
                peakGPUTemp: round(title.gpuTemp + 3 * wobble, 1), peakCPUTemp: round(title.cpuTemp + 4 * wobble, 1),
                averageGPUTemp: round(title.gpuTemp - 7 + 2 * wobble, 1), averageCPUTemp: round(title.cpuTemp - 9 + 2 * wobble, 1),
                daysPlayed: value.days, kWh: round(value.wh / 1000, 3), cost: round(value.wh / 1000 * pricePerKWh, 2))
        }.filter { $0.playSeconds > 0 }.sorted { ($0.playSeconds, $1.name) > ($1.playSeconds, $0.name) }
        let busiest = plans.filter { $0.playSeconds > 0 }.max { ($0.playSeconds, $1.day) < ($1.playSeconds, $0.day) }
        let wall = plans.reduce(0) { $0 + $1.wallWh } / 1000
        let gaming = plans.reduce(0) { $0 + $1.gamingWh } / 1000
        let previousPlans = Self.plans(month.shifted(by: -1), today: today, calendar: calendar)
        let playTotal = games.reduce(0) { $0 + $1.playSeconds }
        return OrbitMonthSummary(
            month: month.text, playSeconds: playTotal,
            daysPlayed: plans.filter { $0.playSeconds >= 60 }.count, sessions: sessions,
            topGame: games.first, games: games,
            longestSession: longest.map { .init(game: titles[$0.play.title].key, name: titles[$0.play.title].name,
                                                seconds: $0.play.seconds.rounded(), date: $0.day) },
            busiestDay: busiest.map { .init(day: $0.day, playSeconds: $0.playSeconds.rounded()) },
            peakCPUTemp: games.compactMap(\.peakCPUTemp).max(), peakGPUTemp: games.compactMap(\.peakGPUTemp).max(),
            energy: .init(kWh: round(wall, 3), cost: round(wall * pricePerKWh, 2), currency: currency, gamingKWh: round(gaming, 3)),
            previous: .init(month: month.shifted(by: -1).text, playSeconds: previousPlans.reduce(0) { $0 + $1.playSeconds }.rounded(),
                            kWh: round(previousPlans.reduce(0) { $0 + $1.wallWh } / 1000, 3)),
            available: availableMonths(today: today, calendar: calendar))
    }
}
