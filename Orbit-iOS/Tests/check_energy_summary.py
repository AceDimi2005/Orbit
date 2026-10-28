"""Electricity cost (F6) and the monthly summary (F7): the agent's real JSON decoded by the app's models.

1. Compiles the production `Shared/OrbitEnergy.swift` and `Shared/OrbitSummaryShareCard.swift` with the
   check below (Swift 6, strict concurrency) and lets it write the request bodies the apps send.
2. Fills a real energy ledger through the agent's own trackers (`orbit_energy.EnergyTracker`,
   `orbit_summary.GameTracker`) with fake clocks: two months of desktop time and games, a Steam game named
   from its appmanifest, a five-minute pause inside one session, a 40-second launch. Then it calls the real
   FastAPI routes over https with TestClient: price, settings, both summaries (this month, last month, an
   empty month, a future month, a bad month), the app's own PUT bodies (own price, a currency change,
   reset, settings) and session details with and without `"energy"` (plus a session with one reading).
3. The Swift check decodes every reply, re-encodes it and compares it key by key with the PC's JSON (so a
   renamed, dropped or unread key fails), checks the numbers that tie the two summaries together, the
   formatting helpers (free electricity, currencies without decimals) and price parsing, the versus
   headlines, the `summary.ready` link, the demo data (re-priced with an edited price and other estimate
   settings), that an odd `"energy"` never breaks a session detail, and renders the share picture
   (1080 × 1350 PNG, also through the Transferable export the share sheet uses). The agent must also
   accept every currency the price editor offers and every value its two setting steppers can send.

Run with the agent's Python environment (FastAPI): no PC, network or device is touched, and nothing is
written outside temporary folders (pass `--png DIR` to keep the rendered share pictures).
"""
import argparse
import calendar
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
AGENT = ROOT / "Orbit-Windows-Agent"
sys.path.insert(0, str(AGENT))
sys.dont_write_bytecode = True

TOKEN = "energy-contract-token-0123456789abcdef"

