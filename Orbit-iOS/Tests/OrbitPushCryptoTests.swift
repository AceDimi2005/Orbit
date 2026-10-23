import Foundation

/// Driven by `check_push_crypto.py`: reads the cases it wrote (ciphertexts sealed by Python exactly
/// like the Windows agent, plus scripted `/api/events` pages), runs the production
/// `OrbitPushCrypto`, `OrbitEventFeed` and `OrbitDeliveredStore` on them and prints the results as JSON
/// for the script to check.
///
/// `push-crypto-tests <cases.json>` runs every case. `push-crypto-tests --hammer <store.json> <pcID> <seed> <count>`
/// records ids 1…count into a delivered store in a seeded random order and prints the ids it was first to
/// record: the script runs several at once to check the cross-process lock.

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
        let delivered: OrbitDeliveredIDs?
        let holdBack: Double?
        let now: Double
        let steps: [Step]
    }
    struct Text: Decodable {
        let name: String
        let body: String
        let ts: String
        let now: Double
    }
    struct IDOperation: Decodable {
        /// "insert" (expect = returned value), "contains" (expect = answer), "reset".
        let op: String
        let id: Int?
        let floor: Int?
        let range: [Int]?
    }
    struct IDCase: Decodable {
        let name: String
        let operations: [IDOperation]
    }
    struct DeliveryStep: Decodable {
        /// A push the extension receives.
        let push: String?
        /// A poll of the app's fallback poller.
        let poll: Feed?
        /// A push the extension handles while that poll runs (after the PC answered, before the app records).
        let concurrentPush: String?
    }
    struct Delivery: Decodable {
        let name: String
        let steps: [DeliveryStep]
    }
    let crypto: [Crypto]
    let feed: [Feed]
    let newKeys: Int
    let texts: [Text]
    let idCases: [IDCase]
    let deliveries: [Delivery]
    let deliveryKeys: [Key]
    let deliveryDeviceID: String
    let storeDirectory: String
    let threadCount: Int
    let threadIDs: Int
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

/// Collects results from several threads.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int: Int] = [:]
    func add(_ id: Int) { lock.lock(); counts[id, default: 0] += 1; lock.unlock() }
    var snapshot: [Int: Int] { lock.lock(); defer { lock.unlock() }; return counts }
}

/// A small deterministic generator, so the hammer processes shuffle differently but reproducibly.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}

