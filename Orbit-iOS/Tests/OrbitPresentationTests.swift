import Foundation

// Driver for Tests/check_presentation.py. Compiled together with Shared/OrbitPresentationModels.swift only.
// Argument 1: a JSON file with {"states": {name: GET body}, "replies": {name: POST body},
// "errors": {name: {"status": N, "body": text}}}. Prints a JSON summary of what the app makes of each,
// after checking the timer and demo-mode logic itself.

@main
struct OrbitPresentationTests {
    static func main() throws {
        checkTimer()
        checkTimerByHand()
        checkSavedTimer()
        checkQueue()
        checkReminderPlan()
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

    /// "Start Timer Now" / "Reset Timer" (iPhone) and "Restart timer" / "Reset timer" (Watch) during PowerPoint's
    /// show: the next read must not put the PC's show time back.
    static func checkTimerByHand() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func show(_ elapsed: Int) -> OrbitPresentationState {
            OrbitPresentationState(app: .powerpoint, running: true, source: .show, slide: 3, slides: 12, showState: .running,
                                   control: .powerpoint, elapsedSeconds: elapsed)
        }
        let ended = OrbitPresentationState(app: .powerpoint, running: false, source: .editor, slide: 3, slides: 12, control: .keys)
        var timer = OrbitPresentationTimer()
        timer.sync(with: show(600), now: t0)
        precondition(timer.isFollowingPC && !timer.overridesPC && timer.elapsed(at: t0) == 600)
        // Reset during the show: stays at 0:00 after the next reads.
        timer.resetByHand()
        timer.sync(with: show(601), now: t0 + 1)
        timer.sync(with: show(602), now: t0 + 2)
        precondition(timer.startedAt == nil && !timer.isRunning && timer.overridesPC, "a reset during the show stays reset")
        // The next slide change Orbit sends starts it (like with key presses).
        timer.note(.next, via: "powerpoint", now: t0 + 3)
        timer.sync(with: show(604), now: t0 + 4)
        precondition(timer.isRunning && timer.elapsed(at: t0 + 4) == 1 && timer.overridesPC)
        // Start Timer Now during the show: counts from zero, the PC's 10 minutes don't come back.
        timer.startByHand(now: t0 + 10)
        timer.sync(with: show(611), now: t0 + 11)
        timer.sync(with: show(612), now: t0 + 12)
        precondition(timer.elapsed(at: t0 + 12) == 2 && !timer.isFollowingPC, "a start during the show counts from zero")
        // Restart from slide 1 (PowerPoint keeps its own show time): the user's timer starts again too.
        timer.note(.start, via: "powerpoint", now: t0 + 20)
        timer.sync(with: show(620), now: t0 + 21)
        precondition(timer.elapsed(at: t0 + 21) == 1 && timer.overridesPC)
        // The show ends: the final time stays, and the next show is followed again.
        timer.sync(with: ended, now: t0 + 50)
        precondition(!timer.isRunning && !timer.overridesPC && timer.elapsed(at: t0 + 99) == 30)
        timer.sync(with: show(5), now: t0 + 100)
        precondition(timer.isFollowingPC && timer.elapsed(at: t0 + 100) == 5, "a new show is followed again")
        // A reset during the show, then the show ends while reset: nothing runs, the next show is followed.
        timer.resetByHand()
        timer.sync(with: ended, now: t0 + 110)
        precondition(timer.startedAt == nil && !timer.overridesPC)
        timer.sync(with: show(2), now: t0 + 120)
        precondition(timer.isFollowingPC && timer.elapsed(at: t0 + 120) == 2)
        // Orbit didn't see the show end (the screen or the Watch page was closed), and another show started: that
        // one is followed. The same show much later, or its start moving by a few seconds, keeps the user's timer.
        var missed = OrbitPresentationTimer()
        missed.sync(with: show(300), now: t0)
        missed.startByHand(now: t0 + 1)
        precondition(missed.overriddenShowStart == t0 - 300)
        missed.sync(with: show(3900), now: t0 + 3600)
        precondition(missed.overridesPC && missed.elapsed(at: t0 + 3600) == 3599, "the same show an hour later")
        missed.sync(with: show(3905), now: t0 + 3602)
        precondition(missed.overridesPC && missed.overriddenShowStart == t0 - 303, "a drift of seconds keeps the user's timer")
        let unchanged = missed
        missed.sync(with: show(3906), now: t0 + 3603)
        precondition(missed == unchanged, "a read within the tolerance changes nothing (no publish per read)")
        missed.sync(with: show(40), now: t0 + 7200)
        precondition(missed.isFollowingPC && !missed.overridesPC && missed.overriddenShowStart == nil && missed.elapsed(at: t0 + 7200) == 40,
                     "another show is followed again")
        // By hand without a PowerPoint show (key presses): no override, so a PowerPoint show started later is followed.
        var keys = OrbitPresentationTimer()
        keys.startByHand(now: t0)
        precondition(keys.isRunning && !keys.overridesPC)
        keys.sync(with: show(3), now: t0 + 30)
        precondition(keys.isFollowingPC && keys.elapsed(at: t0 + 30) == 3)
        // After PowerPoint's show ended (final time on screen) a reset is a plain reset.
        keys.sync(with: ended, now: t0 + 40)
        keys.resetByHand()
        precondition(!keys.overridesPC && keys.startedAt == nil)
        // Another PC or demo mode: everything goes, the override too.
        timer.startByHand(now: t0 + 200)
        precondition(timer.overridesPC)
        timer.reset()
        precondition(timer == OrbitPresentationTimer())
    }