SWIFT_CHECK = r'''
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
    exit(1)
}

func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { fail(message()) }
}

func near(_ a: Double?, _ b: Double?, _ tolerance: Double = 0.0101) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return abs(a - b) <= tolerance
}

func load<T: Decodable>(_ type: T.Type, _ name: String, in directory: URL) -> (value: T, raw: Any) {
    let url = directory.appendingPathComponent(name + ".json")
    guard let data = try? Data(contentsOf: url) else { fail("missing \(name).json") }
    do {
        let value = try JSONDecoder().decode(type, from: data)
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return (value, raw)
    } catch {
        fail("\(name).json does not decode as \(type): \(error)")
    }
}

/// Every key of the PC's JSON must come back from the app's model with the same value; the model must not
/// expect keys the PC doesn't send.
func compare(_ model: Any, _ original: Any, path: String, unread: inout [String]) {
    switch (model, original) {
    case let (m as [String: Any], o as [String: Any]):
        for (key, value) in o.sorted(by: { $0.key < $1.key }) {
            if let modelValue = m[key] {
                compare(modelValue, value, path: path + "." + key, unread: &unread)
            } else if !(value is NSNull) {
                unread.append(path + "." + key)
            }
        }
        for key in m.keys where o[key] == nil { fail("\(path).\(key) is in the app's model but the PC doesn't send it") }
    case let (m as [Any], o as [Any]):
        check(m.count == o.count, "\(path): \(m.count) items in the app, \(o.count) from the PC")
        for (index, pair) in zip(m, o).enumerated() { compare(pair.0, pair.1, path: "\(path)[\(index)]", unread: &unread) }
    case let (m as String, o as String):
        check(m == o, "\(path): \"\(m)\" in the app, \"\(o)\" from the PC")
    case let (m as NSNumber, o as NSNumber):
        check(abs(m.doubleValue - o.doubleValue) <= 1e-9 * max(1, abs(o.doubleValue)), "\(path): \(m) in the app, \(o) from the PC")
    default:
        fail("\(path): \(type(of: model)) in the app, \(type(of: original)) from the PC")
    }
}

func roundTrips<T: Encodable>(_ value: T, _ raw: Any, _ name: String) {
    guard let data = try? JSONEncoder().encode(value),
          let encoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { fail("\(name): cannot encode") }
    var unread: [String] = []
    compare(encoded, raw, path: name, unread: &unread)
    check(unread.isEmpty, "the app doesn't read \(unread.joined(separator: ", ")) (add it to the Swift model, or decoding failed)")
}

func writeJSON<T: Encodable>(_ value: T, _ url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { fail("cannot encode \(url.lastPathComponent)") }
    do { try data.write(to: url) } catch { fail("cannot write \(url.path)") }
}

/// Formatted money with plain spaces (Foundation puts a no-break space between "RON" and the number).
func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
}

func pngSize(_ data: Data) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (width, height)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { fail("usage: check --bodies DIR | --check DIR [PNG_DIR]") }
let directory = URL(fileURLWithPath: arguments[2])
let us = Locale(identifier: "en_US")
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
utc.locale = us

if arguments[1] == "--bodies" {
    // What the apps send. The Python side PUTs these exact bytes to the agent.
    writeJSON(OrbitEnergyPriceChange.set(1.07, currency: "ron"), directory.appendingPathComponent("put-price-own.json"))
    writeJSON(OrbitEnergyPriceChange.set(0.30, currency: "EUR"), directory.appendingPathComponent("put-price-eur.json"))
    writeJSON(OrbitEnergyPriceChange.resetToDetected, directory.appendingPathComponent("put-price-reset.json"))
    writeJSON(OrbitEnergySettingsChange(baseWatts: 75, psuEfficiency: 0.9), directory.appendingPathComponent("put-settings.json"))
    // Every currency the price editor offers; the PC must accept each one.
    let offered = OrbitEnergyPriceChange.offeredCurrencies
    check(offered.count > 100 && offered.contains("RON") && offered.contains("EUR") && !offered.contains("VEF"), "offered currencies: \(offered.count)")
    writeJSON(offered, directory.appendingPathComponent("currencies.json"))
    // Every value the two steppers can reach from the defaults (SwiftUI adds the step and clamps to the
    // range), as the app sends it; the PC must accept each one.
    var steps: [OrbitEnergySettingsChange] = []
    for direction in [1.0, -1.0] {
        var value = OrbitEnergySettings.defaults
        for _ in 0..<120 {
            value.baseWatts = min(500, max(0, value.baseWatts + 5 * direction))
            value.psuEfficiency = min(1, max(0.5, value.psuEfficiency + 0.01 * direction))
            let sent = value.normalized
            steps.append(OrbitEnergySettingsChange(baseWatts: sent.baseWatts, psuEfficiency: sent.psuEfficiency))
            value = sent
        }
    }
    check(steps.contains { $0.psuEfficiency == 1 && $0.baseWatts == 500 } && steps.contains { $0.psuEfficiency == 0.5 && $0.baseWatts == 0 }, "the steppers reach both ends")
    writeJSON(steps, directory.appendingPathComponent("settings-steps.json"))
    let own = String(decoding: try! Data(contentsOf: directory.appendingPathComponent("put-price-own.json")), as: UTF8.self)
    check(own == #"{"currency":"RON","pricePerKWh":1.07}"#, "own price body is \(own)")
    let reset = String(decoding: try! Data(contentsOf: directory.appendingPathComponent("put-price-reset.json")), as: UTF8.self)
    check(reset == #"{"reset":true}"#, "reset body is \(reset)")
    print("PASS: request bodies written")
    exit(0)
}
check(arguments[1] == "--check", "unknown mode \(arguments[1])")

// MARK: Price and settings

let priceRO = load(OrbitEnergyPrice.self, "price", in: directory)
roundTrips(priceRO.value, priceRO.raw, "price")
check(priceRO.value.country == "RO" && priceRO.value.pricePerKWh == 1.4573 && priceRO.value.currency == "RON", "price: \(priceRO.value)")
check(priceRO.value.hasPrice && !priceRO.value.isOverride && priceRO.value.detectedPrice?.pricePerKWh == 1.4573, "price flags")
check(OrbitEnergyFormat.pricePerKWh(priceRO.value, locale: us)?.contains("1.4573") == true, "unit price keeps four decimals")
check(OrbitEnergyFormat.period(priceRO.value.period, locale: us) == "Jan–Jun 2026", "Eurostat period text")
let explanation = OrbitEnergyFormat.sourceExplanation(priceRO.value, locale: us)
check(explanation.contains("Romania") && explanation.contains("Eurostat") && explanation.contains("Jan–Jun 2026"), "source explanation: \(explanation)")

let own = load(OrbitEnergyPrice.self, "price-own", in: directory)
roundTrips(own.value, own.raw, "price-own")
check(own.value.isOverride && own.value.pricePerKWh == 1.07 && own.value.currency == "RON" && own.value.period == nil, "own price: \(own.value)")
check(own.value.source == "Your own price" && own.value.detectedPrice?.pricePerKWh == 1.4573, "own price keeps the published average")
check(OrbitEnergyFormat.sourceExplanation(own.value, locale: us).hasPrefix("You entered"), "own price explanation")

let reset = load(OrbitEnergyPrice.self, "price-reset", in: directory)
check(reset.value == priceRO.value, "reset gives back the detected price")

let none = load(OrbitEnergyPrice.self, "price-none", in: directory)
roundTrips(none.value, none.raw, "price-none")
check(!none.value.hasPrice && none.value.currency == "JPY" && none.value.country == "JP" && none.value.detectedPrice == nil, "no price: \(none.value)")
check(OrbitEnergyFormat.pricePerKWh(none.value) == nil, "no price has no unit price text")
check(OrbitEnergyFormat.sourceExplanation(none.value, locale: us).contains("doesn't know"), "no-price explanation")
let unknown = load(OrbitEnergyPrice.self, "price-unknown", in: directory)
roundTrips(unknown.value, unknown.raw, "price-unknown")
check(unknown.value.country == nil && !unknown.value.hasPrice, "unknown country")

let settings = load(OrbitEnergySettings.self, "settings", in: directory)
roundTrips(settings.value, settings.raw, "settings")
check(settings.value == .defaults, "default settings are 60 W / 0.88 like the agent")
let savedSettings = load(OrbitEnergySettings.self, "settings-put", in: directory)
check(savedSettings.value == OrbitEnergySettings(baseWatts: 75, psuEfficiency: 0.9), "settings PUT reply: \(savedSettings.value)")
check(OrbitEnergyFormat.efficiencyLabel(0.88, locale: us) == "88%, like 80 PLUS Silver", "efficiency label")
check(OrbitEnergySettings(baseWatts: 75, psuEfficiency: 0.89 + 0.01 * 3).normalized == OrbitEnergySettings(baseWatts: 75, psuEfficiency: 0.92), "settings lose the stepping noise")
check(OrbitEnergySettings(baseWatts: 612.34, psuEfficiency: 1.0000000000000002).normalized == OrbitEnergySettings(baseWatts: 500, psuEfficiency: 1), "settings stay in the PC's ranges")
check(OrbitEnergySettings(baseWatts: .nan, psuEfficiency: 0.2).normalized == OrbitEnergySettings(baseWatts: 60, psuEfficiency: 0.5), "odd settings fall back or clamp")

// MARK: Energy months

let october = load(OrbitEnergyMonth.self, "energy-october", in: directory)
roundTrips(october.value, october.raw, "energy-october")
let oct = october.value
check(oct.monthID == OrbitMonthID(year: 2026, month: 10) && oct.currency == "RON" && oct.isEstimate, "october header")
check(oct.days.count == 10 && oct.days.first?.day == "2026-10-01" && oct.days.last?.day == "2026-10-10", "days 1 to today: \(oct.days.map(\.day))")
check(near(oct.days.reduce(0) { $0 + $1.kWh }, oct.kWh, 0.006), "days add up to the month")
check(near(oct.days.compactMap(\.cost).reduce(0, +), oct.cost, 0.06), "daily costs add up")
check(oct.games.map(\.name) == oct.games.sorted { $0.kWh > $1.kWh }.map(\.name), "games sorted by energy")
check(Set(oct.games.map(\.name)) == ["ELDEN RING", "Cyberpunk 2077", "BG3"], "game names: \(oct.games.map(\.name))")
check(oct.otherKWh > 0 && near(oct.otherKWh + oct.games.reduce(0) { $0 + $1.kWh }, oct.kWh, 0.006), "desktop share")
check(oct.hasReadings && (oct.coverage ?? 0) > 0.95 && (oct.coverage ?? 2) <= 1, "coverage: \(String(describing: oct.coverage))")
check(near(oct.breakdown?.total, oct.kWh, 0.006), "breakdown adds up to the wall energy")
check(oct.today != nil && oct.peakDay?.day == "2026-10-03", "today and peak day")
check(oct.available == ["2026-09", "2026-10"], "available months: \(oct.available)")
check(OrbitMonthID.pickerMonths(available: oct.available, including: oct.monthID).map(\.text) == ["2026-10", "2026-09"], "month picker")
check(oct.price == priceRO.value, "the month carries the price")
// The cost chart spans the whole month, so the first days' bars aren't stretched across it.
check(oct.chartDomain(calendar: utc) == utc.date(from: DateComponents(year: 2026, month: 10, day: 1))!...utc.date(from: DateComponents(year: 2026, month: 11, day: 1))!, "chart domain: \(String(describing: oct.chartDomain(calendar: utc)))")

let september = load(OrbitEnergyMonth.self, "energy-september", in: directory)
roundTrips(september.value, september.raw, "energy-september")
check(september.value.days.count == 30 && september.value.hasReadings, "september has every day")
check(september.value.games.map(\.name) == ["ELDEN RING"], "september games")

let future = load(OrbitEnergyMonth.self, "energy-future", in: directory)
roundTrips(future.value, future.raw, "energy-future")
check(future.value.days.isEmpty && !future.value.hasReadings && future.value.coverage == nil && future.value.peakDay == nil, "future month")

let noPrice = load(OrbitEnergyMonth.self, "energy-no-price", in: directory)
roundTrips(noPrice.value, noPrice.raw, "energy-no-price")
check(noPrice.value.cost == nil && noPrice.value.currency == nil && noPrice.value.days.allSatisfy { $0.cost == nil }, "month without a price")
check(OrbitEnergyFormat.cost(noPrice.value.cost, currency: noPrice.value.currency) == "—", "no cost text")
check(noPrice.value.otherCost == nil, "no cost outside games")

let ownMonth = load(OrbitEnergyMonth.self, "energy-own", in: directory)
roundTrips(ownMonth.value, ownMonth.raw, "energy-own")
check(ownMonth.value.cost == oct.cost && ownMonth.value.price?.isOverride == true, "a new price in the same currency keeps the days already recorded")

let euro = load(OrbitEnergyMonth.self, "energy-eur", in: directory)
roundTrips(euro.value, euro.raw, "energy-eur")
check(euro.value.currency == "EUR" && near(euro.value.cost, oct.kWh * 0.30, 0.03), "currency change re-prices the month: \(String(describing: euro.value.cost))")
check(euro.value.price?.isOverride == true && euro.value.price?.currency == "EUR", "month carries the own price")

// MARK: Monthly summaries

let summary = load(OrbitMonthSummary.self, "summary-october", in: directory)
roundTrips(summary.value, summary.raw, "summary-october")
let s = summary.value
check(s.hasPlay && s.monthID == OrbitMonthID(year: 2026, month: 10), "october summary has play")
check(s.topGame == s.games.first && s.topGame?.name == "ELDEN RING", "top game: \(String(describing: s.topGame?.name))")
check(s.games.map(\.playSeconds) == s.games.map(\.playSeconds).sorted(by: >), "games sorted by play time")
check(near(s.playSeconds, s.games.reduce(0) { $0 + $1.playSeconds }, 0.5), "play time adds up")
check(s.daysPlayed == 3 && s.sessions == 4, "days played \(s.daysPlayed), sessions \(s.sessions)")
check(s.longestSession?.name == "ELDEN RING" && s.longestSession?.date == "2026-10-03" && (s.longestSession?.seconds ?? 0) > 7200, "longest session: \(String(describing: s.longestSession))")
check(s.busiestDay?.day == "2026-10-03", "busiest day")
check(s.peakGPUTemp == 83 && s.peakCPUTemp == 88 && s.hottestGame?.name == "Cyberpunk 2077", "temperature peaks")
check(s.games.first { $0.name == "ELDEN RING" }?.averageFPS == 60, "average FPS")
check(near(s.energy?.kWh, oct.kWh, 0.0005) && near(s.energy?.cost, oct.cost, 0.0005) && s.energy?.currency == "RON", "summary energy matches the cost screen")
check(near(s.energy?.gamingKWh, oct.games.reduce(0) { $0 + $1.kWh }, 0.006), "gaming energy matches the games")
check(near(s.averagePricePerKWh, 1.4573, 0.01) && near(s.averageSessionSeconds, s.playSeconds / 4, 0.01), "average price and session: \(String(describing: s.averagePricePerKWh)) \(String(describing: s.averageSessionSeconds))")

let previous = load(OrbitMonthSummary.self, "summary-september", in: directory)
roundTrips(previous.value, previous.raw, "summary-september")
check(s.previous?.month == "2026-09" && near(s.previous?.playSeconds, previous.value.playSeconds, 0.5), "previous play time")
check(near(s.previous?.kWh, september.value.kWh, 0.0005), "previous energy matches september's cost screen")
check(s.playChange != nil && s.energyChange != nil, "comparisons with september")
check(previous.value.previous?.playSeconds == 0 && previous.value.playChange == nil, "nothing to compare before the first month")
// The versus page names what changed, and why there is nothing to compare with.
let versus = s.versusHeadline(previousName: "September", locale: us) ?? ""
check(versus.hasSuffix("more play time than September") && versus.first?.isNumber == true, "versus headline: \(versus)")
check(previous.value.versusHeadline(previousName: "August", locale: us) == "Your first month with Orbit counting", "first month headline")
var noGames = s
noGames.previous = .init(month: "2026-09", playSeconds: 0, kWh: 2.5)
check(noGames.playChange == nil && noGames.versusHeadline(previousName: "September", locale: us) == "No games in September", "a month of energy without games")
noGames.previous = .init(month: "2026-09", playSeconds: 30, kWh: 0.4)
check(noGames.playChange == nil && noGames.versusHeadline(previousName: "September", locale: us) == "No games in September", "30 seconds of a game is no play, as on the PC")
var gap = s
gap.previous = .init(month: "2026-09", playSeconds: 0, kWh: 0)
gap.available = ["2026-07", "2026-10"]
check(gap.versusHeadline(previousName: "September", locale: us) == "Nothing recorded in September", "a month without Orbit after earlier ones")
gap.available = ["2026-10"]
check(gap.versusHeadline(previousName: "September", locale: us) == "Your first month with Orbit counting", "the first month Orbit counted")
gap.previous = nil
check(gap.versusHeadline(previousName: "September", locale: us) == nil, "no previous month, no headline")

let empty = load(OrbitMonthSummary.self, "summary-empty", in: directory)
roundTrips(empty.value, empty.raw, "summary-empty")
check(!empty.value.hasPlay && empty.value.topGame == nil && empty.value.games.isEmpty && empty.value.longestSession == nil, "empty month")
check(empty.value.busiestDay == nil && empty.value.peakGPUTemp == nil && empty.value.hottestGame == nil && empty.value.topGameShare == nil, "empty month details")

// MARK: Session energy

let detailURL = directory.appendingPathComponent("session-detail.json")
let detailRaw = try! JSONSerialization.jsonObject(with: Data(contentsOf: detailURL)) as! [String: Any]
// Read the way SessionHistoryView reads it: leniently, so an odd "energy" never hides the session itself.
struct SessionDetailEnergy: Decodable { let energy: OrbitLenient<OrbitSessionEnergy>? }
let detail = try! JSONDecoder().decode(SessionDetailEnergy.self, from: Data(contentsOf: detailURL))
guard let sessionEnergy = detail.energy?.value, let rawEnergy = detailRaw["energy"] else { fail("session detail has no energy") }
roundTrips(sessionEnergy, rawEnergy, "session.energy")
check(sessionEnergy.kWh > 0 && sessionEnergy.currency == "RON" && sessionEnergy.cost != nil && sessionEnergy.coverage == 1, "session energy: \(sessionEnergy)")
check(sessionEnergy.hasTrackedTime, "a recorded session shows its energy")
check(OrbitEnergyFormat.energyAndCost(sessionEnergy, locale: us).contains(" · "), "session energy text")
let older = try! JSONDecoder().decode(SessionDetailEnergy.self, from: Data(contentsOf: directory.appendingPathComponent("session-detail-older.json")))
check(older.energy == nil, "older agents' details decode without energy")
let justStarted = load(SessionDetailEnergy.self, "session-detail-one-sample", in: directory)
guard let firstEnergy = justStarted.value.energy?.value, let firstRaw = (justStarted.raw as? [String: Any])?["energy"] else { fail("a one-sample session has no energy") }
roundTrips(firstEnergy, firstRaw, "session-one-sample.energy")
check(firstEnergy.kWh == 0 && firstEnergy.coverage == nil && !firstEnergy.hasTrackedTime, "a session without two readings shows no energy row: \(firstEnergy)")
for odd in [#"{"energy":{"kWh":"lots"}}"#, #"{"energy":[1,2]}"#, #"{"energy":null}"#, #"{"energy":{}}"#, #"{"energy":{"kWh":0.2,"cost":"x"}}"#] {
    guard let decoded = try? JSONDecoder().decode(SessionDetailEnergy.self, from: Data(odd.utf8)) else { fail("an odd energy value broke the session detail: \(odd)") }
    check(decoded.energy?.value == nil, "odd energy \(odd) should read as nothing")
}
check(OrbitEnergyFormat.sessionEnergyNote(OrbitSessionEnergy(kWh: 0.2, cost: nil, currency: nil, coverage: 0.5), locale: us)
        == "From the CPU and GPU power readings plus the rest of the PC. Power sensors answered 50% of the time, so it's on the low side.", "session note")

// MARK: Formatting, months and links

check(OrbitEnergyFormat.duration(9000) == "2 h 30 min" && OrbitEnergyFormat.duration(2700) == "45 min" && OrbitEnergyFormat.duration(3600) == "1 h", "durations")
check(OrbitEnergyFormat.duration(10) == "under a minute" && OrbitEnergyFormat.duration(0) == "0 min" && OrbitEnergyFormat.duration(400 * 3600) == "400 h", "short and long durations")
check(OrbitEnergyFormat.spokenDuration(3660) == "1 hour 1 minute" && OrbitEnergyFormat.spokenDuration(7200) == "2 hours", "spoken durations")
check(OrbitEnergyFormat.energy(12.4, locale: us) == "12.4 kWh" && OrbitEnergyFormat.energy(0.056, locale: us) == "0.056 kWh" && OrbitEnergyFormat.energy(0, locale: us) == "0 kWh", "energy text")
check(OrbitEnergyFormat.energy(312.4, locale: us) == "312 kWh", "large energy text")
check(plain(OrbitEnergyFormat.cost(0, currency: "RON", kWh: 0.003, locale: us)) == "less than RON 0.01", "tiny costs: \(OrbitEnergyFormat.cost(0, currency: "RON", kWh: 0.003, locale: us))")
// Free electricity (a price of 0, for example solar) costs nothing, never "less than".
check(plain(OrbitEnergyFormat.cost(0, currency: "RON", kWh: 0.003, pricePerKWh: 0, locale: us)) == "RON 0.00", "free electricity at a known price of 0")
check(plain(OrbitEnergyFormat.cost(0, currency: "RON", kWh: 12.4, locale: us)) == "RON 0.00", "a month at a price of 0 shows it in its own numbers")
check(plain(OrbitEnergyFormat.cost(0, currency: "RON", kWh: 0.003, pricePerKWh: 1.4573, locale: us)) == "less than RON 0.01", "a priced tiny use stays less than")
// Currencies without decimals: less than one unit, never "less than ¥0".
check(plain(OrbitEnergyFormat.cost(0.3, currency: "JPY", kWh: 0.01, locale: us)) == "less than ¥1", "yen: \(OrbitEnergyFormat.cost(0.3, currency: "JPY", kWh: 0.01, locale: us))")
check(plain(OrbitEnergyFormat.cost(0, currency: "ISK", kWh: 0.01, locale: us)) == "less than ISK 1", "krónur: \(OrbitEnergyFormat.cost(0, currency: "ISK", kWh: 0.01, locale: us))")
check(plain(OrbitEnergyFormat.cost(0, currency: "KRW", kWh: 2, locale: us)) == "₩0" && plain(OrbitEnergyFormat.cost(18.4, currency: "JPY", kWh: 0.6, locale: us)) == "¥18", "won at a price of 0, yen")
check(plain(OrbitEnergyFormat.cost(0, currency: "KWD", kWh: 0.1, locale: us)) == "less than KWD 0.010" && OrbitEnergyFormat.smallestAmount("jpy") == 1, "three-decimal currencies and the smallest amounts")
check(plain(OrbitEnergyFormat.approximateCost(18.1, currency: "RON", kWh: 12, locale: us)) == "about RON 18.10", "about a cost")
check(plain(OrbitEnergyFormat.approximateCost(0, currency: "RON", kWh: 0.003, locale: us)) == "less than RON 0.01" && plain(OrbitEnergyFormat.approximateCost(0, currency: "RON", kWh: 3, locale: us)) == "RON 0.00", "no about before less than or nothing")
check(OrbitEnergyFormat.approximateCost(nil, currency: nil) == "—", "no price, no cost")
check(OrbitEnergyFormat.cost(18.1, currency: "RON", locale: us).contains("18.10") && OrbitEnergyFormat.cost(18.1, currency: "RON", locale: us).contains("RON"), "cost with the ISO code")
check(OrbitEnergyFormat.unitPrice(0.1723, currency: "USD", locale: us) == "$0.1723", "dollar unit price")
check(OrbitEnergyFormat.period("2026-Q4", locale: us) == "Oct–Dec 2026" && OrbitEnergyFormat.period("2025", locale: us) == "2025" && OrbitEnergyFormat.period("2026-S2", locale: us) == "Jul–Dec 2026", "periods")
check(OrbitEnergyFormat.flag("RO") == "🇷🇴" && OrbitEnergyFormat.flag(nil) == "" && OrbitEnergyFormat.countryName("RO", locale: us) == "Romania", "country")
check(OrbitEnergyFormat.temperature(83.4) == "83 °C" && OrbitEnergyFormat.fps(59.6) == "60 FPS" && OrbitEnergyFormat.fps(nil) == "—", "temperature and FPS")
check(OrbitEnergyFormat.longDay("2026-10-03", locale: us) == "Saturday, October 3", "long day: \(OrbitEnergyFormat.longDay("2026-10-03", locale: us))")
check(OrbitMonthID("2026-13") == nil && OrbitMonthID("26-10") == nil && OrbitMonthID("2026-1") == nil && OrbitMonthID("x") == nil, "strict months")
check(OrbitMonthID("2026-01")!.shifted(by: -1).text == "2025-12" && OrbitMonthID("2026-12")!.shifted(by: 1).text == "2027-01", "month arithmetic")
check(OrbitMonthID("2026-10")!.title(locale: us) == "October 2026" && OrbitMonthID("2026-02")!.dayCount(calendar: utc) == 28, "month title and length")
check(OrbitChange(current: 120, previous: 100)?.percentText(locale: us) == "+20%" && OrbitChange(current: 80, previous: 100)?.percentText(locale: us) == "−20%", "change text")
check(OrbitChange(current: 120, previous: 100)?.sentence(versus: "September", locale: us) == "20% more than September", "change sentence")
check(OrbitChange(current: 120, previous: 100)?.sentence(versus: "September", of: "play time", locale: us) == "20% more play time than September"
      && OrbitChange(current: 100.2, previous: 100)?.sentence(versus: "September", of: "play time", locale: us) == "About the same play time as September", "change sentence naming what changed")
check(OrbitChange(current: 100.2, previous: 100)?.isSame == true && OrbitChange(current: 5, previous: 0) == nil, "same and nothing to compare")
check(OrbitEnergyPriceChange.isValid(price: 1.07, currency: "RON") && !OrbitEnergyPriceChange.isValid(price: -1, currency: "RON") && !OrbitEnergyPriceChange.isValid(price: 1, currency: "LE1"), "price validation")
check(!OrbitEnergyPriceChange.isValid(price: 1, currency: "VEF") && !OrbitEnergyPriceChange.isValid(price: 1, currency: "cuc"), "withdrawn currencies are refused, as the PC does")
check(OrbitEnergyPriceChange.parse("1.07") == 1.07 && OrbitEnergyPriceChange.parse("1,07") == 1.07 && OrbitEnergyPriceChange.parse(" 0,2632 ") == 0.2632, "typed prices")
check(OrbitEnergyPriceChange.parse("1,234.56") == 1234.56 && OrbitEnergyPriceChange.parse("1.234,56") == 1234.56 && OrbitEnergyPriceChange.parse("1 444,70") == 1444.7, "pasted prices with thousands")
check(OrbitEnergyPriceChange.parse("1,234,567") == 1_234_567 && OrbitEnergyPriceChange.parse("1444") == 1444 && OrbitEnergyPriceChange.parse(".5") == 0.5, "more prices")
check(OrbitEnergyPriceChange.parse("") == nil && OrbitEnergyPriceChange.parse("abc") == nil && OrbitEnergyPriceChange.parse("1.2.3,4,5") == nil && OrbitEnergyPriceChange.parse("-1") == nil, "not prices")
check(OrbitEnergyPriceChange.parse("١٫٥") == 1.5 && OrbitEnergyPriceChange.parse("١٬٢٣٤٫٥") == 1234.5 && OrbitEnergyPriceChange.parse("۰٫۲۵") == 0.25, "Arabic and Persian digits")
check(OrbitEnergyPriceChange.parse("１.５") == 1.5 && OrbitEnergyPriceChange.parse("1e5") == nil && OrbitEnergyPriceChange.parse(",") == nil, "full-width digits, no exponents")

let alertDate = utc.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9))!
let link = OrbitEnergyAPI.summaryLink(month: OrbitEnergyAPI.summaryMonth(forAlertDeliveredAt: alertDate, calendar: utc), pcID: "pc-1")
check(link == "orbit://summary?month=2026-10&pc=pc-1", "summary link: \(link)")
let parts = OrbitEnergyAPI.summaryLinkParts(URL(string: link)!)
check(parts?.pcID == "pc-1" && parts?.month?.text == "2026-10", "summary link parts")
check(OrbitEnergyAPI.summaryLinkParts(URL(string: "orbit://notifications")!) == nil, "other links are not summaries")
// A tapped alert: summary.ready opens that month's summary for the PC that sent it; other kinds keep their link.
check(OrbitEnergyAPI.alertLink(kind: "summary.ready", pcID: "pc-1", deliveredAt: alertDate, calendar: utc) == link, "summary.ready alert link")
check(OrbitEnergyAPI.alertLink(kind: "download.finished", pcID: "pc-1", deliveredAt: alertDate, calendar: utc) == nil
      && OrbitEnergyAPI.alertLink(kind: nil, pcID: nil, deliveredAt: alertDate, calendar: utc) == nil, "other alerts keep their own link")
check(OrbitEnergyAPI.alertLink(kind: "summary.ready", pcID: nil, deliveredAt: alertDate, calendar: utc) == "orbit://summary?month=2026-10", "alert without a PC id")
check(OrbitEnergyAPI.summaryMonth(forAlertDeliveredAt: utc.date(from: DateComponents(year: 2027, month: 1, day: 3))!, calendar: utc).text == "2026-12", "January alert is about December")
// A phone in a time zone behind the PC's still shows October 31 when the PC announces October.
check(OrbitEnergyAPI.summaryMonth(forAlertDeliveredAt: utc.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 20))!, calendar: utc).text == "2026-10", "alert on the phone's October 31 is about October")
// The latest an announcement can arrive: day 7 at midnight on the PC, 12 hours late, a phone 26 hours ahead.
check(OrbitEnergyAPI.summaryMonth(forAlertDeliveredAt: utc.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 14))!, calendar: utc).text == "2026-10", "a late November alert is still about October")

// MARK: Demo data

let today = utc.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 15))!
let demoMonth = OrbitEnergyDemo.energyMonth(nil, today: today, calendar: utc)
let demoSummary = OrbitEnergyDemo.summary(nil, today: today, calendar: utc)
let demoData = try! JSONEncoder().encode(demoMonth)
check(try! JSONDecoder().decode(OrbitEnergyMonth.self, from: demoData) == demoMonth, "demo month round trip")
check(try! JSONDecoder().decode(OrbitMonthSummary.self, from: JSONEncoder().encode(demoSummary)) == demoSummary, "demo summary round trip")
check(demoMonth.month == "2026-10" && demoMonth.days.count == 24 && demoMonth.available == ["2026-08", "2026-09", "2026-10"], "demo month header")
check(near(demoMonth.days.reduce(0) { $0 + $1.kWh }, demoMonth.kWh, 0.03) && near(demoMonth.cost, demoMonth.kWh * OrbitEnergyDemo.pricePerKWh, 0.02), "demo month adds up")
check(near(demoMonth.breakdown?.total, demoMonth.kWh, 0.01) && demoMonth.games.count >= 3 && demoMonth.otherKWh > 0, "demo breakdown and games")
check((5...60).contains(demoMonth.kWh) && (10...200).contains(demoMonth.trackedHours ?? 0), "demo month is realistic: \(demoMonth.kWh) kWh")
check(demoSummary.hasPlay && near(demoSummary.energy?.kWh, demoMonth.kWh, 0.0005) && demoSummary.topGame == demoSummary.games.first, "demo summary matches the demo month")
check(near(demoSummary.playSeconds, demoSummary.games.reduce(0) { $0 + $1.playSeconds }, 0.5) && demoSummary.daysPlayed <= 24, "demo play adds up")
let demoSeptember = OrbitEnergyDemo.energyMonth(OrbitMonthID("2026-09"), today: today, calendar: utc)
check(near(demoSummary.previous?.kWh, demoSeptember.kWh, 0.0005) && demoSeptember.days.count == 30, "demo previous month")
check(near(demoSummary.previous?.playSeconds, OrbitEnergyDemo.summary(OrbitMonthID("2026-09"), today: today, calendar: utc).playSeconds, 0.5), "demo previous play")
let demoOld = OrbitEnergyDemo.energyMonth(OrbitMonthID("2026-07"), today: today, calendar: utc)
check(!demoOld.hasReadings && demoOld.days.count == 31 && !OrbitEnergyDemo.summary(OrbitMonthID("2026-07"), today: today, calendar: utc).hasPlay, "months before the demo history are empty")
check(OrbitEnergyDemo.energyMonth(OrbitMonthID("2026-11"), today: today, calendar: utc).days.isEmpty, "demo future month")
let firstMinute = utc.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 5))!
_ = OrbitEnergyDemo.summary(nil, today: firstMinute, calendar: utc)
_ = OrbitEnergyDemo.energyMonth(nil, today: firstMinute, calendar: utc)
// Demo mode re-prices the sample months with the price and settings the person enters.
check(OrbitEnergyDemo.energyMonth(nil, today: today, calendar: utc, price: OrbitEnergyDemo.price, settings: .defaults) == demoMonth, "the defaults give the sample month")
var euroPrice = OrbitEnergyDemo.price
euroPrice.pricePerKWh = 0.30
euroPrice.currency = "EUR"
euroPrice.isOverride = true
let demoEuro = OrbitEnergyDemo.energyMonth(nil, today: today, calendar: utc, price: euroPrice)
check(demoEuro.currency == "EUR" && demoEuro.kWh == demoMonth.kWh && near(demoEuro.cost, demoEuro.kWh * 0.30, 0.02) && demoEuro.price == euroPrice, "demo month at another price: \(String(describing: demoEuro.cost))")
check(demoEuro.days.allSatisfy { near($0.cost, $0.kWh * 0.30, 0.006) } && near(demoEuro.today?.cost, (demoEuro.today?.kWh ?? 0) * 0.30, 0.006), "demo days at another price")
check(demoEuro.games.allSatisfy { near($0.cost, $0.kWh * 0.30, 0.006) }, "demo games at another price")
let demoSummaryEuro = OrbitEnergyDemo.summary(nil, today: today, calendar: utc, price: euroPrice)
check(demoSummaryEuro.energy?.currency == "EUR" && near(demoSummaryEuro.energy?.cost, demoEuro.cost, 0.0005) && demoSummaryEuro.playSeconds == demoSummary.playSeconds, "demo summary at another price")
let hours = demoMonth.trackedHours ?? 0
let measuredKWh = (demoMonth.breakdown?.cpuKWh ?? 0) + (demoMonth.breakdown?.gpuKWh ?? 0)
let heavier = OrbitEnergyDemo.energyMonth(nil, today: today, calendar: utc, settings: OrbitEnergySettings(baseWatts: 120, psuEfficiency: 0.88))
let efficient = OrbitEnergyDemo.energyMonth(nil, today: today, calendar: utc, settings: OrbitEnergySettings(baseWatts: 60, psuEfficiency: 0.95))
check(heavier.kWh > demoMonth.kWh && efficient.kWh < demoMonth.kWh, "demo energy follows the settings: \(heavier.kWh) \(demoMonth.kWh) \(efficient.kWh)")
check(near(heavier.kWh, (measuredKWh + 120 * hours / 1000) / 0.88, 0.02) && near(heavier.breakdown?.baseKWh, 120 * hours / 1000, 0.01), "wall = (CPU + GPU + rest of the PC) / efficiency")
check(near(heavier.breakdown?.total, heavier.kWh, 0.01) && near(efficient.breakdown?.total, efficient.kWh, 0.01) && near(heavier.cost, heavier.kWh * OrbitEnergyDemo.pricePerKWh, 0.02), "demo breakdown with other settings")
let heavierSummary = OrbitEnergyDemo.summary(nil, today: today, calendar: utc, settings: OrbitEnergySettings(baseWatts: 120, psuEfficiency: 0.88))
check(near(heavierSummary.energy?.kWh, heavier.kWh, 0.0005) && near(heavierSummary.previous?.kWh, OrbitEnergyDemo.energyMonth(OrbitMonthID("2026-09"), today: today, calendar: utc, settings: OrbitEnergySettings(baseWatts: 120, psuEfficiency: 0.88)).kWh, 0.0005), "demo summary with other settings")
var unpriced = OrbitEnergyDemo.price
unpriced.pricePerKWh = nil
let demoUnpriced = OrbitEnergyDemo.energyMonth(nil, today: today, calendar: utc, price: unpriced)
check(demoUnpriced.cost == nil && demoUnpriced.currency == nil && demoUnpriced.days.allSatisfy { $0.cost == nil } && demoUnpriced.games.allSatisfy { $0.cost == nil }, "demo month without a price")
var freePrice = OrbitEnergyDemo.price
freePrice.pricePerKWh = 0
let demoFree = OrbitEnergyDemo.energyMonth(nil, today: today, calendar: utc, price: freePrice)
check(demoFree.cost == 0 && plain(OrbitEnergyFormat.cost(demoFree.cost, currency: demoFree.currency, kWh: demoFree.kWh, pricePerKWh: 0, locale: us)) == "RON 0.00", "demo month with free electricity")
OrbitEnergyDemoEdits.apply(.set(0.30, currency: "eur"))
check(OrbitEnergyDemoEdits.price.isOverride && OrbitEnergyDemoEdits.price.currency == "EUR" && OrbitEnergyDemoEdits.price.source == "Your own price"
      && OrbitEnergyDemoEdits.price.detectedPrice?.pricePerKWh == 1.4573, "demo price edit: \(OrbitEnergyDemoEdits.price)")
check(OrbitEnergyDemoEdits.energyMonth().currency == "EUR" && OrbitEnergyDemoEdits.summary().energy?.currency == "EUR", "demo screens follow the edited price")
OrbitEnergyDemoEdits.apply(.resetToDetected)
check(OrbitEnergyDemoEdits.price == OrbitEnergyDemo.price && OrbitEnergyDemoEdits.energyMonth().currency == "RON", "demo price reset")

// MARK: Share picture

for (name, value) in [("agent", s), ("demo", demoSummary)] {
    // The Share button's item draws only a preview; the PNG is drawn when the share sheet asks for it.
    guard let picture = OrbitSummaryPicture.make(value, accent: .cyan, secondary: .blue) else { fail("the \(name) share item did not render") }
    guard let png = picture.pngData(), let size = pngSize(png) else { fail("the \(name) share picture is not a PNG") }
    check(size == (1080, 1350) && png.count > 20_000, "\(name) share picture is \(size), \(png.count) bytes")
    check(picture.fileName.hasPrefix("Orbit ") && picture.fileName.hasSuffix(".png"), "file name \(picture.fileName)")
    if #available(macOS 15.2, *) {
        // What a share sheet gets: the same picture through the Transferable export.
        let exported = try! await picture.exported(as: .png)
        check(pngSize(exported).map { $0 == (1080, 1350) } == true && exported.count > 20_000, "the \(name) picture the share sheet gets is \(String(describing: pngSize(exported)))")
    }
    if arguments.count > 3 {
        try! png.write(to: URL(fileURLWithPath: arguments[3]).appendingPathComponent("share-\(name).png"))
    }
}

print("PASS: the agent's electricity price, settings, monthly energy (this month, last month, future, no price, another currency), monthly summaries (with play, previous month, empty) and session energy (recorded, one reading, odd values) decode into the app's models key for key; the app's own price/settings bodies, every currency its editor offers and every stepper value are accepted; the two summaries agree; price parsing, formatting (free electricity, currencies without decimals), versus headlines, month links, demo data (re-priced with edited prices and settings) and the 1080 × 1350 share picture (also as the share sheet exports it) check out")
'''


