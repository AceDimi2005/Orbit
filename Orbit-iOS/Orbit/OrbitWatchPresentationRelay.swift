import Foundation

/// The Watch's Present page through the iPhone (bridge command `presentation`, DESIGN F8).
///
/// From the Watch: `{"cmd": "presentation", "action": <OrbitPresentationAction raw value> | "state",
/// "slide": N (goto only), "pcID", "host", "expiresAt"}`. `OrbitWatchBridge.forwardPCCommand` checks the
/// PC id, host and deadline before handing it here, exactly like the other PC commands.
///
/// Reply: `{"status": "sent", "pcID", "via"?, "detail"?, "presentation"?}` where `presentation` is the JSON
/// (`Data`) of `OrbitPresentationState.forWatch` (no speaker notes), or
/// `{"status": "failed", "message", "code"?: "olderAgent"}`. "state" only reads `GET /api/presentation`.
@MainActor
enum OrbitWatchPresentationRelay {
    static let command = "presentation"
    static let stateAction = "state"

    /// One pinned client for the selected PC's connection, reused by every Watch read and action: the Present
    /// page reads the slide show every 2 s, and a new client each time would mean a new TLS handshake (with
    /// the certificate check) on the iPhone and on the PC for every read. Dropped after a failure that wasn't
    /// a reply from the PC, so a broken connection isn't reused.
    private static var cached: (key: String, client: OrbitAPIClient)?

    /// `vm` is the iPhone's view model; `OrbitWatchBridge.forwardPCCommand` already checked that `pcID` and the
    /// Watch's host are its selected PC and that the command hasn't expired.
    static func forward(_ message: [String: Any], vm: OrbitViewModel, pcID: String, deadline: Double) async -> [String: Any] {
        // The address is part of the key: with a Secondary IP the route can move between the LAN and the
        // secondary address without a new connection ID, and the next client should follow it.
        let key = "\(pcID)#\(vm.connectionID)#\(vm.connectionHost())"
        let client: OrbitAPIClient
        if let cached, cached.key == key {
            client = cached.client
        } else {
            do { client = try vm.companionClient() } catch { return failed(error.localizedDescription) }
            cached = (key, client)
        }
        let result = await forward(message, client: client, pcID: pcID, pcName: vm.selectedPCName, deadline: deadline)
        if !result.keepsClient, cached?.key == key { cached = nil }
        return result.reply
    }

    /// The reply for the Watch, and whether the client may be used again (false after a timeout, a lost
    /// connection or a certificate problem).
    private struct Outcome {
        var reply: [String: Any]
        var keepsClient = true
    }

    private static func forward(_ message: [String: Any], client: OrbitAPIClient, pcID: String, pcName: String,
                                deadline: Double) async -> Outcome {
        let name = message["action"] as? String ?? ""
        let isStateRead = name == stateAction
        let action = OrbitPresentationAction(rawValue: name)
        guard isStateRead || action != nil else {
            return Outcome(reply: failed("This slide show action isn't supported. Update Orbit on your iPhone and watch."))
        }
        var slide: Int?
        if action == .goto {
            guard let number = message["slide"] as? Int, OrbitPresentationAction.slideRange.contains(number) else {
                return Outcome(reply: failed("Choose a slide number from the presentation."))
            }
            slide = number
        }

        // Older agents have no presentation remote; the answer is cached for 10 minutes per PC, but a PC that
        // lacked it is asked again after half a minute (it may have been updated meanwhile). Bounded well inside
        // the Watch's wait (the shared client alone would wait 20 s).
        do {
            let link = OrbitPCLink(id: pcID, name: pcName, client: client)
            let maxAge: TimeInterval = OrbitFeatureStore.shared.cached(pcID).has("presentation") ? 600 : 30
            let features = try await OrbitDeadline.run(seconds: 4) { try await OrbitFeatureStore.shared.features(for: link, maxAge: maxAge) }
            guard features.has("presentation") else { return Outcome(reply: failed(OrbitPresentationText.olderAgent, code: "olderAgent")) }
        } catch {
            return Outcome(reply: failed(OrbitPlainError.describe(error)), keepsClient: isReply(error))
        }
        // A command that waited too long on the way must not change a slide any more.
        guard isStateRead || deadline > Date().timeIntervalSince1970 else { return Outcome(reply: failed("The command expired. Try again.")) }

        do {
            if isStateRead {
                let data = try await OrbitDeadline.run(seconds: 5) { try await client.data("/api/presentation") }
                return Outcome(reply: sent(pcID: pcID, state: try JSONDecoder().decode(OrbitPresentationState.self, from: data)))
            }
            guard let action else { return Outcome(reply: failed("This slide show action isn't supported.")) }
            let body = OrbitPresentationActionBody(action: action, slide: slide)
            // Sent once: an unanswered action may already have changed the slide, so it is never replayed.
            let reply: OrbitPresentationActionReply = try await OrbitDeadline.run(seconds: 9) {
                try await client.send(action.path, method: "POST", body: body)
            }
            var result = sent(pcID: pcID, state: reply.presentation)
            result["via"] = reply.via
            if !reply.detail.isEmpty { result["detail"] = reply.detail }
            return Outcome(reply: result)
        } catch is DecodingError {
            // The PC carried out the action but its reply wasn't readable; the Watch reads the state next.
            return Outcome(reply: sent(pcID: pcID, state: nil))
        } catch let error as OrbitError where error.statusCode != nil {
            let status = error.statusCode ?? 0
            let detail = error.message.hasPrefix("PC returned error ") ? nil : error.message
            if status == 404, detail == nil || detail == "Not Found" {
                OrbitFeatureStore.shared.invalidate(pcID)
                return Outcome(reply: failed(OrbitPresentationText.olderAgent, code: "olderAgent"))
            }
            return Outcome(reply: failed(OrbitPresentationText.failure(status: status, detail: detail)))
        } catch let error as URLError where error.code == .timedOut && !isStateRead {
            return Outcome(reply: failed("Your PC didn't answer in time, so the slide may still have changed. Check it before trying again."),
                          keepsClient: false)
        } catch {
            return Outcome(reply: failed(OrbitPlainError.describe(error)), keepsClient: false)
        }
    }

    /// The PC answered (with an error status), so the connection itself is fine.
    private static func isReply(_ error: Error) -> Bool {
        (error as? OrbitError)?.statusCode != nil || error is DecodingError
    }

    private static func sent(pcID: String, state: OrbitPresentationState?) -> [String: Any] {
        var reply: [String: Any] = ["status": "sent", "pcID": pcID]
        if let state, let data = try? JSONEncoder().encode(state.forWatch) { reply["presentation"] = data }
        return reply
    }

    private static func failed(_ message: String, code: String? = nil) -> [String: Any] {
        var reply: [String: Any] = ["status": "failed", "message": message]
        if let code { reply["code"] = code }
        return reply
    }
}
