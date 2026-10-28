import Foundation

// Checks for Shared/OrbitStreamDisplay.swift and Shared/OrbitStreamDisplayModels.swift, run by
// Tests/check_stream_display.py:
//   --unit                                    model, checks, bodies and error wording, then the Fill Screen model
//                                             and the Second Screen session driven against a scripted PC
//                                             (OrbitStreamDisplayFlowChecks.swift)
//   --live <port> <token> <fingerprint> <command…>   one request against the agent over pinned TLS,
//                                             printing what the apps would see as JSON
// Commands: features | status W H [R] | modes W H R | fill on|off|only W H | second on W H R left|right | second off W H | revert W H

@main
struct OrbitStreamDisplayChecks {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        if condition() { return }
        failures += 1
        print("FAIL: \(label)")
    }

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--unit" {
            unitChecks()
            await OrbitStreamDisplayFlowChecks.run()
            if failures > 0 { exit(1) }
            print("PASS: stream display model, checks, request bodies and error wording; Fill Screen model and Second Screen session flows")
            return
        }
        if arguments.first == "--live", arguments.count >= 5 {
            await live(port: Int(arguments[1]) ?? 0, token: arguments[2], fingerprint: arguments[3], command: Array(arguments.dropFirst(4)))
            return
        }
        print("usage: --unit | --live <port> <token> <fingerprint> <command…>")
        exit(2)
    }

    // MARK: - Unit checks

    static func decode(_ json: String) -> OrbitStreamDisplayStatus? {
        try? JSONDecoder().decode(OrbitStreamDisplayStatus.self, from: Data(json.utf8))
    }

    static func ready(listing: [String] = ["1920x1080", "2560x1440", "3840x2160"]) -> OrbitStreamDisplayStatus {
        var status = OrbitStreamDisplayStatus()
        status.loginSaved = true
        status.sunshineVersion = "2026.1017.152030"
        status.sunshineSupported = true
        status.streamActive = false
        status.appRunning = false
        status.virtualDisplay.installed = true
        status.virtualDisplay.driver = "vdd"
        status.virtualDisplay.deviceStatus = "running"
        status.virtualDisplay.deviceId = "{9a7f2e1c-4b3d-5e6f-8a9b-0c1d2e3f4a5b}"
        status.virtualDisplay.resolutions = listing
        status.fillReady = true
        return status
    }

    static func unitChecks() {
        let phone = OrbitDisplaySize(width: 2556, height: 1178)

        // Decoding never fails on missing or odd fields (older and newer agents).
        let empty = decode("{}")
        expect(empty != nil, "an empty object decodes")
        expect(empty?.loginSaved == false && empty?.fill.enabled == false && empty?.secondScreen.active == false && empty?.fillReady == false,
               "missing fields read as off")
        let odd = decode(#"{"loginSaved":"yes","virtualDisplay":{"installed":true,"modes":"x","refreshRates":[60,"a"]},"fill":3,"newThing":{"a":1}}"#)
        expect(odd != nil, "wrong types and unknown keys do not break decoding")
        expect(odd?.virtualDisplay.installed == true && odd?.virtualDisplay.modes == [] && odd?.loginSaved == false, "bad values fall back to defaults")
        let result = try? JSONDecoder().decode(OrbitStreamDisplayResult.self, from: Data(#"{"changed":true,"warning":"  ","display":{"loginSaved":true}}"#.utf8))
        expect(result?.changed == true && result?.cleanWarning == nil && result?.display?.loginSaved == true, "results decode, blank warnings are dropped")

        // Request bodies.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func json<T: Encodable>(_ value: T) -> String { String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self) }
        expect(json(OrbitSecondScreenBody(enabled: false, width: nil, height: nil, refreshRate: 60, position: "right"))
               == #"{"enabled":false,"position":"right","refreshRate":60}"#, "second screen off sends no size")
        expect(json(OrbitSecondScreenBody(enabled: true, width: 2732, height: 2048, refreshRate: 120, position: "left"))
               == #"{"enabled":true,"height":2048,"position":"left","refreshRate":120,"width":2732}"#, "second screen on sends the size")
        expect(json(OrbitStreamDisplayFillBody(enabled: true, onlyDisplay: false)) == #"{"enabled":true,"onlyDisplay":false}"#, "fill body")
        expect(json(OrbitStreamDisplayModeBody(width: 2556, height: 1178, refreshRate: 120)) == #"{"height":1178,"refreshRate":120,"width":2556}"#, "modes body")
        expect(OrbitStreamDisplayAPI.clampedRefreshRate(1000) == 500 && OrbitStreamDisplayAPI.clampedRefreshRate(10) == 24
               && OrbitStreamDisplayAPI.clampedRefreshRate(90) == 90, "refresh rates stay within what the PC accepts")
        expect(OrbitDisplaySize(width: 2556, height: 1178).isAcceptedByPC && !OrbitDisplaySize(width: 8192, height: 4320).isAcceptedByPC
               && !OrbitDisplaySize(width: 600, height: 400).isAcceptedByPC, "sizes outside 640×480…7680×4320 are refused locally")
        expect(phone.key == "2556x1178" && phone.description == "2556 × 1178", "size key and label")

        // Fill Screen checks.
        var noLogin = OrbitStreamDisplayStatus()
        noLogin.reason = "Save your Sunshine web UI login in Orbit first, so Orbit can change Sunshine's settings."
        let noLoginChecks = noLogin.fillChecks(size: phone)
        expect(noLoginChecks.map(\.kind) == [.login, .sunshine, .driver, .size, .sunshineTarget], "checks come in the order the PC needs them")
        expect(noLoginChecks.first?.state == .missing, "a missing login is the first thing to fix")
        expect(noLogin.fillShortfall(size: phone, pcName: "Gaming-PC") == "Orbit needs your Sunshine login to set up Gaming-PC.", "shortfall: login")
        expect(noLogin.secondScreenBlocker != nil, "second screen needs the login")

        var rejected = ready()
        rejected.sunshineVersion = nil
        rejected.sunshineSupported = nil
        rejected.sunshineRunning = true
        rejected.reason = "Sunshine rejected the saved web UI login. Save it again in Orbit."
        let rejectedLogin = rejected.fillChecks(size: phone).first
        expect(rejectedLogin?.state == .missing && rejectedLogin?.detail == rejected.reason, "a saved login Sunshine refuses is asked for again")
        expect(rejected.loginRejected && rejected.loginUnconfirmed && !rejected.sunshineStopped, "a refused login reads as refused")
        expect(rejected.fillShortfall(size: phone, pcName: "PC") == "Sunshine on PC didn't accept the saved login.", "shortfall: refused login")
        expect(rejected.secondScreenBlocker == "Save your Sunshine login again first: Sunshine didn't accept it.", "a refused login blocks the second screen")

        // Sunshine stopped: the login may be fine, so nobody is asked to type it again.
        var stopped = ready()
        stopped.sunshineVersion = nil
        stopped.sunshineSupported = nil
        stopped.sunshineRunning = false
        stopped.fillReady = false
        stopped.reason = "Could not reach Sunshine's web UI on this PC. Make sure Sunshine is running, then try again."
        let stoppedChecks = stopped.fillChecks(size: phone)
        expect(stopped.sunshineStopped && !stopped.loginRejected && !stopped.loginUnconfirmed, "Sunshine stopped is told apart from a refused login")
        expect(stoppedChecks[0].kind == .login && stoppedChecks[0].state == .unknown && stoppedChecks[0].detail?.contains("once Sunshine runs") == true,
               "Sunshine stopped: the login row waits, without the form")
        expect(stoppedChecks[1].kind == .sunshine && stoppedChecks[1].state == .missing && stoppedChecks[1].title == "Sunshine running on the PC",
               "Sunshine stopped: the Sunshine row says so")
        expect(stopped.fillShortfall(size: phone, pcName: "PC") == "Sunshine isn't running on PC.", "shortfall: Sunshine first")
        expect(stopped.secondScreenBlocker == "Start Sunshine on the PC first.", "Sunshine stopped blocks the second screen")
        expect(stopped.pcNote == nil, "Sunshine stopped has its own row, not a note")
        // Sunshine runs, but its web UI does not answer the PC: neither the login's fault nor a stopped Sunshine.
        var unreachable = stopped
        unreachable.sunshineRunning = true
        expect(!unreachable.sunshineStopped && unreachable.loginUnconfirmed && !unreachable.loginRejected, "an unreachable web UI is not a refused login")
        expect(unreachable.fillChecks(size: phone)[0].state == .unknown && unreachable.fillChecks(size: phone)[0].detail == unreachable.reason,
               "an unreachable web UI shows the PC's sentence without the form")
        expect(unreachable.fillShortfall(size: phone, pcName: "PC") == "Orbit can't reach Sunshine's web UI on PC.", "shortfall: unreachable web UI")

        var old = ready()
        old.sunshineSupported = false
        old.sunshineVersion = "0.23.1"
        expect(old.fillChecks(size: phone)[1].state == .missing && old.fillChecks(size: phone)[1].detail?.contains("0.23.1") == true, "old Sunshine is named")
        expect(old.secondScreenBlocker == "Update Sunshine on the PC to 2025.118 or newer.", "old Sunshine blocks the second screen")

        var none = ready()
        none.virtualDisplay = .init()
        expect(!none.driverUsable && none.offersInstallCommand && none.driverInstallCommand == OrbitStreamDisplayStatus.defaultInstallCommand,
               "no driver: offer the winget command")
        expect(none.fillChecks(size: phone)[3].state == .unknown, "the size is unknown without the driver")
        expect(none.fillShortfall(size: phone, pcName: "PC") == "PC needs the free Virtual Display Driver.", "shortfall: driver")
        var sudo = none
        sudo.virtualDisplay.installed = true
        sudo.virtualDisplay.driver = "sudovda"
        expect(sudo.offersInstallCommand && sudo.driverProblem?.contains("SudoVDA") == true, "SudoVDA: explain and offer VDD")
        // Under the Start button the driver problem is a sentence of its own (the row above ends with the command).
        for (label, status) in [("no driver", none), ("SudoVDA", sudo)] {
            let blocker = status.secondScreenBlocker ?? ""
            expect(blocker.hasSuffix(".") && !blocker.hasSuffix(":") && blocker.contains("The command is above"),
                   "\(label): the Start caption is a full sentence")
        }
        expect(none.driverProblem?.hasSuffix(":") == true, "the driver row still leads into the command")
        var disabled = ready()
        disabled.virtualDisplay.deviceStatus = "disabled"
        expect(!disabled.driverUsable && !disabled.offersInstallCommand && disabled.driverProblem?.contains("Device Manager") == true,
               "a disabled driver is not reinstalled")

        var notListed = ready()
        expect(!notListed.lists(phone) && notListed.fillChecks(size: phone)[3].state == .missing, "the phone's size is missing at first")
        expect(notListed.fillShortfall(size: phone, pcName: "PC") == "PC's virtual display doesn't offer 2556 × 1178 yet.", "shortfall: size")
        notListed.virtualDisplay.modes = ["2556x1178@120"]
        expect(notListed.lists(phone), "a size listed only in modes counts")

        // The stream's frame rate counts too: the PC lists every size at every refresh rate of the driver.
        var rates = ready(listing: ["1920x1080", "2556x1178"])
        rates.virtualDisplay.modes = ["1920x1080@60", "1920x1080@120", "2556x1178@60", "2556x1178@120"]
        rates.fill.enabled = true
        rates.config.outputName = rates.virtualDisplay.deviceId
        expect(rates.lists(phone, refreshRate: 120) && !rates.lists(phone, refreshRate: 90), "a size is listed per refresh rate")
        expect(rates.fillsScreen(size: phone, refreshRate: 60) && !rates.fillsScreen(size: phone, refreshRate: 90), "a missing refresh rate does not fill")
        expect(rates.fillShortfall(size: phone, refreshRate: 90, pcName: "PC") == "PC's virtual display doesn't offer 2556 × 1178 at 90 Hz yet.",
               "shortfall: refresh rate")
        expect(rates.fillChecks(size: phone, refreshRate: 90)[3].state == .missing && rates.fillChecks(size: phone, refreshRate: 90)[3].title.contains("90 Hz"),
               "the size check names the refresh rate")
        var sizesOnly = rates
        sizesOnly.virtualDisplay.modes = []
        expect(sizesOnly.lists(phone, refreshRate: 90), "an agent listing no modes is judged by the size alone")

        // Fill Screen on without a usable driver: Sunshine has no virtual display to stream.
        var noDriverFill = ready(listing: ["2556x1178"])
        noDriverFill.fill.enabled = true
        noDriverFill.virtualDisplay = .init()
        noDriverFill.config.outputName = nil
        let noDriverTarget = noDriverFill.fillChecks(size: phone).last
        expect(!noDriverFill.sunshineStreamsVirtualDisplay && noDriverTarget?.state == .missing && noDriverTarget?.detail?.contains("own monitor") == true,
               "fill on without the driver is not shown as streaming the virtual display")
        var disabledFill = ready(listing: ["2556x1178"])
        disabledFill.fill.enabled = true
        disabledFill.config.outputName = disabledFill.virtualDisplay.deviceId
        disabledFill.virtualDisplay.deviceStatus = "disabled"
        expect(!disabledFill.sunshineStreamsVirtualDisplay && !disabledFill.fillsScreen(size: phone), "a disabled driver does not count as streaming it")

        var listedOff = ready(listing: ["1920x1080", "2556x1178"])
        expect(listedOff.fillShortfall(size: phone, pcName: "PC") == "Sunshine on PC still streams the main monitor.", "shortfall: fill off")
        expect(!listedOff.fillsScreen(size: phone), "listed but off does not fill")
        listedOff.fill.enabled = true
        listedOff.config.outputName = listedOff.virtualDisplay.deviceId
        expect(listedOff.fillsScreen(size: phone) && listedOff.fillShortfall(size: phone, pcName: "PC") == nil, "listed and on fills the screen")
        expect(listedOff.fillChecks(size: phone).allSatisfy { $0.state == .done }, "every check done when it fills")
        var otherOutput = listedOff
        otherOutput.config.outputName = "{11111111-2222-3333-4444-555555555555}"
        expect(!otherOutput.fillsScreen(size: phone), "Sunshine pointed at another display does not count")
        expect(otherOutput.fillChecks(size: phone).last?.state == .missing && otherOutput.fillChecks(size: phone).last?.detail?.contains("another display") == true,
               "Sunshine pointed at another display says so")
        var notReady = listedOff
        notReady.fillReady = false
        notReady.reason = "Sunshine does not list the virtual display yet. Restart the PC so the Virtual Display Driver and Sunshine start together, then try again."
        expect(!notReady.fillsScreen(size: phone) && notReady.fillShortfall(size: phone, pcName: "PC") == notReady.reason, "the PC's own reason is shown")
        expect(notReady.secondScreenBlocker == nil, "a reason the PC fixes itself does not block the second screen")

        // The PC's own reason is shown as a note only when no row of its own explains it.
        expect(notReady.pcNote == notReady.reason, "a reason without a row of its own becomes the PC's note")
        expect(listedOff.pcNote == nil, "no note when the PC is ready")
        var driverReason = none
        driverReason.fillReady = false
        driverReason.reason = "Install the free Virtual Display Driver on the PC first."
        expect(driverReason.pcNote == nil, "a missing driver has its own row, not a note")
        var loginReason = rejected
        loginReason.fillReady = false
        expect(loginReason.pcNote == nil, "a login Sunshine refuses has its own row, not a note")
        var blankReason = notReady
        blankReason.reason = "  "
        expect(blankReason.pcNote == nil, "a blank reason is not shown")

        // Second screen: something running in Sunshine.
        var busy = ready()
        busy.appRunning = true
        expect(busy.isBusy && busy.secondScreenChecks.last?.kind == .idle && busy.secondScreenChecks.last?.state == .missing, "a running app is flagged")
        var unknown = ready()
        unknown.streamActive = nil
        expect(unknown.secondScreenChecks.last?.state == .unknown, "an unknown stream state is not shown as done")
        expect(ready().secondScreenChecks.last?.state == .done && ready().secondScreenBlocker == nil, "an idle, ready PC can start")

        // Messages after a change.
        var secondOn = ready()
        secondOn.secondScreen.active = true
        expect(OrbitStreamDisplayMessages.fillOff(display: secondOn, pcName: "PC").contains("Second Screen is still on"),
               "Fill Screen off while the second screen stays on says streams still show the extra display")
        expect(OrbitStreamDisplayMessages.fillOff(display: ready(), pcName: "PC") == "Fill Screen is off on PC. Sunshine streams its main monitor again.",
               "Fill Screen off")
        var offResult = OrbitStreamDisplayResult()
        offResult.changed = true
        var fillUnder = ready()
        fillUnder.fill.enabled = true
        offResult.display = fillUnder
        expect(OrbitStreamDisplayMessages.secondScreenOff(offResult, before: nil, pcName: "PC").contains("back to Fill Screen"), "second screen off with Fill Screen on")
        offResult.display = ready()
        offResult.warning = "Sunshine keeps the display it uses now."
        expect(OrbitStreamDisplayMessages.secondScreenOff(offResult, before: nil, pcName: "PC")
               == "The second screen is off. Sunshine on PC streams the main monitor again. Sunshine keeps the display it uses now.",
               "second screen off, with the PC's caveat")
        expect(OrbitSecondScreenScaleTip.message(device: "this iPhone").contains("Scale to 200%"), "the scale tip names the setting")

        // Reads that belong to one PC.
        var reads = OrbitStatusReads()
        expect(reads.select("A") && !reads.select("A"), "selecting the same PC again changes nothing")
        let first = reads.begin()
        expect(first != nil && reads.isReading && reads.begin() == nil, "one read at a time unless forced")
        let forced = reads.begin(force: true)
        expect(forced != nil, "a forced read starts next to it")
        if let first, let forced {
            reads.applied(forced)
            expect(!reads.isNewest(first) && reads.isCurrent(first), "an older answer never replaces a newer one")
            expect(reads.select("B") && !reads.isReading && !reads.isCurrent(first), "another PC: earlier reads no longer count")
            reads.end(first)
            expect(!reads.isReading, "an earlier PC's read ending changes nothing")
            let next = reads.begin()
            expect(next != nil, "the next PC's first read starts at once")
        }
        expect(OrbitStreamDisplayErrors.isCancellation(URLError(.cancelled)) && OrbitStreamDisplayErrors.isCancellation(CancellationError())
               && !OrbitStreamDisplayErrors.isCancellation(URLError(.timedOut)), "cancelled requests are told apart")

        // Demo data.
        let demo = OrbitStreamDisplayStatus.demo(listing: [phone], fillOn: true)
        expect(demo.fillsScreen(size: phone) && demo.fillsScreen(size: phone, refreshRate: 120), "demo: set up after Set Up This PC")
        expect(!demo.fillsScreen(size: phone, refreshRate: 90) && OrbitStreamDisplayStatus.demo(listing: [phone], rates: [90], fillOn: true).fillsScreen(size: phone, refreshRate: 90),
               "demo: refresh rates")
        expect(OrbitStreamDisplayStatus.demo(listing: [phone, phone]).virtualDisplay.resolutions.filter { $0 == phone.key }.count == 1, "demo: sizes listed once")
        expect(!OrbitStreamDisplayStatus.demo().fillsScreen(size: phone), "demo: not set up at first")
        expect(OrbitStreamDisplayStatus.demo(secondScreenOn: true, position: "left").secondScreen.position == "left", "demo second screen")
        let demoOn = OrbitStreamDisplayStatus.demo(fillOn: true).demoWithSecondScreen(true, position: "left")
        expect(demoOn.secondScreen.active && demoOn.secondScreen.position == "left" && demoOn.config.configurationOption == "ensure_active",
               "demo: the second screen turns on")
        let demoOff = demoOn.demoWithSecondScreen(false)
        expect(!demoOff.secondScreen.active && demoOff.fill.enabled && demoOff.config.configurationOption == "ensure_primary",
               "demo: turning it off goes back to Fill Screen")

        // Errors in plain words.
        let conflict = OrbitStreamDisplayErrors.describe(OrbitError(message: "Someone is streaming from this PC right now.", statusCode: 409))
        expect(conflict.title == "Not possible right now" && conflict.message == "Someone is streaming from this PC right now.", "409 keeps the PC's sentence")
        expect(OrbitStreamDisplayErrors.describe(OrbitError(message: "x", statusCode: 428)).title == "Sunshine login needed", "428")
        expect(OrbitStreamDisplayErrors.describe(OrbitError(message: "x", statusCode: 502)).title == "Sunshine didn't answer", "502")
        expect(OrbitStreamDisplayErrors.describe(OrbitError(message: "x", statusCode: 503)).title == "Windows refused a step", "503")
        let older = OrbitStreamDisplayErrors.describe(OrbitError(message: "Not Found", statusCode: 404))
        expect(older.title == "Update Orbit PC Companion" && older.message.hasSuffix(OrbitStreamDisplayErrors.updateHint), "404")
        #if os(macOS)
        expect(OrbitStreamDisplayErrors.updateHint.contains("Check for Agent Update"), "the Mac names its own update button")
        #endif
        expect(OrbitStreamDisplayAPI.nextStartNote(size: phone, pcName: "Gaming-PC").contains("2556 × 1178")
               && OrbitStreamDisplayAPI.nextStartNote(size: phone, pcName: "Gaming-PC").contains("restart Gaming-PC"),
               "a size the driver offers only after it restarts says so")
        expect(OrbitStreamDisplayErrors.describe(URLError(.timedOut), waitedForChange: true).title == "No answer yet", "slow change timeout")
        expect(OrbitStreamDisplayErrors.describe(URLError(.timedOut)).title == "PC not reachable", "plain timeout")
        let decoding = (try? JSONDecoder().decode(OrbitStreamDisplayResult.self, from: Data("[]".utf8))) == nil
        expect(decoding, "a list is not a result")
        do { _ = try JSONDecoder().decode(OrbitStreamDisplayResult.self, from: Data("[]".utf8)) } catch {
            expect(OrbitStreamDisplayErrors.describe(error).title == "Unexpected reply", "decoding errors")
        }
    }

    // MARK: - Live requests

    static func summary(_ status: OrbitStreamDisplayStatus, size: OrbitDisplaySize?, rate: Int? = nil) -> [String: Any] {
        var out: [String: Any] = [
            "loginSaved": status.loginSaved,
            "driverUsable": status.driverUsable,
            "offersInstallCommand": status.offersInstallCommand,
            "installCommand": status.driverInstallCommand,
            "fillEnabled": status.fill.enabled,
            "onlyDisplay": status.fill.onlyDisplay,
            "fillReady": status.fillReady,
            "sunshineStreamsVirtualDisplay": status.sunshineStreamsVirtualDisplay,
            "secondScreenActive": status.secondScreen.active,
            "secondScreenPosition": status.secondScreen.position as Any,
            "secondScreenPlacement": status.secondScreen.placement as Any,
            "secondScreenBlocker": status.secondScreenBlocker as Any,
            "secondScreenChecks": status.secondScreenChecks.map { "\($0.kind.rawValue)=\(state($0.state))" },
            "appRunning": status.appRunning as Any,
            "streamActive": status.streamActive as Any,
            "savedConfig": status.savedConfig.available,
            "reason": status.reason as Any,
            "pcNote": status.pcNote as Any,
            "sunshineRunning": status.sunshineRunning as Any,
            "sunshineStopped": status.sunshineStopped,
            "loginRejected": status.loginRejected,
            "resolutions": status.virtualDisplay.resolutions,
        ]
        if let size {
            out["lists"] = status.lists(size)
            out["fillsScreen"] = status.fillsScreen(size: size)
            out["shortfall"] = status.fillShortfall(size: size, pcName: "Test-PC") as Any
            out["checks"] = status.fillChecks(size: size).map { "\($0.kind.rawValue)=\(state($0.state))" }
            if let rate {
                out["listsAtRate"] = status.lists(size, refreshRate: rate)
                out["fillsScreenAtRate"] = status.fillsScreen(size: size, refreshRate: rate)
            }
        }
        return out
    }

    static func state(_ value: OrbitDisplayCheck.State) -> String {
        switch value {
        case .done: return "done"
        case .missing: return "missing"
        case .unknown: return "unknown"
        }
    }

    static func emit(json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        print(String(decoding: data, as: UTF8.self))
    }

    static func size(_ width: String, _ height: String) -> OrbitDisplaySize? {
        guard let width = Int(width), let height = Int(height) else { return nil }
        return OrbitDisplaySize(width: width, height: height)
    }

    static func resultJSON(_ result: OrbitStreamDisplayResult, size: OrbitDisplaySize?, rate: Int? = nil) -> [String: Any] {
        var out: [String: Any] = ["changed": result.changed, "restarted": result.restarted, "sunshineReady": result.sunshineReady as Any,
                                  "warning": result.cleanWarning as Any, "reload": result.reload as Any, "elevated": result.elevated as Any,
                                  "placement": result.placement as Any, "placementHint": result.placementHint as Any]
        if let display = result.display { out["display"] = summary(display, size: size, rate: rate) }
        return out
    }

    static func live(port: Int, token: String, fingerprint: String, command: [String]) async {
        do {
            let client = try OrbitAPIClient(host: "127.0.0.1", port: port, token: token, fingerprint: fingerprint)
            // Through the service the screens use (Shared/OrbitStreamDisplay.swift), so its mapping is checked too.
            let pc: any OrbitStreamDisplayService = OrbitStreamDisplayHTTPService(client: client)
            switch command.first {
            case "features":
                let features = try await pc.features()
                emit(json: features.map { ["features": $0.sorted()] } ?? ["olderAgent": true])
            case "status":
                let status = try await pc.status()
                emit(json: summary(status, size: command.count >= 3 ? size(command[1], command[2]) : nil, rate: command.count >= 4 ? Int(command[3]) : nil))
            case "modes":
                guard command.count >= 4, let target = size(command[1], command[2]), let rate = Int(command[3]) else { exit(2) }
                emit(json: resultJSON(try await pc.addMode(size: target, refreshRate: rate), size: target, rate: rate))
            case "fill":
                guard command.count >= 4 else { exit(2) }
                let result = try await pc.setFill(enabled: command[1] != "off", onlyDisplay: command[1] == "only")
                emit(json: resultJSON(result, size: size(command[2], command[3])))
            case "second":
                if command.count >= 6, command[1] == "on", let target = size(command[2], command[3]), let rate = Int(command[4]) {
                    let result = try await pc.setSecondScreen(enabled: true, size: target, refreshRate: rate, position: command[5])
                    emit(json: resultJSON(result, size: target))
                } else if command.count >= 4, command[1] == "off" {
                    let result = try await pc.setSecondScreen(enabled: false, size: nil, refreshRate: 60, position: "right")
                    emit(json: resultJSON(result, size: size(command[2], command[3])))
                } else { exit(2) }
            case "revert":
                guard command.count >= 3 else { exit(2) }
                emit(json: resultJSON(try await pc.revert(), size: size(command[1], command[2])))
            default:
                exit(2)
            }
        } catch {
            let problem = OrbitStreamDisplayErrors.describe(error, waitedForChange: true)
            emit(json: ["error": ["status": (error as? OrbitError)?.statusCode as Any, "title": problem.title, "message": problem.message]])
        }
    }
}
