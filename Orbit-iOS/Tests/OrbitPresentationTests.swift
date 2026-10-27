import Foundation

// Driver for Tests/check_presentation.py. Compiled together with Shared/OrbitPresentationModels.swift only.
// Argument 1: a JSON file with {"states": {name: GET body}, "replies": {name: POST body},
// "errors": {name: {"status": N, "body": text}}}. Prints a JSON summary of what the app makes of each,
// after checking the timer and demo-mode logic itself.

@main
struct OrbitPresentationTests {
    static func main() throws {
        checkTimer()
        checkDemo()
        checkLenientDecoding()
        checkText()

        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        var output: [String: Any] = [
            "actions": OrbitPresentationAction.allCases.map(\.rawValue),
            "bodies": [
                "goto": String(decoding: try JSONEncoder().encode(OrbitPresentationActionBody(action: .goto, slide: 7)), as: UTF8.self),
                "next": String(decoding: try JSONEncoder().encode(OrbitPresentationActionBody(action: .next, slide: 7)), as: UTF8.self)
            ]
        ]

        var states: [String: Any] = [:]
        for (name, body) in input["states"] as! [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: body)
            let state = try JSONDecoder().decode(OrbitPresentationState.self, from: data)
            // What the iPhone relays to the Watch must decode back to the same state without notes.
            let relayed = try JSONDecoder().decode(OrbitPresentationState.self, from: JSONEncoder().encode(state.forWatch))
            precondition(relayed.notes.isEmpty && relayed.slide == state.slide && relayed.control == state.control
                         && relayed.showState == state.showState && relayed.elapsedSeconds == state.elapsedSeconds, "watch copy of \(name)")
            states[name] = summary(state)
        }
        output["states"] = states

        var replies: [String: Any] = [:]
        for (name, body) in input["replies"] as! [String: Any] {
            let reply = try JSONDecoder().decode(OrbitPresentationActionReply.self, from: JSONSerialization.data(withJSONObject: body))
            let action = OrbitPresentationAction(rawValue: reply.action) ?? .next
            replies[name] = [
                "status": reply.status, "action": reply.action, "via": reply.via, "keys": reply.keys, "detail": reply.detail,
                "usedKeys": reply.usedKeys, "presentation": reply.presentation.map(summary) as Any,
                "intent": OrbitPresentationText.intentSentence(reply, action: action, pc: "Present-PC")
            ]
        }
        output["replies"] = replies

        var errors: [String: Any] = [:]
        for (name, value) in input["errors"] as! [String: Any] {
            let entry = value as! [String: Any]
            let status = entry["status"] as! Int
            let text = entry["body"] as! String
            // The app reads `detail` only when it is a string (OrbitAPIClient / OrbitWatchHTTPClient).
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            let detail = object?["detail"] as? String
            errors[name] = OrbitPresentationText.failure(status: status, detail: detail)
        }
        output["errors"] = errors

        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func summary(_ state: OrbitPresentationState) -> [String: Any] {
        [
            "app": state.app.rawValue, "running": state.running, "source": state.source.rawValue, "slide": state.slide,
            "slides": state.slides, "state": state.showState.rawValue, "control": state.control.rawValue,
            "notes": state.notes, "title": state.title, "slideTitle": state.slideTitle, "thumbnails": state.thumbnails,
            "elapsed": state.elapsedSeconds as Any, "slideElapsed": state.slideElapsedSeconds as Any,
            "position": state.positionText as Any, "spoken": state.spokenPosition as Any,
            "showingSlide": state.isShowingSlide, "canThumbnail": state.canShowThumbnail, "blocked": state.isBlocked,
            "readyInEditor": state.isReadyInEditor, "status": state.statusTitle, "controlTitle": state.controlExplanation.title
        ]
    }

    // MARK: Pure logic

