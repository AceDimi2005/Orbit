import Foundation

/// The iPhone's half of the button deck on Apple Watch (DESIGN F4), used by `OrbitWatchBridge`.
///
/// The iPhone's deck screen caches the exact `GET /api/deck` reply per PC in App Group defaults
/// (`Orbit.Deck.v1.<pcID>`). The sync payload carries a compact copy under the key `deck`:
/// `{"pcID","isPro","cached","demo"?,"updatedAt"?,"buttons":[{"id","title","symbol","color","type","confirm","power"?}]}`.
/// Only what the Watch draws travels (WatchConnectivity payloads are small); buttons run by id through
/// the bridge command `runDeck` → `POST /api/deck/buttons/{id}/run`. The Watch reads it with
/// `OrbitRemoteDeckButton(watchSummary:)` (Shared/OrbitRemoteDeck.swift).
///
/// Uses only Foundation and `OrbitError`, so `Tests/check_remote_deck.py` can compile it on its own.
enum OrbitWatchDeckSync {
    static let cacheKeyPrefix = "Orbit.Deck.v1."
    /// Buttons that work without Orbit Pro.
    static let freeButtonLimit = 6
    static let maxButtons = 64
    static let powerActions: Set<String> = ["sleep", "shutdown", "restart"]
    static let updateAgentMessage = "Buttons need the latest Orbit agent on your PC. Update it, then try again."

    /// The `deck` value of the Watch sync payload. `cached` is the PC's `GET /api/deck` reply, if the iPhone has one.
    static func payload(pcID: String, isPro: Bool, isDemo: Bool, cached: [String: Any]?) -> [String: Any] {
        var deck: [String: Any] = ["pcID": pcID, "isPro": isPro, "buttons": [[String: Any]]()]
        if isDemo {
            // The Watch shows its own sample buttons and never sends them anywhere.
            deck["demo"] = true
            deck["cached"] = true
            return deck
        }
        guard let cached else {
            deck["cached"] = false
            return deck
        }
        deck["cached"] = true
        if let updatedAt = cached["updatedAt"] as? String { deck["updatedAt"] = String(updatedAt.prefix(40)) }
        var seen = Set<String>()
        deck["buttons"] = (cached["buttons"] as? [[String: Any]] ?? []).prefix(maxButtons)
            .compactMap(summary(of:))
            .filter { seen.insert($0["id"] as? String ?? "").inserted }
        return deck
    }

    static func summary(of button: [String: Any]) -> [String: Any]? {
        guard let id = button["id"] as? String, isValidButtonID(id) else { return nil }
        let action = button["action"] as? [String: Any] ?? [:]
        var summary: [String: Any] = [
            "id": id,
            "title": String((button["title"] as? String ?? "").prefix(40)),
            "symbol": String((button["symbol"] as? String ?? "").prefix(64)),
            "color": String((button["color"] as? String ?? "").prefix(9)),
            "type": String((action["type"] as? String ?? "").prefix(24))
        ]
        let power = powerAction(in: action)
        if let power { summary["power"] = power }
        summary["confirm"] = button["confirm"] as? Bool == true || power != nil
        return summary
    }

    /// `sleep`, `shutdown` or `restart` when an action (or a step of its sequence) turns the PC off.
    static func powerAction(in action: [String: Any]) -> String? {
        switch action["type"] as? String {
        case "system":
            let name = action["name"] as? String ?? ""
            return powerActions.contains(name) ? name : nil
        case "sequence":
            return (action["steps"] as? [[String: Any]] ?? []).lazy.compactMap { powerAction(in: $0) }.first
        default:
            return nil
        }
    }

    /// Ids go into a URL path: letters, digits, `-` and `_` only (the PC uses UUIDs).
    static func isValidButtonID(_ id: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return (1...64).contains(id.unicodeScalars.count) && id.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// The path for a Watch `runDeck` command. Buttons after the first six need Orbit Pro, checked
    /// against the iPhone's cached deck (a button missing from the cache is left to the PC to judge).
    static func runPath(buttonID: String?, cached: [String: Any]?, isPro: Bool) throws -> String {
        guard let buttonID, isValidButtonID(buttonID) else {
            throw OrbitError(message: "That button is no longer on your PC. Open Buttons in Orbit on iPhone to sync, then try again.")
        }
        if !isPro, let index = position(of: buttonID, in: cached), index >= freeButtonLimit {
            throw OrbitError(message: "Orbit Pro unlocks more than \(freeButtonLimit) buttons. Unlock it in Orbit on iPhone.")
        }
        return "/api/deck/buttons/\(buttonID)/run"
    }

    static func position(of buttonID: String, in cached: [String: Any]?) -> Int? {
        (cached?["buttons"] as? [[String: Any]])?.firstIndex { $0["id"] as? String == buttonID }
    }

    /// Whether running this cached button turns the PC off (sleep, shut down, restart).
    static func turnsPCOff(buttonID: String, cached: [String: Any]?) -> Bool {
        guard let index = position(of: buttonID, in: cached),
              let button = (cached?["buttons"] as? [[String: Any]])?[index] else { return false }
        return powerAction(in: button["action"] as? [String: Any] ?? [:]) != nil
    }

    /// The `detail` sentence of `{"status":"done","detail":"…"}`, if any.
    static func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = (object["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty else { return nil }
        return String(detail.prefix(200))
    }

    /// FastAPI answers an unknown route with the bare detail "Not Found" (an agent without the deck);
    /// the deck's own 404s ("That button was deleted…") are sentences.
    static func isMissingRoute(_ error: Error) -> Bool {
        guard let error = error as? OrbitError, error.statusCode == 404 else { return false }
        return error.message == "Not Found" || error.message.hasPrefix("PC returned error")
    }

    /// The cached `GET /api/deck` reply for a PC: JSON data as stored by the iPhone's deck screen
    /// (a JSON string or an already-decoded dictionary are accepted too).
    static func cachedDeck(pcID: String, stores: [UserDefaults]? = nil) -> [String: Any]? {
        guard !pcID.isEmpty else { return nil }
        let key = cacheKeyPrefix + pcID
        for defaults in stores ?? defaultStores {
            guard let stored = defaults.object(forKey: key) else { continue }
            if let dictionary = stored as? [String: Any] { return dictionary }
            let data = (stored as? Data) ?? (stored as? String).map { Data($0.utf8) }
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        }
        return nil
    }

    private static var defaultStores: [UserDefaults] {
        let group = (Bundle.main.object(forInfoDictionaryKey: "OrbitAppGroupIdentifier") as? String)
            .flatMap { $0.hasPrefix("group.") && !$0.contains("$(") ? $0 : nil } ?? "group.com.dimitrie.orbit"
        return [UserDefaults(suiteName: group), UserDefaults.standard].compactMap { $0 }
    }
}