@main
enum OrbitPushCryptoTests {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count == 6, arguments[1] == "--hammer" {
            hammer(file: arguments[2], pcID: arguments[3], seed: UInt64(arguments[4]) ?? 1, count: Int(arguments[5]) ?? 100)
            return
        }
        guard arguments.count == 2, let data = FileManager.default.contents(atPath: arguments[1]) else {
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
            feedResults.append(await runFeed(scenario))
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

        // Notification text of late alerts.
        var texts: [String: String] = [:]
        for item in cases.texts {
            texts[item.name] = OrbitEventFeed.displayBody(item.body, date: OrbitEventFeed.parseTimestamp(item.ts),
                                                          now: Date(timeIntervalSince1970: item.now))
        }

        // The delivered-ids set on its own.
        var idResults: [[String: Any]] = []
        for item in cases.idCases {
            var ids = OrbitDeliveredIDs()
            var answers: [Any] = []
            for operation in item.operations {
                switch operation.op {
                case "insert":
                    if let range = operation.range, range.count == 2 {
                        answers.append((range[0]...range[1]).map { ids.insert($0) }.allSatisfy { $0 })
                    } else {
                        answers.append(ids.insert(operation.id ?? 0))
                    }
                case "contains":
                    if let range = operation.range, range.count == 2 {
                        answers.append((range[0]...range[1]).map { ids.contains($0) })
                    } else {
                        answers.append(ids.contains(operation.id ?? 0))
                    }
                case "reset":
                    ids = OrbitDeliveredIDs(floor: operation.floor ?? 0)
                    answers.append(true)
                default:
                    answers.append("unknown op")
                }
            }
            idResults.append(["name": item.name, "answers": answers, "floor": ids.floor, "count": ids.ids.count, "maxID": ids.maxID])
        }

        // Pushes (the extension's code) and polls (the app's code) sharing one delivered store, like on the phone.
        let deliveryKeys = cases.deliveryKeys.map { (id: $0.id, key: Data(base64Encoded: $0.key) ?? Data()) }
        var deliveryResults: [[String: Any]] = []
        for (index, scenario) in cases.deliveries.enumerated() {
            let store = OrbitDeliveredStore(fileURL: URL(fileURLWithPath: cases.storeDirectory)
                .appendingPathComponent("delivery-\(index)", isDirectory: true).appendingPathComponent("DeliveredEvents.v2.json"))
            var steps: [[String: Any]] = []
            for step in scenario.steps {
                // Distinct timestamps between steps (the store tells old ids from new ones by when they came).
                usleep(2000)
                if let push = step.push {
                    steps.append(receive(push, keys: deliveryKeys, deviceID: cases.deliveryDeviceID, store: store))
                } else if let poll = step.poll {
                    let pcID = "PC-B"
                    // Exactly what OrbitEventPoller.pollSelected does: time, snapshot, poll, reconcile, record.
                    let startedAt = Date()
                    var result = await runFeed(poll, delivered: store.ids(for: pcID))
                    if let concurrent = step.concurrentPush {
                        result["concurrent"] = receive(concurrent, keys: deliveryKeys, deviceID: cases.deliveryDeviceID, store: store)
                    }
                    if result["error"] == nil, let cursor = result["cursor"] as? Int, let latest = result["latestID"] as? Int,
                       let toPost = result["toPost"] as? [Int], let resynced = result["resynced"] as? Bool {
                        store.reconcile(pcID, latestID: latest, floor: min(poll.cursor ?? cursor, cursor), pollStartedAt: startedAt,
                                        logRecreated: resynced && poll.cursor != nil)
                        result["posted"] = toPost.filter { store.record($0, for: pcID) }
                    }
                    steps.append(result)
                }
            }
            deliveryResults.append(["name": scenario.name, "steps": steps])
        }

        // Threads of one process, each with its own store value on the same file.
        let threadFile = URL(fileURLWithPath: cases.storeDirectory).appendingPathComponent("threads", isDirectory: true)
            .appendingPathComponent("DeliveredEvents.v2.json")
        let tally = Tally()
        let threadCount = max(1, cases.threadCount), threadIDs = max(1, cases.threadIDs)
        DispatchQueue.concurrentPerform(iterations: threadCount) { worker in
            let store = OrbitDeliveredStore(fileURL: threadFile)
            var generator = SeededGenerator(state: UInt64(worker + 1) * 7919)
            for id in Array(1...threadIDs).shuffled(using: &generator) where store.record(id, for: "PC-T") {
                tally.add(id)
            }
        }
        let counts = tally.snapshot
        let finalIDs = OrbitDeliveredStore(fileURL: threadFile).ids(for: "PC-T")
        let threadReport: [String: Any] = [
            "firstRecords": counts.values.reduce(0, +),
            "recordedOnce": (1...threadIDs).allSatisfy { counts[$0] == 1 },
            "storedCount": finalIDs.ids.count,
            "storedAll": (1...threadIDs).allSatisfy { finalIDs.contains($0) }
        ]

        let output: [String: Any] = [
            "crypto": cryptoResults,
            "feed": feedResults,
            "keys": keyReport,
            "categories": categories,
            "powerCategory": OrbitEventFeed.notificationCategory(for: "power.scheduled"),
            "otherCategory": OrbitEventFeed.notificationCategory(for: "download.finished"),
            "identifier": OrbitEventFeed.notificationIdentifier(pcID: "PC-1", eventID: 12),
            "texts": texts,
            "ids": idResults,
            "deliveries": deliveryResults,
            "threads": threadReport
        ]
        let json = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        FileHandle.standardOutput.write(json)
    }

    static func runFeed(_ scenario: Cases.Feed, delivered: OrbitDeliveredIDs? = nil) async -> [String: Any] {
        let script = ScriptedFetch(scenario.steps)
        var result: [String: Any] = ["name": scenario.name]
        do {
            let outcome = try await OrbitEventFeed.poll(cursor: scenario.cursor, delivered: delivered ?? scenario.delivered ?? OrbitDeliveredIDs(), holdBack: scenario.holdBack,
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
        return result
    }

    /// The extension's decision for one push, against a delivered store.
    static func receive(_ ciphertext: String, keys: [(id: String, key: Data)], deviceID: String, store: OrbitDeliveredStore) -> [String: Any] {
        guard let outcome = OrbitPushCrypto.receive(ciphertext, keys: keys, deviceID: deviceID, record: { store.record($0, for: $1) }) else {
            return ["push": -1, "opened": false]
        }
        return ["push": outcome.message.id, "pcID": outcome.pcID, "duplicate": outcome.duplicate]
    }

    static func hammer(file: String, pcID: String, seed: UInt64, count: Int) {
        let store = OrbitDeliveredStore(fileURL: URL(fileURLWithPath: file))
        var generator = SeededGenerator(state: seed)
        var first: [Int] = []
        for id in Array(1...max(1, count)).shuffled(using: &generator) where store.record(id, for: pcID) {
            first.append(id)
        }
        let json = try! JSONSerialization.data(withJSONObject: ["first": first.sorted()])
        FileHandle.standardOutput.write(json)
    }

    static func describe(_ message: OrbitPushMessage) -> [String: Any] {
        ["pc": message.pc, "id": message.id, "kind": message.kind, "title": message.title, "body": message.body,
         "ts": message.timestamp, "link": message.link]
    }
}