    static func checkTimer() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var timer = OrbitPresentationTimer()
        precondition(timer.elapsed(at: t0) == nil && !timer.isRunning)
        // PowerPoint reports 60 s since the show started.
        timer.sync(with: OrbitPresentationState(running: true, slide: 2, slides: 9, showState: .running, control: .powerpoint, elapsedSeconds: 60), now: t0)
        precondition(timer.isRunning && timer.followsPC && timer.elapsed(at: t0) == 60)
        // A second later the PC still says 60 (it rounds down): within tolerance, the anchor stays.
        timer.sync(with: OrbitPresentationState(running: true, slide: 2, slides: 9, showState: .running, elapsedSeconds: 60), now: t0 + 1)
        precondition(timer.elapsed(at: t0 + 1) == 61)
        // The show restarted on the PC: re-anchored.
        timer.sync(with: OrbitPresentationState(running: true, slide: 1, slides: 9, showState: .running, elapsedSeconds: 3), now: t0 + 10)
        precondition(timer.elapsed(at: t0 + 10) == 3)
        // Orbit's own keys don't move a timer that follows PowerPoint.
        timer.note(.start, via: "powerpoint", now: t0 + 11)
        precondition(timer.elapsed(at: t0 + 11) == 4)
        // The show ended: the final time stays.
        timer.sync(with: OrbitPresentationState(running: false, control: .keys), now: t0 + 20)
        precondition(!timer.isRunning && timer.elapsed(at: t0 + 100) == 13)