def utc(text):
    return calendar.timegm(time.strptime(text, "%Y-%m-%d %H:%M:%S"))


def utc_day(timestamp):
    return time.strftime("%Y-%m-%d", time.gmtime(timestamp))


class Clock:
    def __init__(self, start):
        self.now = float(start)

    def __call__(self):
        return self.now


def acf(appid, name, installdir):
    return ('"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"installdir"\t\t"%s"\n\t"StateFlags"\t\t"4"\n}\n'
            % (appid, name, installdir))


def fail(message):
    raise SystemExit(f"FAIL: {message}")


def build_payloads(out, bodies):
    with tempfile.TemporaryDirectory(prefix="orbit-energy-agent-") as data_dir:
        data = Path(data_dir)
        steam = data / "Steam"
        elden_exe = steam / "steamapps" / "common" / "ELDEN RING" / "Game" / "eldenring.exe"
        elden_exe.parent.mkdir(parents=True)
        (steam / "steamapps" / "appmanifest_1245620.acf").write_text(acf(1245620, "ELDEN RING", "ELDEN RING"), encoding="utf-8")
        (data / "Epic").mkdir()
        environment = {"LOCALAPPDATA": str(data / "LocalAppData"), "ORBIT_ENERGY_PRICE_REFRESH": "0",
                       "ORBIT_STEAM_LIBRARIES": str(steam), "ORBIT_STEAM_PATH": "", "ORBIT_EPIC_MANIFESTS": str(data / "Epic")}
        with patch.dict(os.environ, environment):
            try:
                import orbit_settings
                import orbit_energy as energy
                import orbit_summary as summary
                import orbit_history
                from fastapi import FastAPI
                from fastapi.testclient import TestClient
            except Exception as error:
                fail(f"the agent's Python dependencies are missing ({type(error).__name__}: {error}); "
                     "run with /Users/dimitrie2005/Downloads/Orbit-main/output/.recovery-test-venv/bin/python3")
            store = orbit_settings.SettingsStore(data / "settings.json")
            orbit_settings.set_shared_store(store)
            import orbit_agent as agent

            wall = Clock(utc("2026-09-05 18:00:00"))
            mono = Clock(10_000)
            ledger = energy.Ledger(data / "ledger.sqlite3")
            names = summary.GameNames(process_lookup=lambda process: str(elden_exe) if process.lower() == "eldenring.exe" else None)
            tracker = summary.GameTracker(ledger, names=names, emit=lambda *a, **k: {"id": 1}, alerts_allow=lambda: False,
                                          day_of=utc_day, log_ready=lambda: True)
            runtime = energy.LedgerRuntime(ledger, [energy.EnergyTracker(ledger), tracker],
                                           price_provider=lambda: energy.current_price(store),
                                           settings_provider=lambda: energy.energy_settings(store),
                                           clock=wall, monotonic=mono, day_of=utc_day)
            patches = [patch.object(energy, "COUNTRY", energy.CountryResolver(detector=lambda: "RO", currency_detector=lambda code: None)),
                       patch.object(energy, "PRICE_TABLE", energy.PriceTable(data / "energy-prices.json")),
                       patch.object(energy, "_RUNTIME", runtime),
                       patch.object(agent, "API_TOKEN", TOKEN)]
            for item in patches:
                item.start()
            try:
                feed_ledger(runtime, wall, mono)
                write_agent_payloads(out, bodies, agent, energy, TestClient)
                write_builder_payloads(out, data, energy, store)
                write_session_payloads(out, data, energy, orbit_history, FastAPI, TestClient, wall)
            finally:
                for item in reversed(patches):
                    item.stop()
                runtime.close()
                orbit_settings.set_shared_store(None)


