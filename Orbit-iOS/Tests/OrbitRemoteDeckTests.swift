import Foundation

// Driven by check_remote_deck.py: `OrbitRemoteDeckTests <deck.json> <capabilities.json>`.
// Covers the deck model the Watch, Mac and Apple TV share (Shared/OrbitRemoteDeck.swift) and the
// iPhone → Watch sync payload (Orbit/OrbitWatchDeckSync.swift), without a PC or a simulator.

private struct FakeHTTPError: LocalizedError {
    let status: Int
    let detail: String
    var errorDescription: String? { detail }
}

private final class CallLog: @unchecked Sendable {
    var paths: [String] = []
}

@main
private struct OrbitRemoteDeckTests {
    static func main() async throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 3, "usage: OrbitRemoteDeckTests <deck.json> <capabilities.json>")
        let deckData = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let capabilitiesData = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))

        let deck = try decodesTheContractAndSkipsBrokenButtons(deckData)
        try roundTripKeepsUnknownFields(deckData, deck: deck)
        watchPayloadMatchesTheFullDeck(deckData, deck: deck)
        watchPayloadStates()
        try runPathsAndProLimit(deckData)
        cachedDeckFormats(deckData)
        actionDescriptions()
        await serviceLoadOutcomes(deckData: deckData, capabilities: capabilitiesData)
        await serviceRunOutcomes()
        print("PASS: deck contract decoding, unknown fields kept on save, iPhone→Watch payload, Pro limit, cached formats, confirmations and summaries, capability detection and run errors")
    }

    static func decodesTheContractAndSkipsBrokenButtons(_ data: Data) throws -> OrbitRemoteDeck {
        let deck = try JSONDecoder().decode(OrbitRemoteDeck.self, from: data)
        precondition(!deck.buttons.isEmpty, "the fixture must have buttons")
        precondition(Set(deck.buttons.map(\.id)).count == deck.buttons.count, "ids must be unique")
        precondition(deck.buttons.allSatisfy { OrbitRemoteDeck.isValidButtonID($0.id) })

        // One unreadable button never hides the others.
        let messy = """
        {"buttons":[{"title":"no id"},{"id":"../x","title":"bad id"},{"id":"ok-1","title":"Fine","action":{"type":"media","name":"next"}},
        {"id":"ok-1","title":"Duplicate"},"not an object",{"id":"ok-2"}],"updatedAt":"2026-10-24T10:00:00Z"}
        """
        let cleaned = try JSONDecoder().decode(OrbitRemoteDeck.self, from: Data(messy.utf8))
        precondition(cleaned.buttons.map(\.id) == ["ok-1", "ok-2"], "\(cleaned.buttons.map(\.id))")
        precondition(cleaned.buttons[0].title == "Fine" && cleaned.buttons[1].displayTitle == "Button")
        precondition(cleaned.updatedAt == "2026-10-24T10:00:00Z")
        let empty = try JSONDecoder().decode(OrbitRemoteDeck.self, from: Data("{}".utf8))
        precondition(empty.buttons.isEmpty)
        return deck
    }

    /// The Mac saves with `PUT /api/deck` (full replace): fields it does not know must survive.
    static func roundTripKeepsUnknownFields(_ data: Data, deck: OrbitRemoteDeck) throws {
        let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let originalButtons = (original["buttons"] as! [[String: Any]]).filter { OrbitRemoteDeck.isValidButtonID($0["id"] as? String ?? "") }
        let encoded = try JSONEncoder().encode(deck.buttons.map(\.json))
        let again = try JSONSerialization.jsonObject(with: encoded) as! [[String: Any]]
        precondition(again.count == originalButtons.count)
        for (before, after) in zip(originalButtons, again) {
            var expected = before
            if expected["confirm"] as? Bool == false { expected.removeValue(forKey: "confirm") }
            precondition(NSDictionary(dictionary: expected).isEqual(to: after), "button changed on round trip:\n\(before)\n\(after)")
        }
        // Integers stay integers (`delayMs: 200`, not `200.0`).
        let sequence = OrbitRemoteDeckButton(json: .object([
            "id": .string("seq"), "title": .string("Clip"), "symbol": .string("film"), "color": .string("#30D158"),
            "action": .object(["type": .string("sequence"), "delayMs": .int(200), "steps": .array([])]),
            "futureField": .object(["nested": .array([.bool(true), .null, .number(1.5)])])
        ]))!
        let text = String(decoding: try JSONEncoder().encode(sequence.json), as: UTF8.self)
        precondition(text.contains("\"delayMs\":200") && !text.contains("200.0"), text)
        precondition(text.contains("futureField") && text.contains("1.5"), text)
    }

    static func watchPayloadMatchesTheFullDeck(_ data: Data, deck: OrbitRemoteDeck) {
        let cached = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let payload = OrbitWatchDeckSync.payload(pcID: "pc-1", isPro: true, isDemo: false, cached: cached)
        precondition(payload["pcID"] as? String == "pc-1" && payload["cached"] as? Bool == true && payload["isPro"] as? Bool == true)
        precondition(PropertyListSerialization.propertyList(payload, isValidFor: .binary), "WatchConnectivity needs property-list values")
        let summaries = payload["buttons"] as! [[String: Any]]
        let watchButtons = summaries.compactMap(OrbitRemoteDeckButton.init(watchSummary:))
        precondition(watchButtons.count == deck.buttons.count)
        for (full, watch) in zip(deck.buttons, watchButtons) {
            precondition(full.id == watch.id && full.displayTitle == watch.displayTitle)
            precondition(full.symbol == watch.symbol && full.color == watch.color)
            precondition(full.needsConfirmation == watch.needsConfirmation, "confirmation differs for \(full.id)")
            precondition(full.powerAction == watch.powerAction, "power action differs for \(full.id)")
            precondition(full.actionType == watch.actionType)
        }
        precondition(deck.buttons.contains { $0.needsConfirmation }, "the fixture must have a power button")
        let size = try! PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0).count
        precondition(size < 16_000, "deck payload too large for WatchConnectivity: \(size) bytes")

        // 64 long buttons stay well inside the WatchConnectivity budget.
        let big: [[String: Any]] = (0..<80).map { index in
            ["id": "button-\(index)", "title": String(repeating: "T", count: 300), "symbol": String(repeating: "s", count: 300),
             "color": "#FFFFFFFF00", "action": ["type": "text", "text": String(repeating: "x", count: 5000)]]
        }
        let bigPayload = OrbitWatchDeckSync.payload(pcID: "pc", isPro: false, isDemo: false, cached: ["buttons": big])
        let bigButtons = bigPayload["buttons"] as! [[String: Any]]
        precondition(bigButtons.count == OrbitWatchDeckSync.maxButtons)
        let bigSize = try! PropertyListSerialization.data(fromPropertyList: bigPayload, format: .binary, options: 0).count
        precondition(bigSize < 24_000, "worst-case deck payload is \(bigSize) bytes")
    }

    static func watchPayloadStates() {
        let demo = OrbitWatchDeckSync.payload(pcID: "pc", isPro: false, isDemo: true, cached: ["buttons": [["id": "real"]]])
        precondition(demo["demo"] as? Bool == true && (demo["buttons"] as! [Any]).isEmpty, "demo mode never sends real buttons")
        let missing = OrbitWatchDeckSync.payload(pcID: "pc", isPro: false, isDemo: false, cached: nil)
        precondition(missing["cached"] as? Bool == false && (missing["buttons"] as! [Any]).isEmpty)
        let duplicates = OrbitWatchDeckSync.payload(pcID: "pc", isPro: false, isDemo: false,
                                                    cached: ["buttons": [["id": "a"], ["id": "a"], ["id": "b c"], ["title": "x"]]])
        precondition((duplicates["buttons"] as! [[String: Any]]).map { $0["id"] as! String } == ["a"])
        precondition(OrbitRemoteDeckButton(watchSummary: ["id": "x/y"]) == nil)
        let sleep = OrbitRemoteDeckButton(watchSummary: ["id": "s", "type": "sequence", "power": "shutdown", "confirm": true])!
        precondition(sleep.powerAction == "shutdown" && sleep.needsConfirmation && sleep.confirmationButton == "Shut Down PC")
    }

    static func runPathsAndProLimit(_ data: Data) throws {
        let cached: [String: Any] = ["buttons": (0..<8).map { ["id": "b\($0)", "action": ["type": "system", "name": $0 == 7 ? "restart" : "lock"]] }]
        let first = try OrbitWatchDeckSync.runPath(buttonID: "b0", cached: cached, isPro: false)
        let sixth = try OrbitWatchDeckSync.runPath(buttonID: "b5", cached: cached, isPro: false)
        precondition(first == "/api/deck/buttons/b0/run" && sixth == "/api/deck/buttons/b5/run")
        do {
            _ = try OrbitWatchDeckSync.runPath(buttonID: "b6", cached: cached, isPro: false)
            preconditionFailure("the 7th button needs Orbit Pro")
        } catch let error as OrbitError { precondition(error.message.contains("Orbit Pro")) }
        let seventhWithPro = try OrbitWatchDeckSync.runPath(buttonID: "b6", cached: cached, isPro: true)
        let uncached = try OrbitWatchDeckSync.runPath(buttonID: "unknown", cached: cached, isPro: false)
        precondition(seventhWithPro == "/api/deck/buttons/b6/run" && uncached == "/api/deck/buttons/unknown/run")
        for bad: String? in [nil, "", "../b0", "b0/run", "b0?x", String(repeating: "a", count: 65)] {
            do {
                _ = try OrbitWatchDeckSync.runPath(buttonID: bad, cached: cached, isPro: true)
                preconditionFailure("invalid id accepted: \(String(describing: bad))")
            } catch is OrbitError {}
        }
        precondition(OrbitWatchDeckSync.turnsPCOff(buttonID: "b7", cached: cached))
        precondition(!OrbitWatchDeckSync.turnsPCOff(buttonID: "b1", cached: cached))
        precondition(!OrbitWatchDeckSync.turnsPCOff(buttonID: "nope", cached: nil))

        precondition(OrbitRemoteDeck.isLocked(index: 6, proUnlocked: false))
        precondition(!OrbitRemoteDeck.isLocked(index: 5, proUnlocked: false))
        precondition(!OrbitRemoteDeck.isLocked(index: 40, proUnlocked: true))
        precondition(OrbitRemoteDeck.runPath(for: "a b") == nil && OrbitRemoteDeck.runPath(for: "ab_1-2") == "/api/deck/buttons/ab_1-2/run")

        precondition(OrbitWatchDeckSync.detail(from: Data("{\"status\":\"done\",\"detail\":\"  Pressed Alt+F10 \"}".utf8)) == "Pressed Alt+F10")
        precondition(OrbitWatchDeckSync.detail(from: Data("{\"status\":\"done\"}".utf8)) == nil)
        precondition(OrbitWatchDeckSync.detail(from: Data("nope".utf8)) == nil)
        precondition(OrbitRemoteDeckService.detail(from: Data("{\"detail\":\"Started recording\"}".utf8)) == "Started recording")
        precondition(OrbitWatchDeckSync.isMissingRoute(OrbitError(message: "Not Found", statusCode: 404)))
        precondition(OrbitWatchDeckSync.isMissingRoute(OrbitError(message: "PC returned error 404.", statusCode: 404)))
        precondition(!OrbitWatchDeckSync.isMissingRoute(OrbitError(message: "That button was deleted.", statusCode: 404)))
        precondition(!OrbitWatchDeckSync.isMissingRoute(OrbitError(message: "Not Found", statusCode: 500)))
    }

    static func cachedDeckFormats(_ data: Data) {
        let suite = "orbit.remote-deck-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(OrbitWatchDeckSync.cachedDeck(pcID: "pc", stores: [defaults]) == nil)
        precondition(OrbitWatchDeckSync.cachedDeck(pcID: "", stores: [defaults]) == nil)
        defaults.set(data, forKey: "Orbit.Deck.v1.pc-data")
        defaults.set(String(decoding: data, as: UTF8.self), forKey: "Orbit.Deck.v1.pc-string")
        // A property list cannot hold JSON null, so the dictionary form is a plain deck.
        defaults.set(["buttons": [["id": "a", "title": "A", "action": ["type": "media", "name": "next"]]]], forKey: "Orbit.Deck.v1.pc-dict")
        defaults.set(Data("garbage".utf8), forKey: "Orbit.Deck.v1.pc-bad")
        for pc in ["pc-data", "pc-string", "pc-dict"] {
            let cached = OrbitWatchDeckSync.cachedDeck(pcID: pc, stores: [defaults])
            precondition((cached?["buttons"] as? [[String: Any]])?.isEmpty == false, "cache format \(pc) unreadable")
        }
        precondition(OrbitWatchDeckSync.cachedDeck(pcID: "pc-bad", stores: [defaults]) == nil)
    }

    static func actionDescriptions() {
        func button(_ action: [String: OrbitDeckJSON], confirm: Bool = false, color: String = "#FF453A") -> OrbitRemoteDeckButton {
            OrbitRemoteDeckButton(id: "x", title: "T", symbol: "no.such.symbol.anywhere", color: color, confirm: confirm, action: .object(action))
        }
        let hotkey = button(["type": .string("hotkey"), "keys": .array([.string("ctrl"), .string("shift"), .string("m")])])
        precondition(hotkey.summary == "Ctrl + Shift + M", hotkey.summary)
        precondition(hotkey.displaySymbol == "keyboard", "unknown symbols fall back to the action's symbol")
        precondition(!hotkey.needsConfirmation && hotkey.powerAction == nil && hotkey.confirmationTitle == "Run “T”?")
        precondition(button(["type": .string("hotkey"), "keys": .array([.string("alt"), .string("f10")])]).summary == "Alt + F10")
        precondition(button(["type": .string("obs"), "request": .string("SetCurrentProgramScene"), "data": .object(["sceneName": .string("BRB")])]).summary == "OBS · BRB")
        precondition(button(["type": .string("obs"), "request": .string("ToggleRecord")]).summary == "OBS · Record")
        precondition(button(["type": .string("openUrl"), "url": .string("https://www.youtube.com/watch?v=1")]).summary == "Opens youtube.com")
        precondition(button(["type": .string("openUrl"), "url": .string("steam://rungameid/620")]).summary == "Opens Steam")
        precondition(button(["type": .string("openUrl"), "url": .string("ms-settings:display")]).summary == "Opens Windows Settings")
        precondition(button(["type": .string("openUrl"), "url": .string("spotify:")]).summary == "Opens Spotify")
        precondition(button(["type": .string("media"), "name": .string("playpause")]).summary == "Play / pause")
        precondition(button(["type": .string("text"), "text": .string("gg wp everyone, see you tomorrow")]).summary.hasPrefix("Types “gg wp"))
        precondition(button(["type": .string("sequence"), "steps": .array([.object([:]), .object([:]), .object([:])])]).summary == "3 steps")
        precondition(button(["type": .string("launch"), "appID": .string("abc")]).summary == "Opens an app")
        precondition(button(["type": .string("teleport")]).summary == "Custom action")

        let sleep = button(["type": .string("system"), "name": .string("sleep")])
        precondition(sleep.needsConfirmation && sleep.powerAction == "sleep" && sleep.confirmationButton == "Sleep PC")
        precondition(sleep.confirmationMessage(pcName: "Gaming PC").contains("Gaming PC"))
        let nested = button(["type": .string("sequence"), "steps": .array([.object(["type": .string("hotkey")]), .object(["type": .string("system"), "name": .string("restart")])])])
        precondition(nested.powerAction == "restart" && nested.needsConfirmation && nested.confirmationTitle == "Restart your PC?")
        let lock = button(["type": .string("system"), "name": .string("lock")])
        precondition(!lock.needsConfirmation && lock.summary == "Lock the PC")
        precondition(button(["type": .string("hotkey")], confirm: true).needsConfirmation)

        // Subtitles never just repeat the title.
        func titled(_ title: String, _ action: [String: OrbitDeckJSON], confirm: Bool = false) -> OrbitRemoteDeckButton {
            OrbitRemoteDeckButton(id: "x", title: title, symbol: "", color: "", confirm: confirm, action: .object(action))
        }
        precondition(titled("Screenshot", ["type": .string("system"), "name": .string("screenshot")]).subtitle == "Windows action")
        precondition(titled("Play / Pause", ["type": .string("media"), "name": .string("playpause")]).subtitle == "Media key")
        precondition(titled("Sleep PC", ["type": .string("system"), "name": .string("sleep")], confirm: true).subtitle == "Asks before it runs")
        precondition(titled("Bed time", ["type": .string("system"), "name": .string("sleep")], confirm: true).subtitle == "Sleep · asks first")
        precondition(titled("Mute Discord", ["type": .string("hotkey"), "keys": .array([.string("ctrl"), .string("shift"), .string("m")])]).subtitle == "Ctrl + Shift + M")
        precondition(titled("Lock PC", ["type": .string("system"), "name": .string("lock")]).subtitle == "Lock the PC")

        precondition(OrbitRemoteDeck.rgb(fromHex: "#FF453A")! == (1.0, 69.0 / 255, 58.0 / 255))
        precondition(OrbitRemoteDeck.rgb(fromHex: "30d158cc") != nil && OrbitRemoteDeck.rgb(fromHex: "#12") == nil && OrbitRemoteDeck.rgb(fromHex: "zzzzzz") == nil)
        precondition(OrbitRemoteDeck.demo.buttons.count == 8 && OrbitRemoteDeck.demo.buttons.contains { $0.needsConfirmation })
        precondition(OrbitRemoteDeck.demo.buttons.allSatisfy { OrbitRemoteDeck.symbolExists($0.symbol) }, "demo symbols must exist")
    }

    static func serviceLoadOutcomes(deckData: Data, capabilities: Data) async {
        let status: (Error) -> Int? = { ($0 as? FakeHTTPError)?.status }
        let log = CallLog()
        // An agent with the deck.
        var outcome = await OrbitRemoteDeckService.load(get: { path in
            log.paths.append(path)
            return path == "/api/capabilities" ? capabilities : deckData
        }, status: status)
        guard case let .deck(deck) = outcome, !deck.buttons.isEmpty else { preconditionFailure("deck not loaded: \(outcome)") }
        precondition(log.paths == ["/api/capabilities", "/api/deck"])

        // Older agents: no capabilities route, or no "deck" in it. The deck is never requested.
        log.paths = []
        outcome = await OrbitRemoteDeckService.load(get: { path in
            log.paths.append(path)
            throw FakeHTTPError(status: 404, detail: "Not Found")
        }, status: status)
        guard case .unsupported = outcome else { preconditionFailure("404 must mean an older agent") }
        precondition(log.paths == ["/api/capabilities"])
        outcome = await OrbitRemoteDeckService.load(get: { _ in Data("{\"agentVersion\":\"4.4.0\",\"features\":[\"events\"]}".utf8) }, status: status)
        guard case .unsupported = outcome else { preconditionFailure("no deck feature must mean unsupported") }

        // Failures become sentences.
        outcome = await OrbitRemoteDeckService.load(get: { _ in throw URLError(.timedOut) }, status: status)
        guard case let .failed(timeout) = outcome, timeout.contains("didn't answer") else { preconditionFailure("\(outcome)") }
        outcome = await OrbitRemoteDeckService.load(get: { _ in throw FakeHTTPError(status: 401, detail: "Invalid Orbit token") }, status: status)
        guard case let .failed(auth) = outcome, auth.contains("Pair it again") else { preconditionFailure("\(outcome)") }
        outcome = await OrbitRemoteDeckService.load(get: { path in
            path == "/api/capabilities" ? capabilities : Data("[1,2,3]".utf8)
        }, status: status)
        guard case let .failed(unreadable) = outcome, unreadable.contains("can't read") else { preconditionFailure("\(outcome)") }
    }

    static func serviceRunOutcomes() async {
        let status: (Error) -> Int? = { ($0 as? FakeHTTPError)?.status }
        let log = CallLog()
        var outcome = await OrbitRemoteDeckService.run(buttonID: "abc-1", post: { path in
            log.paths.append(path)
            return Data("{\"status\":\"done\",\"detail\":\"Muted Discord\"}".utf8)
        }, status: status)
        guard case .done("Muted Discord") = outcome else { preconditionFailure("\(outcome)") }
        precondition(log.paths == ["/api/deck/buttons/abc-1/run"])

        outcome = await OrbitRemoteDeckService.run(buttonID: "abc-1", post: { _ in Data() }, status: status)
        guard case .done(nil) = outcome else { preconditionFailure("\(outcome)") }

        outcome = await OrbitRemoteDeckService.run(buttonID: "abc-1", post: { _ in throw FakeHTTPError(status: 404, detail: "Not Found") }, status: status)
        guard case .unsupported = outcome else { preconditionFailure("\(outcome)") }

        outcome = await OrbitRemoteDeckService.run(buttonID: "abc-1", post: { _ in throw FakeHTTPError(status: 404, detail: "That button was deleted on another device.") }, status: status)
        guard case let .failed(message, missing) = outcome, missing, message.contains("deleted") else { preconditionFailure("\(outcome)") }

        outcome = await OrbitRemoteDeckService.run(buttonID: "abc-1", post: { _ in throw FakeHTTPError(status: 409, detail: "OBS is not running.") }, status: status)
        guard case .failed("OBS is not running.", false) = outcome else { preconditionFailure("\(outcome)") }

        log.paths = []
        outcome = await OrbitRemoteDeckService.run(buttonID: "abc-1", post: { path in
            log.paths.append(path)
            throw URLError(.timedOut)
        }, status: status)
        guard case let .failed(timeout, false) = outcome, timeout.contains("may still have run") else { preconditionFailure("\(outcome)") }
        precondition(log.paths.count == 1, "a run is never retried")

        log.paths = []
        outcome = await OrbitRemoteDeckService.run(buttonID: "../etc", post: { path in
            log.paths.append(path)
            return Data()
        }, status: status)
        guard case .failed(_, true) = outcome else { preconditionFailure("\(outcome)") }
        precondition(log.paths.isEmpty, "an invalid id never reaches the PC")
    }
}