        // Key presses (Google Slides): Orbit's own Start / End.
        var keys = OrbitPresentationTimer()
        keys.note(.black, via: "keys", now: t0)
        precondition(keys.startedAt == nil)
        keys.note(.next, via: "keys", now: t0)
        precondition(keys.isRunning && keys.elapsed(at: t0 + 5) == 5)
        keys.note(.startCurrent, via: "keys", now: t0 + 30)
        precondition(keys.elapsed(at: t0 + 30) == 30, "start from current keeps the time")
        keys.note(.start, via: "keys", now: t0 + 40)
        precondition(keys.elapsed(at: t0 + 41) == 1, "start from the beginning restarts it")
        keys.note(.end, via: "keys", now: t0 + 50)
        precondition(!keys.isRunning && keys.elapsed(at: t0 + 90) == 10)
        // A state without a running show doesn't touch a keys timer.
        keys.start(now: t0 + 100)
        keys.sync(with: OrbitPresentationState(running: false, control: .keys), now: t0 + 110)
        precondition(keys.isRunning && keys.elapsed(at: t0 + 110) == 10)
        keys.reset()
        precondition(keys.startedAt == nil && !keys.isRunning)
    }

    static func checkDemo() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var demo = OrbitPresentationDemo()
        var state = demo.state(at: t0)
        // Like a PC with the deck open in PowerPoint's editor, in front: Start works, Next waits.
        precondition(!state.running && state.isReadyInEditor && state.isBlocked && state.slides == 12 && state.control == .blocked)
        precondition(state.statusTitle == "Ready in PowerPoint" && state.positionText == nil)
        do {
            _ = try demo.perform(.next, now: t0)
            preconditionFailure("next without a show must be refused")
        } catch let refusal as OrbitPresentationDemo.Refusal {
            precondition(refusal.message.contains("Start the slide show"))
        } catch { preconditionFailure("\(error)") }
        demo.editorSlide = 4
        var reply = try! demo.perform(.startCurrent, now: t0)
        precondition(reply.detail == "Started the slide show from slide 4." && reply.presentation?.slide == 4 && reply.via == "powerpoint")
        reply = try! demo.perform(.start, now: t0 + 1)
        precondition(reply.presentation?.slide == 1 && reply.detail == "Went to the first slide.")
        for expected in 2...12 {
            reply = try! demo.perform(.next, now: t0 + 2)
            precondition(reply.presentation?.slide == expected)
        }
        reply = try! demo.perform(.next, now: t0 + 3)
        state = reply.presentation!
        precondition(state.showState == .done && state.running && !state.isShowingSlide && state.notes.isEmpty)
        reply = try! demo.perform(.previous, now: t0 + 4)
        precondition(reply.presentation?.slide == 12 && reply.presentation?.showState == .running)
        reply = try! demo.perform(.black, now: t0 + 5)
        precondition(reply.presentation?.showState == .black && !reply.presentation!.canShowThumbnail)
        reply = try! demo.perform(.goto, slide: 3, now: t0 + 6)
        precondition(reply.presentation?.slide == 3 && reply.presentation?.showState == .running, "a move shows the slide again")
        do {
            _ = try demo.perform(.goto, slide: 13, now: t0)
            preconditionFailure("goto 13 must be refused")
        } catch let refusal as OrbitPresentationDemo.Refusal {
            precondition(refusal.message == "This presentation has 12 slides. Choose a slide from 1 to 12.")
        } catch { preconditionFailure("\(error)") }
        reply = try! demo.perform(.white, now: t0 + 7)
        reply = try! demo.perform(.white, now: t0 + 8)
        precondition(reply.presentation?.showState == .running && reply.detail == "Showing the slide again.")
        state = demo.state(at: t0 + 61)
        precondition(state.elapsedSeconds == 61 && state.slideElapsedSeconds == 55)
        reply = try! demo.perform(.end, now: t0 + 70)
        precondition(reply.presentation?.running == false && reply.detail == "Ended the slide show.")
    }

    static func checkLenientDecoding() {
        func decode(_ json: String) -> OrbitPresentationState {
            try! JSONDecoder().decode(OrbitPresentationState.self, from: Data(json.utf8))
        }
        let empty = decode("{}")
        precondition(empty == OrbitPresentationState() && !empty.isShowingSlide && empty.positionText == nil)
        let odd = decode("""
            {"app":"keynote","running":true,"slide":"3","slides":12.0,"state":"spinning","control":"telepathy",
             "notes":"a\\u0000b\\nc","title":"Deck\\nTwo","elapsedSeconds":-5,"slideElapsedSeconds":3.5,"thumbnails":"yes"}
            """)
        precondition(odd.app == .unknown && odd.slide == 0 && odd.slides == 12 && odd.showState == .unknown)
        precondition(odd.control == .unknown && odd.notes == "ab\nc" && odd.title == "Deck Two")
        precondition(odd.elapsedSeconds == nil && odd.slideElapsedSeconds == nil && !odd.thumbnails)
        let clamped = decode(#"{"running":true,"slide":40,"slides":12,"elapsedSeconds":3.0}"#)
        precondition(clamped.slide == 12 && clamped.elapsedSeconds == 3 && clamped.source == .show && clamped.showState == .running && clamped.control == .powerpoint)
        let long = decode("{\"notes\":\"\(String(repeating: "x", count: 25_000))\"}")
        precondition(long.notes.count == OrbitPresentationState.maxNotes + 1 && long.notes.hasSuffix("…"))
        let reply = try! JSONDecoder().decode(OrbitPresentationActionReply.self, from: Data(#"{"detail":"  Pressed Right on the PC.  ","presentation":{"bogus":1},"keys":"Right"}"#.utf8))
        precondition(reply.status == "done" && reply.detail == "Pressed Right on the PC." && reply.keys.isEmpty)
        precondition(reply.presentation == OrbitPresentationState(), "an unreadable presentation decodes to defaults, never fails the reply")
    }

    static func checkText() {
        precondition(OrbitPresentationText.clock(0) == "0:00" && OrbitPresentationText.clock(65) == "1:05")
        precondition(OrbitPresentationText.clock(3723) == "1:02:03" && OrbitPresentationText.clock(-4) == "0:00")
        precondition(OrbitPresentationText.clock(.infinity) == "0:00")
        precondition(OrbitPresentationText.spokenDuration(61) == "1 minute 1 second")
        precondition(OrbitPresentationText.spokenDuration(0) == "0 seconds")
        precondition(OrbitPresentationText.spokenDuration(7200) == "2 hours")
        precondition(OrbitPresentationText.failure(status: 500, detail: "Something broke") == "Something broke.")
        precondition(OrbitPresentationText.intentSentence(nil, action: .next, pc: "PC") == "Sent “Next slide” to PC.")
    }
}