def feed_ledger(runtime, wall, mono):
    """Two months of a gaming PC, one telemetry tick every 5 s, through the agent's own trackers."""
    desktop = {"activeGameProcess": None, "cpuPowerWatts": 28, "gpuPowerWatts": 18, "cpuTemp": 45, "gpuTemp": 40}
    elden = {"activeGameProcess": "eldenring.exe", "cpuPowerWatts": 95, "gpuPowerWatts": 260, "fps": 60, "cpuTemp": 76, "gpuTemp": 72}
    cyberpunk = {"activeGameProcess": "Cyberpunk2077.exe", "cpuPowerWatts": 120, "gpuPowerWatts": 300, "fps": 92, "cpuTemp": 88, "gpuTemp": 83}
    bg3 = {"activeGameProcess": "bg3.exe", "cpuPowerWatts": 90, "gpuPowerWatts": 240, "fps": 110, "cpuTemp": 79, "gpuTemp": 74}

    def run(start, seconds, snapshot):
        wall.now = utc(start)
        elapsed = 0
        while elapsed < seconds:
            mono.now += 5
            runtime.record({"telemetryAvailable": True, **snapshot})
            wall.now += 5
            elapsed += 5

    run("2026-09-05 18:00:00", 3600, elden)
    run("2026-09-20 10:00:00", 2 * 3600, desktop)
    run("2026-10-01 17:00:00", 3600, desktop)
    run("2026-10-01 18:00:00", 90 * 60, cyberpunk)
    run("2026-10-03 14:00:00", 70 * 60, elden)
    run("2026-10-03 15:13:00", 50 * 60, elden)  # a 3-minute pause: still one session
    run("2026-10-03 16:10:00", 6 * 60, bg3)
    run("2026-10-04 20:00:00", 40, cyberpunk)  # a launch that crashed: not a session, not a day played
    run("2026-10-10 09:00:00", 30 * 60, desktop)
    run("2026-10-10 09:30:00", 30 * 60, elden)
    if not runtime.flush():
        fail("the ledger did not flush")


