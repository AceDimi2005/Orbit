import Foundation

/// Driven by `check_push_crypto.py`: reads the cases it wrote (ciphertexts sealed by Python exactly
/// like the Windows agent, plus scripted `/api/events` pages), runs the production
/// `OrbitPushCrypto` and `OrbitEventFeed` on them and prints the results as JSON for the script to check.

struct Cases: Decodable {
    struct Key: Decodable { let id: String; let key: String }
    struct Crypto: Decodable {
        let name: String
        let ciphertext: String
        let deviceID: String
        let keys: [Key]
    }
    struct Step: Decodable, Sendable {
        let since: Int?
        let limit: Int
        let page: OrbitPCEventPage
    }
    struct Feed: Decodable {
        let name: String
        let cursor: Int?
        let delivered: Int
        let holdBack: Double?
        let now: Double
        let steps: [Step]
    }
    let crypto: [Crypto]
    let feed: [Feed]
    let newKeys: Int
}

actor ScriptedFetch {
    var steps: [Cases.Step]
    var calls: [[Int]] = []
    init(_ steps: [Cases.Step]) { self.steps = steps }

    func fetch(_ since: Int?, _ limit: Int) async throws -> OrbitPCEventPage {
        calls.append([since ?? -1, limit])
        guard !steps.isEmpty else { throw NSError(domain: "ScriptedFetch", code: 1, userInfo: [NSLocalizedDescriptionKey: "no more pages scripted"]) }
        return steps.removeFirst().page
    }
}

@main
enum OrbitPushCryptoTests {
    static func main() async {
        guard CommandLine.arguments.count == 2,
              let data = FileManager.default.contents(atPath: CommandLine.arguments[1]) else {
            print("usage: push-crypto-tests <cases.json>"); exit(2)
        }
        let cases: Cases
        do { cases = try JSONDecoder().decode(Cases.self, from: data) } catch { print("bad cases: \(error)"); exit(2) }

        var cryptoResults: [[String: Any]] = []
        for item in cases.crypto {
            var result: [String: Any] = ["name": item.name]
            let keys = item.keys.map { (id: $0.id, key: Data(base64Encoded: $0.key) ?? Data()) }
            if keys.count == 1 {
                do {
                    let message = try OrbitPushCrypto.open(item.ciphertext, key: keys[0].key, deviceID: item.deviceID)
                    result["ok"] = true
                    result["pcID"] = keys[0].id
                    result["message"] = describe(message)
                } catch let failure as OrbitPushCrypto.Failure {
                    result["ok"] = false
                    result["error"] = "\(failure)"
                } catch {
                    result["ok"] = false
                    result["error"] = "other: \(error)"
                }
            } else if let opened = OrbitPushCrypto.open(item.ciphertext, keys: keys, deviceID: item.deviceID) {
                result["ok"] = true
                result["pcID"] = opened.id
                result["message"] = describe(opened.message)
            } else {
                result["ok"] = false
                result["error"] = "none"
            }
            cryptoResults.append(result)
        }

        var feedResults: [[String: Any]] = []
        for scenario in cases.feed {
            let script = ScriptedFetch(scenario.steps)
            var result: [String: Any] = ["name": scenario.name]
            do {
                let outcome = try await OrbitEventFeed.poll(cursor: scenario.cursor, delivered: scenario.delivered, holdBack: scenario.holdBack,
                                                            now: Date(timeIntervalSince1970: scenario.now), fetch: { try await script.fetch($0, $1) })
                result["toPost"] = outcome.toPost.map(\.id)
                result["cursor"] = outcome.cursor
                result["resynced"] = outcome.resynced
                result["latestID"] = outcome.latestID
            } catch {
                result["error"] = "\(error.localizedDescription)"
            }
            result["fetches"] = await script.calls
            result["unusedSteps"] = await script.steps.count
            feedResults.append(result)
        }

        // Fresh keys: right size and never repeated.
        let generated = (0..<max(1, cases.newKeys)).map { _ in OrbitPushCrypto.newKey() }
        let keyReport: [String: Any] = [
            "count": generated.count,
            "allRightSize": generated.allSatisfy { $0.count == OrbitPushCrypto.keyByteCount },
            "distinct": Set(generated).count
        ]

        // Event kinds → categories and notification identifiers used by both apps.
        let categories = ["download.finished", "downloads.allFinished", "temperature.high", "task.finished", "power.scheduled",
                          "pc.online", "pc.offline", "summary.ready", "webcam.connected"]
            .reduce(into: [String: String]()) { $0[$1] = OrbitEventFeed.category(of: $1).rawValue }

        let output: [String: Any] = [
            "crypto": cryptoResults,
            "feed": feedResults,
            "keys": keyReport,
            "categories": categories,
            "powerCategory": OrbitEventFeed.notificationCategory(for: "power.scheduled"),
            "otherCategory": OrbitEventFeed.notificationCategory(for: "download.finished"),
            "identifier": OrbitEventFeed.notificationIdentifier(pcID: "PC-1", eventID: 12)
        ]
        let json = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        FileHandle.standardOutput.write(json)
    }

    static func describe(_ message: OrbitPushMessage) -> [String: Any] {
        ["pc": message.pc, "id": message.id, "kind": message.kind, "title": message.title, "body": message.body,
         "ts": message.timestamp, "link": message.link]
    }
}
