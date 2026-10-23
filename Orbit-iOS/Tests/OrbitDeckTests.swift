import Foundation

// Driven by check_deck_contract.py:
//   OrbitDeckTests <agent-keys.json> <agent-actions.json> <out-deck.json>   model and contract checks,
//                                                                          writes a deck with every action type
//   OrbitDeckTests --decode <deck.json>                                    decodes what an agent returned

@main
struct OrbitDeckTests {
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 3 && arguments[1] == "--decode" {
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
            guard let deck = OrbitDeck.decode(data) else { fail("the agent's GET /api/deck reply did not decode") }
            let sample = sampleDeck()
            check(deck.buttons.count == sample.buttons.count, "agent kept \(deck.buttons.count) of \(sample.buttons.count) buttons")
            for (sent, kept) in zip(sample.buttons, deck.buttons) {
                check(sent.id == kept.id && sent.title == kept.title && sent.symbol == kept.symbol && sent.color == kept.color,
                      "agent changed button \(sent.id)")
                check(sent.action.kind == kept.action.kind, "agent changed the action of \(sent.id): \(kept.action.raw)")
                check(sent.needsConfirmation == kept.needsConfirmation, "agent changed confirm of \(sent.id)")
            }
            print("PASS: the agent stored and returned every action type unchanged (\(deck.buttons.count) buttons)")
            return
        }
        guard arguments.count == 4 else { fail("usage: OrbitDeckTests <keys.json> <actions.json> <out-deck.json>") }
        let agentKeys = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        let agentActions = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))

        try designSample()
        try roundTrips()
        try newerActionsSurvive()
        try lossyDecoding()
        try confirmation()
        validation()
        try statusPayloads()
        catalogues(agentKeys: agentKeys, agentActions: agentActions)
        limitsAndCache()
        try savingRules()

        let deck = sampleDeck()
        for button in deck.buttons { check(button.validationProblem() == nil, "sample button \(button.id) is invalid: \(button.validationProblem() ?? "")") }
        let encoded = try JSONEncoder().encode(OrbitDeckUpdate(buttons: deck.buttons))
        try encoded.write(to: URL(fileURLWithPath: arguments[3]))
        print("PASS: deck model — DESIGN sample, \(deck.buttons.count) action types round-trip, newer actions kept, lossy decoding, confirm rules, validation, OBS/apps/capabilities payloads, \(agentKeys.count) agent key names, \(agentActions.count) agent actions")
    }

    // MARK: Checks

    static func designSample() throws {
        let json = ##"{"buttons":[{"id":"uuid","title":"Mute Discord","symbol":"mic.slash.fill","color":"#FF453A","action":{"type":"hotkey","keys":["ctrl","shift","m"]}}],"updatedAt":"2026-10-23T18:00:00Z"}"##
        guard let deck = OrbitDeck.decode(Data(json.utf8)) else { fail("DESIGN sample did not decode") }
        check(deck.updatedAt == "2026-10-23T18:00:00Z", "updatedAt")
        check(deck.buttons.count == 1, "one button")
        let button = deck.buttons[0]
        check(button.id == "uuid" && button.title == "Mute Discord" && button.symbol == "mic.slash.fill" && button.color == "#FF453A", "fields")
        check(button.action.kind == .hotkey(keys: ["ctrl", "shift", "m"]), "hotkey kind")
        check(button.action.summary == "Ctrl+Shift+M", "summary \(button.action.summary)")
        check(!button.needsConfirmation, "no confirmation for a hotkey")
        let reencoded = try JSONEncoder().encode(button)
        let object = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        check(object?["confirm"] == nil, "confirm is omitted unless true")
        check(Set(object?.keys.map { $0 } ?? []) == ["id", "title", "symbol", "color", "action"], "only contract keys: \(object?.keys.sorted() ?? [])")
    }

    static func roundTrips() throws {
        for button in sampleDeck().buttons {
            let data = try JSONEncoder().encode(button)
            let decoded = try JSONDecoder().decode(OrbitDeckButton.self, from: data)
            check(decoded == button, "round trip of \(button.id)")
            check(decoded.action.kind == button.action.kind, "kind of \(button.id)")
            if case .unsupported = decoded.action.kind { fail("\(button.id) decoded as unsupported: \(decoded.action.raw)") }
        }
        // Exact JSON shapes the agent expects.
        let shapes: [(OrbitDeckAction, String)] = [
            (.hotkey(["alt", "f10"]), ##"{"keys":["alt","f10"],"type":"hotkey"}"##),
            (OrbitDeckAction(.text("gg")), ##"{"text":"gg","type":"text"}"##),
            (OrbitDeckAction(.openURL("steam://rungameid/620")), ##"{"type":"openUrl","url":"steam:\/\/rungameid\/620"}"##),
            (OrbitDeckAction(.launch(appID: "abc")), ##"{"appID":"abc","type":"launch"}"##),
            (.system("lock"), ##"{"name":"lock","type":"system"}"##),
            (.media("playpause"), ##"{"name":"playpause","type":"media"}"##),
            (.obs("ToggleRecord"), ##"{"data":{},"request":"ToggleRecord","type":"obs"}"##),
            (.obs("SetCurrentProgramScene", ["sceneName": .string("BRB")]), ##"{"data":{"sceneName":"BRB"},"request":"SetCurrentProgramScene","type":"obs"}"##),
            (OrbitDeckAction(.sequence(steps: [.media("next")], delayMs: 150)), ##"{"delayMs":150,"steps":[{"name":"next","type":"media"}],"type":"sequence"}"##)
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (action, expected) in shapes {
            let text = String(decoding: try encoder.encode(action), as: UTF8.self)
            check(text == expected, "JSON of \(action.type): \(text)")
        }
    }

    static func newerActionsSurvive() throws {
        let json = ##"{"buttons":[{"id":"n1","title":"Future","symbol":"star.fill","color":"#30d158","action":{"type":"macro","frames":[1,2.5,{"x":true}],"note":null}},{"id":"n2","title":"Launch","symbol":"app.fill","color":"#0A84FF","action":{"type":"launch","appID":"x","args":"--safe"}}]}"##
        guard let deck = OrbitDeck.decode(Data(json.utf8)) else { fail("newer deck did not decode") }
        check(deck.buttons[0].action.kind == .unsupported(type: "macro"), "unknown type is unsupported")
        check(deck.buttons[0].color == "#30D158", "colour normalised")
        check(deck.buttons[0].action.validationProblem() == nil, "unsupported actions can be saved as they are")
        let saved = try JSONEncoder().encode(OrbitDeckUpdate(buttons: deck.buttons))
        let object = try JSONSerialization.jsonObject(with: saved) as? [String: Any]
        let buttons = object?["buttons"] as? [[String: Any]]
        let action = buttons?[0]["action"] as? [String: Any]
        check(action?["type"] as? String == "macro", "type kept")
        check((action?["frames"] as? [Any])?.count == 3, "unknown fields kept")
        check(action?.keys.contains("note") == true && action?["note"] is NSNull, "null kept")
        let launch = buttons?[1]["action"] as? [String: Any]
        check(launch?["args"] as? String == "--safe", "extra field of a known action kept when not edited")
    }

    static func lossyDecoding() throws {
        let json = ##"{"buttons":[{"title":"No id"},{"id":"ok","action":{"type":"media","name":"mute"}},{"id":"ok","title":"Duplicate"},{"id":"bad-colour","title":"X","symbol":"","color":"red","action":"nope"}],"updatedAt":5}"##
        guard let deck = OrbitDeck.decode(Data(json.utf8)) else { fail("lossy deck did not decode") }
        check(deck.buttons.map(\.id) == ["ok", "bad-colour"], "skips buttons without id and duplicates: \(deck.buttons.map(\.id))")
        check(deck.buttons[0].title == "Button" && deck.buttons[0].symbol == OrbitDeckButton.defaultSymbol && deck.buttons[0].color == OrbitDeckButton.defaultColor, "defaults")
        check(deck.buttons[1].color == OrbitDeckButton.defaultColor, "invalid colour replaced")
        check(deck.buttons[1].action.kind == .unsupported(type: ""), "invalid action is unsupported")
        check(deck.updatedAt == nil, "non-string updatedAt ignored")
        check(OrbitDeck.decode(Data("[]".utf8)) == nil, "not a deck")
        check(OrbitDeck.decode(Data(##"{"detail":"Not Found"}"##.utf8)) == nil, "error body is not a deck")
        let malformed = ##"{"buttons":[{"id":"m","action":{"type":"hotkey","keys":["ctrl",5]}}]}"##
        check(OrbitDeck.decode(Data(malformed.utf8))?.buttons.first?.action.kind == .unsupported(type: "hotkey"), "malformed known action is unsupported")
    }

    static func confirmation() throws {
        var sleep = OrbitDeckButton(title: "Sleep", symbol: "moon.zzz.fill", color: "#FFD60A", action: .system("sleep"))
        check(sleep.confirm == true && sleep.needsConfirmation, "power buttons carry confirm")
        sleep.confirm = nil
        sleep.normalizeConfirmation()
        check(sleep.confirm == true, "normalize restores confirm")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sleep)) as? [String: Any]
        check(object?["confirm"] as? Bool == true, "confirm encoded")
        var lock = OrbitDeckButton(title: "Lock", symbol: "lock.fill", color: "#8E8E93", action: .system("lock"), confirm: false)
        check(lock.confirm == nil && !lock.needsConfirmation, "false confirm dropped")
        lock.confirm = true
        lock.normalizeConfirmation()
        check(lock.needsConfirmation, "user can ask for confirmation")
        for name in ["sleep", "restart", "shutdown"] { check(OrbitDeckAction.system(name).isPowerAction, name) }
        check(!OrbitDeckAction.system("lock").isPowerAction, "lock is not power")

        // Sequences ending in a power step are power actions too (the agent's is_power_action).
        let saveAndSleep = OrbitDeckAction(.sequence(steps: [.hotkey(["ctrl", "s"]), .system("sleep")], delayMs: 500))
        check(saveAndSleep.isPowerAction && saveAndSleep.powerActionName == "sleep", "sequence with a sleep step is power")
        check(!OrbitDeckAction(.sequence(steps: [.media("next")], delayMs: 0)).isPowerAction, "plain sequence is not power")
        let sequenceButton = OrbitDeckButton(title: "Save and sleep", symbol: "moon.fill", color: "#FFD60A", action: saveAndSleep)
        check(sequenceButton.confirm == true && sequenceButton.needsConfirmation, "power sequences carry confirm")

        // The agent always sends "confirm": false; decoding normalises it, so an untouched button stays equal.
        let fromAgent = ##"{"id":"a1","title":"Lock","symbol":"lock.fill","color":"#8E8E93","confirm":false,"action":{"type":"system","name":"lock"}}"##
        var decoded = try JSONDecoder().decode(OrbitDeckButton.self, from: Data(fromAgent.utf8))
        check(decoded.confirm == nil, "confirm false decodes as nil")
        let before = decoded
        decoded.normalizeConfirmation()
        check(decoded == before, "normalising a decoded button changes nothing")
        let powerWithoutConfirm = ##"{"id":"a2","title":"Sleep","symbol":"moon.zzz.fill","color":"#FFD60A","action":{"type":"system","name":"sleep"}}"##
        let decodedPower = try JSONDecoder().decode(OrbitDeckButton.self, from: Data(powerWithoutConfirm.utf8))
        check(decodedPower.confirm == true, "power button decodes with confirm")
    }

    static func validation() {
        func problem(_ action: OrbitDeckAction, asStep: Bool = false) -> String? { action.validationProblem(asStep: asStep) }
        check(problem(.hotkey([])) != nil, "empty shortcut")
        check(problem(.hotkey(["ctrl", "alt", "delete"])) != nil, "ctrl+alt+delete")
        check(problem(.hotkey(["ctrl", "nope"])) != nil, "unknown key")
        check(problem(.hotkey(["ctrl", "ctrl"])) != nil, "duplicate key")
        check(problem(.hotkey(["ctrl", "shift", "alt", "win", "a", "b"])) != nil, "six keys")
        check(problem(.hotkey(["win"])) == nil, "modifier-only shortcut is allowed")
        check(problem(.hotkey(["CTRL", "Shift", "M"])) == nil, "names in any case")
        check(problem(OrbitDeckAction(.text(""))) != nil, "empty text")
        check(problem(OrbitDeckAction(.text(String(repeating: "a", count: 1001)))) != nil, "long text")
        for good in ["https://example.com/a?b=1", "http://192.168.1.5:8080/", "steam://rungameid/620", "com.epicgames.launcher://apps/fn",
                     "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M", "discord://-/channels/@me", "ms-settings:display"] {
            check(OrbitDeckCatalog.urlProblem(good) == nil, "url \(good): \(OrbitDeckCatalog.urlProblem(good) ?? "")")
        }
        for bad in ["", "example.com", "ftp://x", "javascript:alert(1)", "https://", "https://user:pw@host/", "https://a b", "file:///C:/x", "https://x/\"y"] {
            check(OrbitDeckCatalog.urlProblem(bad) != nil, "url \(bad) should be refused")
        }
        check(problem(OrbitDeckAction(.launch(appID: ""))) != nil, "no app")
        check(problem(.system("format_c")) != nil, "unknown system action")
        check(problem(.system("sleep"), asStep: true) == nil, "a power step is checked by its sequence")
        for name in ["mute", "volume_up", "volume_down", "media_play_pause", "media_next", "media_prev"] {
            check(problem(.system(name)) == nil, "agent system action \(name) made elsewhere is accepted")
            check(OrbitDeckAction.system(name).summary != "Windows action", "agent system action \(name) has a title")
        }
        check(problem(OrbitDeckAction(.sequence(steps: [.hotkey(["ctrl", "s"]), .system("shutdown")], delayMs: 0))) == nil, "power as the last step")
        check(problem(OrbitDeckAction(.sequence(steps: [.system("restart"), .media("next")], delayMs: 0))) == OrbitDeckAction.powerStepProblem, "power before the last step")
        let misplaced: [OrbitDeckAction] = [.system("sleep"), .media("next")]
        check(OrbitDeckAction.isMisplacedPowerStep(misplaced, at: 0) && !OrbitDeckAction.isMisplacedPowerStep(misplaced, at: 1), "misplaced power step")
        check(!OrbitDeckAction.isMisplacedPowerStep([.media("next"), .system("sleep")], at: 1), "last power step is fine")
        check(problem(.media("rewind")) != nil, "unknown media key")
        check(problem(.obs("StartStream")) != nil, "OBS request outside the allowlist")
        check(problem(.obs("SetCurrentProgramScene", ["sceneName": .string(" ")])) != nil, "scene name needed")
        check(problem(.obs("ToggleInputMute", [:])) != nil, "input name needed")
        check(problem(OrbitDeckAction(.sequence(steps: [], delayMs: 100))) != nil, "empty sequence")
        let nine = Array(repeating: OrbitDeckAction.media("next"), count: 9)
        check(problem(OrbitDeckAction(.sequence(steps: nine, delayMs: 100))) != nil, "nine steps")
        let nested = OrbitDeckAction(.sequence(steps: [OrbitDeckAction(.sequence(steps: [.media("next")], delayMs: 0))], delayMs: 0))
        check(problem(nested) != nil, "nested sequence")
        check(problem(OrbitDeckAction(.sequence(steps: [.media("next")], delayMs: 6000))) != nil, "long pause")
        check(problem(OrbitDeckAction(.sequence(steps: [.system("format_c")], delayMs: 0)))?.hasPrefix("Step 1:") == true, "step problems are numbered")
        var button = OrbitDeckButton(title: "  ", symbol: "star.fill", color: "#FFFFFF", action: .media("mute"))
        check(button.validationProblem() != nil, "blank name")
        button.title = String(repeating: "x", count: 41)
        check(button.validationProblem() != nil, "long name")
    }

    static func statusPayloads() throws {
        let obs = try JSONDecoder().decode(OrbitDeckOBSStatus.self, from: Data(##"{"installed":true,"enabled":true,"connected":true,"scenes":["Gaming","BRB"],"currentScene":"Gaming","recording":false,"streaming":true,"replayBuffer":true,"reason":null}"##.utf8))
        check(obs.connected && obs.scenes == ["Gaming", "BRB"] && obs.streaming && obs.currentScene == "Gaming", "OBS status")
        let partial = try JSONDecoder().decode(OrbitDeckOBSStatus.self, from: Data(##"{"installed":false}"##.utf8))
        check(!partial.connected && partial.scenes.isEmpty && partial.explanation.contains("isn't installed"), "partial OBS status")
        let reason = try JSONDecoder().decode(OrbitDeckOBSStatus.self, from: Data(##"{"installed":true,"enabled":true,"connected":false,"reason":"OBS refused the password."}"##.utf8))
        check(reason.explanation == "OBS refused the password.", "reason shown")
        let apps = try JSONDecoder().decode(OrbitDeckAppList.self, from: Data(##"{"apps":[{"id":"a","name":"Spotify","iconID":"0123456789abcdef0123456789abcdef"},{"id":"b","name":"Notepad","iconID":null},{"name":"broken"}]}"##.utf8))
        check(apps.apps.map(\.name) == ["Spotify", "Notepad"], "apps list skips broken rows")
        let capabilities = try JSONDecoder().decode(OrbitDeckCapabilities.self, from: Data(##"{"agentVersion":"4.4.0","features":["events","deck","obs"]}"##.utf8))
        check(capabilities.hasDeck && capabilities.hasOBS && capabilities.agentVersion == "4.4.0", "capabilities")
        let none = try JSONDecoder().decode(OrbitDeckCapabilities.self, from: Data(##"{"agentVersion":"4.4.0","features":["events"]}"##.utf8))
        check(!none.hasDeck && !none.hasOBS, "no deck feature")
        let reply = try JSONDecoder().decode(OrbitDeckRunReply.self, from: Data(##"{"status":"done","detail":"Pressed Ctrl+Shift+M"}"##.utf8))
        check(reply.detail == "Pressed Ctrl+Shift+M", "run reply")
    }

    static func catalogues(agentKeys: [String], agentActions: [String]) {
        let swiftKeys = OrbitDeckKeys.allKeys
        let agent = Set(agentKeys)
        check(swiftKeys == agent, "key names differ from orbit_input.KEY_NAMES: app-only \(swiftKeys.subtracting(agent).sorted()), agent-only \(agent.subtracting(swiftKeys).sorted())")
        let grouped = OrbitDeckKeys.groups.flatMap(\.keys)
        check(grouped.count == Set(grouped).count, "a key is listed twice in the picker")
        for name in (OrbitDeckCatalog.systemActions + OrbitDeckCatalog.otherSystemActions).map(\.id) {
            check(agentActions.contains(name), "system action \(name) is not in the agent's ACTIONS")
        }
        check(OrbitDeckCatalog.powerSystemActions == ["sleep", "restart", "shutdown"], "power set")
        check(Set(OrbitDeckCatalog.mediaActions.map(\.id)) == ["playpause", "next", "previous", "mute", "volumeup", "volumedown"], "media names")
        check(Set(OrbitDeckCatalog.obsRequests.map(\.id)) == ["SetCurrentProgramScene", "StartRecord", "StopRecord", "ToggleRecord", "ToggleStream",
                                                           "SaveReplayBuffer", "ToggleInputMute", "StartReplayBuffer"], "OBS allowlist")
        check(Set(OrbitDeckCatalog.urlSchemes) == ["http", "https", "steam", "com.epicgames.launcher", "spotify", "discord", "ms-settings"], "URL schemes")
        check(OrbitDeckKeys.chordLabel(["m", "shift", "ctrl"]) == "Ctrl+Shift+M", "modifiers first")
        check(OrbitDeckKeys.chordLabel(["alt", "f10"]) == "Alt+F10" && OrbitDeckKeys.chordLabel(["win", "printscreen"]) == "Win+Print Screen", "labels")
        check(OrbitDeckKeys.chordLabel(["ctrl", "shift", "esc"]) == "Ctrl+Shift+Esc", "esc label")
        for hex in OrbitDeckColor.palette { check(OrbitDeckColor.normalized(hex) == hex, "palette \(hex)") }
        check(OrbitDeckColor.hex(red: 1, green: 0.27, blue: 0.227) == "#FF453A", "hex from components")
        let parts = OrbitDeckColor.components("#5865F2")
        check(abs(parts.red - 88.0 / 255) < 0.001 && abs(parts.blue - 242.0 / 255) < 0.001, "components")
    }

    static func limitsAndCache() {
        check(OrbitDeckLimits.canAddButton(existingCount: 5, isPro: false), "free: 6th button")
        check(!OrbitDeckLimits.canAddButton(existingCount: 6, isPro: false), "free: no 7th button")
        check(OrbitDeckLimits.canAddButton(existingCount: 63, isPro: true) && !OrbitDeckLimits.canAddButton(existingCount: 64, isPro: true), "Pro: 64")
        check(OrbitDeckLimits.isIncludedForFree(index: 5) && !OrbitDeckLimits.isIncludedForFree(index: 6), "free index")
        check(OrbitDeckCache.key(for: "PC-1") == "Orbit.Deck.v1.PC-1", "cache key")
        check(OrbitDeckHTTP.describe(status: 404, detail: nil) == OrbitDeckRequestError.olderAgent, "404 without a sentence: older agent")
        check(OrbitDeckHTTP.describe(status: 404, detail: "Not Found") == OrbitDeckRequestError.olderAgent, "FastAPI's own 404: older agent")
        let gone = "This button is no longer on the PC. Refresh your buttons."
        check(OrbitDeckHTTP.describe(status: 404, detail: gone) == gone, "agent 404 sentence kept")
        check(OrbitDeckRequestError.isMissingButton(status: 404, detail: gone), "button-missing 404")
        check(OrbitDeckRequestError.isMissingButton(status: 404, detail: "PC returned error 404."), "404 without detail")
        check(!OrbitDeckRequestError.isMissingButton(status: 404, detail: "Spotify is no longer in the PC's Start menu. Edit the button and choose the app again."), "launch 404 is not a missing button")
        check(!OrbitDeckRequestError.isMissingButton(status: 404, detail: "Step 2 of 3 didn't work: Spotify is no longer in the PC's Start menu."), "sequence 404 is not a missing button")
        check(!OrbitDeckRequestError.isMissingButton(status: 409, detail: gone), "only 404")
        check(OrbitDeckHTTP.describe(status: 409, detail: "OBS isn't running right now.") == "OBS isn't running right now.", "agent detail kept")
        check(OrbitDeckHTTP.describe(status: 401, detail: "Invalid Orbit token").contains("pair the PC again"), "401 sentence")
        check(OrbitDeckRequestError.message(for: URLError(.timedOut), pcName: "Gaming PC") == "Gaming PC isn't reachable. Wake it from Orbit and try again.", "timeout sentence")
        check(OrbitDeckSamples.demoDeck.buttons.count == OrbitDeckLimits.freeButtons, "demo deck fits the free plan")
        for button in OrbitDeckSamples.demoDeck.buttons { check(button.validationProblem() == nil, "demo button \(button.id)") }
    }

    static func savingRules() throws {
        // PUT body: baseUpdatedAt only when known.
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OrbitDeckUpdate(buttons: []))) as? [String: Any]
        check(plain?.keys.sorted() == ["buttons"], "no baseUpdatedAt when unknown: \(plain?.keys.sorted() ?? [])")
        let based = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OrbitDeckUpdate(buttons: [], baseUpdatedAt: "2026-10-23T18:00:00Z"))) as? [String: Any]
        check(based?["baseUpdatedAt"] as? String == "2026-10-23T18:00:00Z", "baseUpdatedAt sent")

        // Only new or changed buttons are validated before a save.
        let fromPC = OrbitDeckButton(id: "x1", title: "Odd", symbol: "star.fill", color: "#FFFFFF", action: .system("not_known_here"))
        let fine = OrbitDeckButton(id: "x2", title: "Lock", symbol: "lock.fill", color: "#8E8E93", action: .system("lock"))
        check(OrbitDeckButton.firstProblem(in: [fromPC, fine], unchangedFrom: [fromPC, fine]) == nil, "untouched buttons aren't checked")
        var edited = fromPC
        edited.title = "Odd 2"
        check(OrbitDeckButton.firstProblem(in: [edited, fine], unchangedFrom: [fromPC, fine])?.button.id == "x1", "an edited button is checked")
        let added = OrbitDeckButton(id: "x3", title: "", symbol: "star.fill", color: "#FFFFFF", action: .media("next"))
        check(OrbitDeckButton.firstProblem(in: [fromPC, added], unchangedFrom: [fromPC])?.button.id == "x3", "a new button is checked")

        // Widget feedback: success flag and the PC it belongs to.
        OrbitDeckCache.recordFeedback("Mute · done", success: true, pcID: "pc-a")
        check(OrbitDeckCache.recentFeedback(for: "pc-a")?.success == true, "feedback for its PC")
        check(OrbitDeckCache.recentFeedback(for: "pc-b") == nil, "feedback hidden on another PC's widget")
        OrbitDeckCache.recordFeedback("Pair your PC in Orbit first.", success: false, pcID: nil)
        let general = OrbitDeckCache.recentFeedback(for: "pc-b")
        check(general?.success == false && general?.message == "Pair your PC in Orbit first.", "feedback without a PC shows everywhere")
        OrbitDeckCache.recordFeedback("", success: true, pcID: nil)
        UserDefaults.standard.removeObject(forKey: "Orbit.DeckFeedbackTime.v1")
    }

    /// One button per action type, as the editor's presets create them.
    static func sampleDeck() -> OrbitDeck {
        OrbitDeck(buttons: [
            OrbitDeckButton(id: "6f1c1f9e-0001-4c55-9d1e-000000000001", title: "Mute Discord", symbol: "mic.slash.fill", color: "#5865F2", action: .hotkey(["ctrl", "shift", "m"])),
            OrbitDeckButton(id: "6f1c1f9e-0001-4c55-9d1e-000000000002", title: "Task Manager", symbol: "list.bullet.rectangle.fill", color: "#30D158", action: .hotkey(["ctrl", "shift", "esc"])),
            OrbitDeckButton(id: "6f1c1f9e-0001-4c55-9d1e-000000000003", title: "Type gg", symbol: "keyboard", color: "#66D4CF", action: OrbitDeckAction(.text("gg wp"))),
            OrbitDeckButton(id: "6f1c1f9e-0001-4c55-9d1e-000000000004", title: "Portal 2", symbol: "gamecontroller.fill", color: "#0A84FF", action: OrbitDeckAction(.openURL("steam://rungameid/620"))),
            OrbitDeckButton(id: "6f1c1f9e-0001-4c55-9d1e-000000000005", title: "Spotify", symbol: "music.note", color: "#30D158", action: OrbitDeckAction(.launch(appID: "1ff2ef2944128ed1148fc2a860e7c3caad82f639"))),
            OrbitDeckButton(id: "6f1c1f9e-0001-4c55-9d1e-000000000006", title: "Lock PC", symbol: "lock.fill", color: "#8E8E93", action: .system("lock")),
            OrbitDeckButton(id: "6f1c1f9e-0001-4c55-9d1e-000000000007", title: "Sleep PC", symbol: "moon.zzz.fill", color: "#FFD60A", action: .system("sleep")),
            OrbitDeckButton(id: "6f1c1f9e-0001-4c55-9d1e-000000000008", title: "Play/Pause", symbol: "playpause.fill", color: "#FF375F", action: .media("playpause")),
            OrbitDeckButton(id: "6f1c1f9e-0001-4c55-9d1e-000000000009", title: "Record", symbol: "record.circle", color: "#FF453A", action: .obs("ToggleRecord")),
            OrbitDeckButton(id: "6f1c1f9e-0001-4c55-9d1e-00000000000a", title: "BRB", symbol: "rectangle.on.rectangle", color: "#64D2FF", action: .obs("SetCurrentProgramScene", ["sceneName": .string("BRB")])),
            OrbitDeckButton(id: "6f1c1f9e-0001-4c55-9d1e-00000000000b", title: "Mute mic in OBS", symbol: "mic.slash.fill", color: "#BF5AF2", action: .obs("ToggleInputMute", ["inputName": .string("Mic/Aux")])),
            OrbitDeckButton(id: "6f1c1f9e-0001-4c55-9d1e-00000000000c", title: "Clip + note", symbol: "list.number", color: "#BF5AF2",
                            action: OrbitDeckAction(.sequence(steps: [.hotkey(["alt", "f10"]), .obs("SaveReplayBuffer"), .media("next")], delayMs: 250)), confirm: true),
            OrbitDeckButton(id: "6f1c1f9e-0001-4c55-9d1e-00000000000d", title: "Save and sleep", symbol: "moon.fill", color: "#FFD60A",
                            action: OrbitDeckAction(.sequence(steps: [.hotkey(["ctrl", "s"]), .system("sleep")], delayMs: 500)))
        ], updatedAt: nil)
    }

    // MARK: Helpers

    static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
        if !condition() { fail(message()) }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}