def write_agent_payloads(out, bodies, agent, energy, TestClient):
    client = TestClient(agent.app, base_url="https://testserver")
    headers = {"Authorization": f"Bearer {TOKEN}"}

    def save(name, response, status=200):
        if response.status_code != status:
            fail(f"{name}: HTTP {response.status_code} {response.text}")
        (out / f"{name}.json").write_text(response.text)
        return response.json()

    def body(name):
        return (bodies / name).read_bytes()

    json_headers = {**headers, "Content-Type": "application/json"}
    save("price", client.get("/api/energy/price", headers=headers))
    save("settings", client.get("/api/energy/settings", headers=headers))
    october = save("energy-october", client.get("/api/energy/summary", headers=headers))
    save("energy-september", client.get("/api/energy/summary", params={"month": "2026-09"}, headers=headers))
    save("energy-future", client.get("/api/energy/summary", params={"month": "2026-12"}, headers=headers))
    wrapped = save("summary-october", client.get("/api/summary", headers=headers))
    save("summary-september", client.get("/api/summary", params={"month": "2026-09"}, headers=headers))
    save("summary-empty", client.get("/api/summary", params={"month": "2026-08"}, headers=headers))
    if october["month"] != "2026-10" or wrapped["month"] != "2026-10":
        fail("the default month should be the PC's current month")
    for path in ("/api/energy/summary", "/api/summary"):
        response = client.get(path, params={"month": "2026-13"}, headers=headers)
        if response.status_code != 422 or not isinstance(response.json().get("detail"), str):
            fail(f"{path}?month=2026-13 answered {response.status_code} {response.text}")
    # The app's own bodies, byte for byte.
    save("price-own", client.put("/api/energy/price", content=body("put-price-own.json"), headers=json_headers))
    save("energy-own", client.get("/api/energy/summary", headers=headers))
    save("price-eur", client.put("/api/energy/price", content=body("put-price-eur.json"), headers=json_headers))
    save("energy-eur", client.get("/api/energy/summary", headers=headers))
    save("price-reset", client.put("/api/energy/price", content=body("put-price-reset.json"), headers=json_headers))
    save("settings-put", client.put("/api/energy/settings", content=body("put-settings.json"), headers=json_headers))
    refused = client.put("/api/energy/price", json={"pricePerKWh": 1.0, "currency": "LEI"}, headers=headers)
    if refused.status_code != 422 or "three-letter" not in refused.json().get("detail", ""):
        fail(f"an unknown currency answered {refused.status_code} {refused.text}")
    offered = json.loads(body("currencies.json"))
    rejected = [code for code in offered if not energy.is_currency_code(code)]
    if rejected:
        fail(f"the price editor offers currencies the PC refuses: {rejected}")
    steps = json.loads(body("settings-steps.json"))
    refused_steps = []
    for step in steps:
        try:
            energy.validate_settings_update(step)
        except ValueError as error:
            refused_steps.append((step, str(error)))
    if refused_steps or len(steps) < 200:
        fail(f"the PC refuses settings the steppers can send: {refused_steps[:5]}")
    plain = TestClient(agent.app, base_url="http://testserver").get("/api/energy/summary", headers=headers)
    if plain.status_code != 426:
        fail(f"/api/energy/summary over http answered {plain.status_code}")
    # What the trackers made of the scenario (agent rules, checked here so a change shows up plainly).
    games = {game["name"]: game for game in wrapped["games"]}
    if set(games) != {"ELDEN RING", "Cyberpunk 2077", "BG3"} or games["ELDEN RING"]["daysPlayed"] != 2:
        fail(f"unexpected games {sorted(games)}")
    if wrapped["daysPlayed"] != 3 or wrapped["sessions"] != 4 or wrapped["longestSession"]["date"] != "2026-10-03":
        fail(f"unexpected days/sessions/longest {wrapped['daysPlayed']} {wrapped['sessions']} {wrapped['longestSession']}")