    /// Taps waiting behind a failed or slow action are dropped, never sent seconds later.
    static func checkQueue() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var queue = OrbitPresentationQueue(capacity: 4, maxWait: 2.5)
        precondition(queue.isEmpty && queue.first == nil && queue.finishFirst(now: t0) == 0 && queue.dropWaiting() == 0)
        // Quick taps go out one after another.
        for tap in 0..<4 { precondition(queue.append(.next, now: t0 + Double(tap) * 0.2)) }
        precondition(!queue.append(.next, now: t0 + 1), "the fifth tap is refused while four wait")
        precondition(queue.finishFirst(now: t0 + 0.5) == 0 && queue.count == 3 && queue.first?.queuedAt == t0 + 0.2)
        // The action in flight failed: the taps behind it are dropped; the one in flight stays first until finished.
        precondition(queue.dropWaiting() == 2 && queue.count == 1 && queue.first?.queuedAt == t0 + 0.2)
        precondition(queue.finishFirst(now: t0 + 9) == 0 && queue.isEmpty)
        // A slow action: every tap made while it was on its way is dropped once the first one waited too long,
        // also the one made just before it landed.
        queue.append(.next, now: t0 + 10)
        queue.append(.next, now: t0 + 10.5)
        queue.append(.goto, slide: 7, now: t0 + 12.9)
        precondition(queue.finishFirst(now: t0 + 13.2) == 2 && queue.isEmpty, "a stale head drops every waiting tap")
        // A tap made after the slow one landed goes out as usual.
        queue.append(.previous, now: t0 + 14)
        precondition(queue.first?.action == .previous && queue.first?.slide == nil && queue.finishFirst(now: t0 + 14.1) == 0)
        // Waiting exactly the limit still goes out; the slide number travels with its tap.
        queue.append(.next, now: t0 + 20)
        queue.append(.goto, slide: 9, now: t0 + 20)
        precondition(queue.finishFirst(now: t0 + 22.5) == 0 && queue.first?.slide == 9 && queue.first?.action == .goto)
        queue.removeAll()
        precondition(queue.isEmpty && queue.count == 0)
        precondition(OrbitPresentationText.skippedSlowTaps(1).contains("your next tap.")
                     && OrbitPresentationText.skippedSlowTaps(3).contains("your next 3 taps."))
        precondition(OrbitPresentationText.skippedTapsAfterFailure(2) == "Orbit didn't send the 2 taps after it."
                     && OrbitPresentationText.skippedTapsAfterFailure(1) == "Orbit didn't send the tap after it.")
        precondition(OrbitPresentationText.skippedTapsShort(1) == "Skipped 1 tap." && OrbitPresentationText.skippedTapsShort(3) == "Skipped 3 taps.")
    }

    /// The Watch keeps a running talk timer across launches (`Orbit.WatchPresentTalk.v1`).
    static func checkSavedTimer() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000.25)
        func roundTrip(_ timer: OrbitPresentationTimer) -> OrbitPresentationTimer {
            try! JSONDecoder().decode(OrbitPresentationTimer.self, from: JSONEncoder().encode(timer))
        }
        var pc = OrbitPresentationTimer()
        pc.sync(with: OrbitPresentationState(running: true, slide: 2, slides: 9, showState: .running, control: .powerpoint, elapsedSeconds: 75), now: t0)
        var restored = roundTrip(pc)
        precondition(restored == pc && restored.isRunning && restored.followsPC && restored.elapsed(at: t0 + 5) == 80)
        // Picked up again, the PC's show time keeps the same anchor (no jump in the reminders).
        restored.sync(with: OrbitPresentationState(running: true, slide: 3, slides: 9, showState: .running, elapsedSeconds: 95), now: t0 + 20)
        precondition(restored.startedAt == pc.startedAt)
        var keys = OrbitPresentationTimer()
        keys.note(.next, via: "keys", now: t0)
        keys.note(.end, via: "keys", now: t0 + 30)
        precondition(roundTrip(keys) == keys && !roundTrip(keys).isRunning && roundTrip(keys).elapsed(at: t0 + 99) == 30)
        precondition(roundTrip(OrbitPresentationTimer()) == OrbitPresentationTimer())
        // A timer restarted by hand during the show keeps ignoring the PC's show time after a relaunch.
        var mine = pc
        mine.startByHand(now: t0 + 30)
        let reopened = roundTrip(mine)
        precondition(reopened == mine && reopened.overridesPC && reopened.overriddenShowStart == pc.startedAt
                     && reopened.elapsed(at: t0 + 40) == 10)
    }

    static func checkReminderPlan() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func plan(after seconds: TimeInterval, minutes: Int = 5, limit: Int = 48, horizon: TimeInterval = 3 * 3600) -> [(number: Int, delay: TimeInterval)] {
            OrbitPresentationReminderPlan.upcoming(startedAt: start, now: start + seconds, minutes: minutes, limit: limit, horizon: horizon)
        }
        // Every 5 minutes from the start, within 3 hours: 36 reminders, the first one 5 minutes in.
        var reminders = plan(after: 0)
        precondition(reminders.count == 36 && reminders.first?.number == 1 && reminders.first?.delay == 300)
        precondition(reminders.last?.number == 36 && reminders.last?.delay == 3 * 3600)
        // 7.5 minutes in: the next one is the second (10 minutes), due in 2.5 minutes.
        reminders = plan(after: 450)
        precondition(reminders.first?.number == 2 && reminders.first?.delay == 150)
        // Exactly at a reminder: that one was just delivered, the window moves on.
        reminders = plan(after: 600)
        precondition(reminders.first?.number == 3 && reminders.first?.delay == 300)
        // Every minute: capped by the number of slots, not by the horizon.
        reminders = plan(after: 30, minutes: 1)
        precondition(reminders.count == 48 && reminders.first?.number == 1 && reminders.first?.delay == 30 && reminders.last?.number == 48)
        // A timer that started in the future (clock change) still plans from the first reminder.
        reminders = OrbitPresentationReminderPlan.upcoming(startedAt: start + 120, now: start, minutes: 2, limit: 3, horizon: 3600)
        precondition(reminders.map(\.number) == [1, 2, 3] && reminders.first?.delay == 240)
        precondition(plan(after: 0, minutes: 0).isEmpty && plan(after: 0, limit: 0).isEmpty)
        precondition(plan(after: 0, minutes: 30, horizon: 1200).isEmpty, "nothing due within the horizon")
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
        // Format characters belong to the text (an emoji ZWJ sequence, a right-to-left mark after Hebrew, a soft
        // hyphen, bidi isolates); only control characters (here a bell and a carriage return) are removed.
        let joined = "Team \u{1F469}\u{200D}\u{1F4BB} \u{05E9}\u{05DC}\u{05D5}\u{05DD}\u{200F} co\u{00AD}operate"
        let isolated = "\u{2067}\u{05E9}\u{05DC}\u{05D5}\u{05DD}\u{2069} Agenda"
        let formatted = try! JSONDecoder().decode(OrbitPresentationState.self, from: JSONSerialization.data(withJSONObject: [
            "notes": joined + "\u{0007}\r", "title": "Deck \u{1F469}\u{200D}\u{1F4BB}\u{200F}", "slideTitle": isolated
        ]))
        precondition(Array(formatted.notes.unicodeScalars) == Array(joined.unicodeScalars), "notes keep ZWJ, RLM and soft hyphen")
        precondition(Array(formatted.title.unicodeScalars) == Array("Deck \u{1F469}\u{200D}\u{1F4BB}\u{200F}".unicodeScalars))
        precondition(Array(formatted.slideTitle.unicodeScalars) == Array(isolated.unicodeScalars), "titles keep bidi isolates")
        precondition(formatted.forWatch.title == formatted.title)
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