def write_builder_payloads(out, data, energy, store):
    def dump(name, value):
        (out / f"{name}.json").write_text(json.dumps(value, allow_nan=False))

    dump("price-none", energy.resolve_price("JP", None, {}, currency_hint=lambda code: "JPY"))
    unknown = energy.resolve_price(None, None, {})
    dump("price-unknown", unknown)
    # A ledger recorded before any price existed, reported without one.
    ledger = energy.Ledger(data / "no-price.sqlite3")
    try:
        with ledger.transaction() as db:
            db.execute("""INSERT INTO energy_daily (day, game, cpu_wh, gpu_wh, base_wh, wall_wh, seconds, measured_seconds, cost, currency)
                          VALUES ('2026-10-01', '', 20, 10, 60, 102.3, 3600, 3600, NULL, NULL)""")
        dump("energy-no-price", energy.energy_month(ledger, 2026, 10, unknown, today="2026-10-02"))
    finally:
        ledger.close()


def write_session_payloads(out, data, energy, orbit_history, FastAPI, TestClient, wall):
    clock = Clock(utc("2026-10-10 20:00:00"))
    recorder = orbit_history.SessionRecorder(data / "history.sqlite3", clock=clock)
    try:
        session = recorder.start("Evening game")
        for _ in range(30):
            clock.now += 5
            recorder.record_sample({"telemetryAvailable": True, "cpuPowerWatts": 110, "gpuPowerWatts": 280, "fps": 90})
        recorder.stop()
        clock.now += 60
        first = recorder.start("Just started")
        clock.now += 5
        recorder.record_sample({"telemetryAvailable": True, "cpuPowerWatts": 110, "gpuPowerWatts": 280, "fps": 90})
        recorder.stop()
        for name, extras, target in (("session-detail", energy.session_energy_extras, session),
                                     ("session-detail-older", None, session),
                                     ("session-detail-one-sample", energy.session_energy_extras, first)):
            app = FastAPI()
            app.include_router(orbit_history.create_history_router(lambda authorization=None: None, lambda: recorder, detail_extras=extras))
            response = TestClient(app, base_url="https://testserver").get(f"/api/history/sessions/{target['id']}")
            if response.status_code != 200:
                fail(f"{name}: HTTP {response.status_code} {response.text}")
            if (extras is None) == ("energy" in response.json()):
                fail(f"{name}: unexpected energy key")
            (out / f"{name}.json").write_text(response.text)
    finally:
        recorder.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--png", type=Path, help="folder to keep the rendered share pictures in")
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="orbit-energy-contract-") as directory:
        root = Path(directory)
        payloads = root / "payloads"
        bodies = root / "bodies"
        payloads.mkdir()
        bodies.mkdir()
        (root / "main.swift").write_text(SWIFT_CHECK)
        binary = root / "energy-check"
        subprocess.run([
            "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-target", f"{platform.machine()}-apple-macos14.0",
            str(ROOT / "Orbit-iOS/Shared/OrbitEnergy.swift"),
            str(ROOT / "Orbit-iOS/Shared/OrbitSummaryShareCard.swift"),
            str(root / "main.swift"), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary), "--bodies", str(bodies)], check=True, timeout=60)
        build_payloads(payloads, bodies)
        command = [str(binary), "--check", str(payloads)]
        if options.png:
            options.png.mkdir(parents=True, exist_ok=True)
            command.append(str(options.png))
        subprocess.run(command, check=True, timeout=120)


if __name__ == "__main__":
    main()
