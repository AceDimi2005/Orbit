import Foundation

// Presentation remote (DESIGN F8): the parts shared by Orbit on iPhone/iPad (the Presentation screen and
// the Shortcuts action) and Orbit for Apple Watch (the Present page and its iPhone relay).
//
// The agent (`orbit_presentation.py`) is the source of truth:
//   GET  /api/presentation                   -> OrbitPresentationState
//   POST /api/presentation/{action}          -> OrbitPresentationActionReply   (body {"slide": N} for goto)
//   GET  /api/presentation/slide.png?slide=N&width=W -> PNG (only while PowerPoint can export it)
// All three need the main token over HTTPS (426 over plain HTTP) and the "presentation" capability.
//
// Foundation only: `Tests/check_presentation.py` compiles this file on its own and feeds it replies made by
// the real agent module, so keep other app types out of it.

// MARK: - Actions

/// `POST /api/presentation/{action}`, spelled like the agent.
enum OrbitPresentationAction: String, CaseIterable, Codable, Sendable {
    case next, previous, first, last, start, startCurrent, end, black, white, goto

    var path: String { "/api/presentation/\(rawValue)" }

    /// Moves between slides (a light haptic and no toast on success).
    var isMove: Bool {
        switch self {
        case .next, .previous, .first, .last, .goto: true
        default: false
        }
    }

    /// Button and VoiceOver label.
    var title: String {
        switch self {
        case .next: "Next slide"
        case .previous: "Previous slide"
        case .first: "First slide"
        case .last: "Last slide"
        case .start: "Start from the beginning"
        case .startCurrent: "Start from the current slide"
        case .end: "End the slide show"
        case .black: "Black screen"
        case .white: "White screen"
        case .goto: "Go to slide"
        }
    }

    var symbol: String {
        switch self {
        case .next: "chevron.forward"
        case .previous: "chevron.backward"
        case .first: "backward.end.fill"
        case .last: "forward.end.fill"
        case .start: "play.fill"
        case .startCurrent: "play.circle"
        case .end: "stop.fill"
        case .black: "rectangle.fill"
        case .white: "rectangle"
        case .goto: "number"
        }
    }

    /// Slide numbers the agent accepts for `goto` (`orbit_presentation.MAX_SLIDE`).
    static let slideRange = 1...10_000
}

/// Optional body of an action. `slide` is required for `goto` and left out otherwise.
struct OrbitPresentationActionBody: Encodable, Equatable, Sendable {
    var slide: Int?

    init(action: OrbitPresentationAction, slide: Int? = nil) {
        self.slide = action == .goto ? slide : nil
    }
}

// MARK: - State

/// `GET /api/presentation`. Every field is decoded on its own with a safe default, so an older or newer
/// agent never breaks the screen, and impossible values (negative slides, a 10 MB note) are clamped.
struct OrbitPresentationState: Codable, Equatable, Sendable {
    enum App: String, Sendable { case powerpoint, none, unknown }
    enum Source: String, Sendable { case show, editor, none, unknown }
    enum ShowState: String, Sendable { case running, paused, black, white, done, none, unknown }
    /// How next/previous are sent right now: PowerPoint's own slide show (COM), key presses to the window
    /// in front, or refused because PowerPoint's editor is in front with no show (keys would edit slides).
    enum Control: String, Sendable { case powerpoint, keys, blocked, unknown }

    static let maxNotes = 20_000
    static let maxTitle = 300

    var app: App = .none
    var running = false
    var source: Source = .none
    var slide = 0
    var slides = 0
    var showState: ShowState = .none
    var notes = ""
    var title = ""
    var slideTitle = ""
    var control: Control = .keys
    var thumbnails = false
    var elapsedSeconds: Int?
    var slideElapsedSeconds: Int?

    private enum CodingKeys: String, CodingKey {
        case app, running, source, slide, slides, notes, title, slideTitle, control, thumbnails, elapsedSeconds, slideElapsedSeconds
        case showState = "state"
    }

    init(app: App = .none, running: Bool = false, source: Source = .none, slide: Int = 0, slides: Int = 0,
         showState: ShowState = .none, notes: String = "", title: String = "", slideTitle: String = "",
         control: Control = .keys, thumbnails: Bool = false, elapsedSeconds: Int? = nil, slideElapsedSeconds: Int? = nil) {
        self.app = app
        self.running = running
        self.source = source
        self.slide = slide
        self.slides = slides
        self.showState = showState
        self.notes = notes
        self.title = title
        self.slideTitle = slideTitle
        self.control = control
        self.thumbnails = thumbnails
        self.elapsedSeconds = elapsedSeconds
        self.slideElapsedSeconds = slideElapsedSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys, limit: Int) -> String {
            let decoded: String? = try? c.decodeIfPresent(String.self, forKey: key)
            let value = decoded ?? ""
            let clean = String(value.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) })
            return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
        }
        func count(_ key: CodingKeys) -> Int {
            guard let value = Self.integer(c, key) else { return 0 }
            return min(max(value, 0), OrbitPresentationAction.slideRange.upperBound)
        }
        func seconds(_ key: CodingKeys) -> Int? {
            guard let value = Self.integer(c, key), value >= 0 else { return nil }
            return min(value, 7 * 24 * 3600)
        }
        func raw(_ key: CodingKeys) -> String {
            let value: String? = try? c.decodeIfPresent(String.self, forKey: key)
            return value ?? ""
        }

        app = App(rawValue: raw(.app)) ?? (raw(.app).isEmpty ? .none : .unknown)
        let running: Bool? = try? c.decodeIfPresent(Bool.self, forKey: .running)
        self.running = running ?? false
        let sourceText = raw(.source)
        source = Source(rawValue: sourceText) ?? (sourceText.isEmpty ? (self.running ? .show : .none) : .unknown)
        slides = count(.slides)
        slide = min(count(.slide), slides)
        let stateText = raw(.showState)
        showState = ShowState(rawValue: stateText) ?? (stateText.isEmpty ? (self.running ? .running : .none) : .unknown)
        notes = text(.notes, limit: Self.maxNotes).trimmingCharacters(in: .whitespacesAndNewlines)
        title = text(.title, limit: Self.maxTitle).replacingOccurrences(of: "\n", with: " ")
        slideTitle = text(.slideTitle, limit: Self.maxTitle).replacingOccurrences(of: "\n", with: " ")
        let controlText = raw(.control)
        control = Control(rawValue: controlText) ?? (controlText.isEmpty ? (self.running ? .powerpoint : .keys) : .unknown)
        let thumbnails: Bool? = try? c.decodeIfPresent(Bool.self, forKey: .thumbnails)
        self.thumbnails = thumbnails ?? false
        elapsedSeconds = seconds(.elapsedSeconds)
        slideElapsedSeconds = seconds(.slideElapsedSeconds)
    }

    /// Whole numbers only; JSON numbers such as 3.0 count, 3.5 or "3" do not.
    private static func integer(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        let whole: Int? = try? c.decodeIfPresent(Int.self, forKey: key)
        if let whole { return whole }
        let number: Double? = try? c.decodeIfPresent(Double.self, forKey: key)
        if let number, number.isFinite, number.rounded() == number, abs(number) < 1e9 { return Int(number) }
        return nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(app.rawValue, forKey: .app)
        try c.encode(running, forKey: .running)
        try c.encode(source.rawValue, forKey: .source)
        try c.encode(slide, forKey: .slide)
        try c.encode(slides, forKey: .slides)
        try c.encode(showState.rawValue, forKey: .showState)
        try c.encode(notes, forKey: .notes)
        try c.encode(title, forKey: .title)
        try c.encode(slideTitle, forKey: .slideTitle)
        try c.encode(control.rawValue, forKey: .control)
        try c.encode(thumbnails, forKey: .thumbnails)
        try c.encodeIfPresent(elapsedSeconds, forKey: .elapsedSeconds)
        try c.encodeIfPresent(slideElapsedSeconds, forKey: .slideElapsedSeconds)
    }

    /// A PowerPoint slide show runs and shows a slide: slide x/y, notes and the thumbnail are what the
    /// audience sees. (At the end-of-show screen `running` stays true but no slide is shown.)
    var isShowingSlide: Bool { running && showState != .done && slides > 0 && slide >= 1 }

    /// "4 / 12" while a slide is shown.
    var positionText: String? { isShowingSlide ? "\(slide) / \(slides)" : nil }

    /// Spoken form for VoiceOver and Siri.
    var spokenPosition: String? { isShowingSlide ? "Slide \(slide) of \(slides)" : nil }

    /// The thumbnail endpoint can draw the slide that's on screen now (not at a black, white or end screen).
    var canShowThumbnail: Bool { isShowingSlide && thumbnails && (showState == .running || showState == .paused) }

    /// Next/previous would be refused (409) until the show runs or is in front.
    var isBlocked: Bool { !running && control == .blocked }

    /// A deck waits in PowerPoint's editor (no show yet).
    var isReadyInEditor: Bool { !running && source == .editor && slides > 0 }

    /// The same state for the Watch: without the speaker notes, which it never shows.
    var forWatch: OrbitPresentationState {
        var copy = self
        copy.notes = ""
        return copy
    }

    /// Short status line ("Slide show running", "Ready in PowerPoint"…).
    var statusTitle: String {
        if running {
            switch showState {
            case .paused: return "Slide show paused"
            case .black: return "Screen is black"
            case .white: return "Screen is white"
            case .done: return "End of slide show"
            default: return "Slide show running"
            }
        }
        if isReadyInEditor { return "Ready in PowerPoint" }
        // PowerPoint is in front (a dialog, or a deck the PC can't read yet): Start works, Next waits.
        if control == .blocked { return "PowerPoint in front" }
        switch control {
        case .keys, .unknown, .blocked: return app == .powerpoint ? "No slide show yet" : "Ready to press keys"
        case .powerpoint: return "Slide show running"
        }
    }

    /// What controls the slides, in plain words: a short title and one or two sentences.
    var controlExplanation: (title: String, detail: String) {
        switch control {
        case .powerpoint:
            return ("Controlling PowerPoint",
                    "Orbit drives the PowerPoint slide show directly, so it works even when another window is in front on the PC.")
        case .blocked:
            return ("Start the slide show first",
                    "PowerPoint's editor is in front on the PC, so Orbit starts the slide show from here instead of pressing keys, which would type into your slides. Next and Previous work once the show runs.")
        case .keys, .unknown:
            return ("Pressing keys on the PC",
                    "Orbit presses the arrow keys, F5 and Esc on the PC. They go to the window in front, so click into your slides once (Google Slides, a PDF, Keynote in a browser).")
        }
    }
}

/// `POST /api/presentation/{action}` → 200.
struct OrbitPresentationActionReply: Decodable, Equatable, Sendable {
    var status = "done"
    var action = ""
    /// "powerpoint" or "keys".
    var via = ""
    /// Keys pressed, such as ["Right"]; empty on the PowerPoint path.
    var keys: [String] = []
    var detail = ""
    /// The state right after the action; nil when the PC couldn't read it back in time.
    var presentation: OrbitPresentationState?

    private enum CodingKeys: String, CodingKey { case status, action, via, keys, detail, presentation }

    init(status: String = "done", action: String, via: String, keys: [String] = [], detail: String, presentation: OrbitPresentationState?) {
        self.status = status
        self.action = action
        self.via = via
        self.keys = keys
        self.detail = detail
        self.presentation = presentation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            let value: String? = try? c.decodeIfPresent(String.self, forKey: key)
            return value ?? ""
        }
        let status = text(.status)
        self.status = status.isEmpty ? "done" : status
        action = text(.action)
        via = text(.via)
        let keys: [String]? = try? c.decodeIfPresent([String].self, forKey: .keys)
        self.keys = (keys ?? []).prefix(16).map { String($0.prefix(40)) }
        detail = String(text(.detail).trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        let presentation: OrbitPresentationState? = try? c.decodeIfPresent(OrbitPresentationState.self, forKey: .presentation)
        self.presentation = presentation
    }

    var usedKeys: Bool { via == "keys" }
}

// MARK: - Elapsed timer

/// The talk timer. While PowerPoint runs the show it follows the PC (`elapsedSeconds`), so every device
/// shows the same time; with key presses (Google Slides, a PDF) the PC can't tell, so it starts when Orbit
/// sends Start (or the first slide change) and stops when Orbit sends End. It can also be reset by hand.
/// Codable so the Watch can keep a talk's timer when watchOS ends Orbit in the background.
struct OrbitPresentationTimer: Codable, Equatable, Sendable {
    private(set) var startedAt: Date?
    private(set) var stoppedAt: Date?
    /// Anchored to the PC's own show time.
    private(set) var followsPC = false

    /// A drift smaller than this keeps the current anchor, so the display doesn't jitter by a second.
    static let resyncTolerance: TimeInterval = 2

    var isRunning: Bool { startedAt != nil && stoppedAt == nil }

    func elapsed(at now: Date) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (stoppedAt ?? now).timeIntervalSince(startedAt))
    }

    /// Applies a state read from the PC (or from demo mode).
    mutating func sync(with state: OrbitPresentationState, now: Date) {
        if state.running, let elapsed = state.elapsedSeconds {
            let anchor = now.addingTimeInterval(-TimeInterval(elapsed))
            if startedAt == nil || stoppedAt != nil || !followsPC || abs(startedAt!.timeIntervalSince(anchor)) > Self.resyncTolerance {
                startedAt = anchor
            }
            stoppedAt = nil
            followsPC = true
        } else if followsPC, !state.running, isRunning {
            stoppedAt = now // PowerPoint's show ended: keep the final time on screen.
        }
    }

    /// Orbit sent an action that the PC carried out.
    mutating func note(_ action: OrbitPresentationAction, via: String, now: Date) {
        guard via == "keys" || !followsPC else { return }
        switch action {
        case .start, .startCurrent:
            if !isRunning || action == .start { start(now: now) }
        case .end:
            if isRunning { stoppedAt = now }
        case .next, .previous, .first, .last, .goto:
            if startedAt == nil { start(now: now) }
        case .black, .white:
            break
        }
    }

    mutating func start(now: Date) {
        startedAt = now
        stoppedAt = nil
        followsPC = false
    }

    mutating func reset() {
        startedAt = nil
        stoppedAt = nil
        followsPC = false
    }
}

// MARK: - Talk reminders

/// When the Watch's tap reminders are due: reminder n comes n × `minutes` after the talk started.
enum OrbitPresentationReminderPlan {
    /// The reminders still to come after `now`, as (n, seconds from now), at most `limit` of them and none
    /// further ahead than `horizon`. A reminder due exactly now counts as already delivered.
    static func upcoming(startedAt: Date, now: Date, minutes: Int, limit: Int,
                         horizon: TimeInterval) -> [(number: Int, delay: TimeInterval)] {
        guard minutes > 0, limit > 0 else { return [] }
        let interval = TimeInterval(minutes * 60)
        let next = Int(max(0, now.timeIntervalSince(startedAt)) / interval) + 1
        var plan: [(number: Int, delay: TimeInterval)] = []
        for number in next..<(next + limit) {
            let delay = startedAt.addingTimeInterval(TimeInterval(number) * interval).timeIntervalSince(now)
            guard delay <= horizon else { break }
            plan.append((number, delay))
        }
        return plan
    }
}

// MARK: - Words

enum OrbitPresentationText {
    /// "0:07", "12:34", "1:02:03".
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.isFinite ? interval : 0))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// "12 minutes 5 seconds" for VoiceOver.
    static func spokenDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.isFinite ? interval : 0))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if minutes > 0 { parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes") }
        if seconds > 0 || parts.isEmpty { parts.append(seconds == 1 ? "1 second" : "\(seconds) seconds") }
        return parts.joined(separator: " ")
    }

    static let olderAgent = "Presentation remote needs a newer Orbit agent on the PC. Update it from Settings → PC Companion, then try again."
    static let needsEncryption = "Presentation remote works over Orbit's encrypted connection. Pair the PC again with Find my PC to turn it on."
    static let windowsOnly = "Presentation remote needs Orbit running on a Windows PC."
    static let accessRevoked = "The PC didn't accept Orbit's access key. Pair the PC again in My PCs."

    /// One sentence for a reply outside 200–299. `detail` is the agent's FastAPI `detail`: a sentence for
    /// people (409, 422, 503…), FastAPI's bare "Not Found" for a route an older agent doesn't have, or
    /// nil (validation errors arrive as a list).
    static func failure(status: Int, detail: String?) -> String {
        let sentence = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usable = !sentence.isEmpty && sentence != "Not Found" && sentence != "Method Not Allowed"
        switch status {
        case 401, 403: return accessRevoked
        case 404 where !usable, 405: return olderAgent
        case 426: return needsEncryption
        case 501: return windowsOnly
        case 422 where !usable: return "The PC refused that slide number. Choose a slide from the presentation."
        default:
            if usable { return ".!?…".contains(sentence.last!) ? sentence : sentence + "." }
            return "The PC couldn't do that (error \(status)). Try again."
        }
    }

    /// What the Shortcuts action says after the PC carried it out.
    static func intentSentence(_ reply: OrbitPresentationActionReply?, action: OrbitPresentationAction, pc: String) -> String {
        guard let reply else { return "Sent “\(action.title)” to \(pc)." }
        var sentence = reply.detail.isEmpty ? "Sent “\(action.title)” to \(pc)." : reply.detail
        if let last = sentence.last, !".!?…".contains(last) { sentence += "." }
        if !reply.usedKeys, let position = reply.presentation?.spokenPosition {
            sentence += " \(position)."
        }
        return sentence
    }
}

// MARK: - Demo mode

/// A pretend PowerPoint deck for demo mode. It answers actions the way the agent's PowerPoint path does,
/// so the screen and the Watch page can be tried without a PC.
struct OrbitPresentationDemo: Sendable {
    static let deckTitle = "Orbit Demo Deck"
    static let slideTitles = ["Welcome", "Agenda", "Where we are", "The numbers", "Customers", "Roadmap",
                              "Risks", "The team", "Budget", "Timeline", "Questions", "Thank you"]

    struct Refusal: Error, Equatable, Sendable { let message: String }

    private(set) var running = false
    private(set) var slide = 1
    private(set) var showState: OrbitPresentationState.ShowState = .running
    private(set) var startedAt: Date?
    private(set) var slideStartedAt: Date?
    /// The slide "selected in the editor" that Start from current slide uses.
    var editorSlide = 1

    var slides: Int { Self.slideTitles.count }

    static func notes(for slide: Int) -> String {
        switch slide {
        case 1: return "Thank everyone for coming.\nIntroduce yourself and what the talk covers in one sentence."
        case 4: return "Pause after the main number. Let it land.\nMention the comparison with last quarter."
        case 8: return ""
        case 11: return "Repeat each question before answering, so everyone hears it."
        default: return "Key point for “\(slideTitles[max(0, min(slideTitles.count - 1, slide - 1))])”.\nKeep it under two minutes."
        }
    }

    func state(at now: Date) -> OrbitPresentationState {
        guard running else {
            // What the PC reports with the deck open in PowerPoint's editor, in front: Start works, Next waits.
            return OrbitPresentationState(app: .powerpoint, running: false, source: .editor, slide: editorSlide, slides: slides,
                                          showState: .none, notes: Self.notes(for: editorSlide), title: Self.deckTitle,
                                          slideTitle: Self.slideTitles[editorSlide - 1], control: .blocked, thumbnails: true)
        }
        let done = showState == .done
        return OrbitPresentationState(
            app: .powerpoint, running: true, source: .show, slide: slide, slides: slides, showState: showState,
            notes: done ? "" : Self.notes(for: slide), title: Self.deckTitle,
            slideTitle: done ? "" : Self.slideTitles[slide - 1], control: .powerpoint, thumbnails: true,
            elapsedSeconds: startedAt.map { max(0, Int(now.timeIntervalSince($0))) },
            slideElapsedSeconds: done ? nil : slideStartedAt.map { max(0, Int(now.timeIntervalSince($0))) })
    }

    mutating func perform(_ action: OrbitPresentationAction, slide target: Int? = nil, now: Date) throws -> OrbitPresentationActionReply {
        let detail: String
        if !running {
            switch action {
            case .start, .startCurrent:
                running = true
                showState = .running
                startedAt = now
                move(to: action == .start ? 1 : editorSlide, now: now)
                detail = action == .start || editorSlide == 1 ? "Started the slide show." : "Started the slide show from slide \(editorSlide)."
            default:
                throw Refusal(message: "No PowerPoint slide show is running. Start the slide show first.")
            }
        } else {
            if action == .goto {
                guard let target, (1...slides).contains(target) else {
                    throw Refusal(message: "This presentation has \(slides) slides. Choose a slide from 1 to \(slides).")
                }
            }
            if action.isMove, showState == .black || showState == .white { showState = .running }
            switch action {
            case .next:
                if showState == .done {
                    running = false
                    detail = "Ended the slide show."
                } else if slide >= slides {
                    showState = .done
                    detail = "Went to the next slide."
                } else {
                    move(to: slide + 1, now: now)
                    detail = "Went to the next slide."
                }
            case .previous:
                if showState == .done { showState = .running; move(to: slides, now: now) } else { move(to: max(1, slide - 1), now: now) }
                detail = "Went back one slide."
            case .first, .start:
                showState = .running
                move(to: 1, now: now)
                detail = "Went to the first slide."
            case .last:
                showState = .running
                move(to: slides, now: now)
                detail = "Went to the last slide."
            case .goto:
                showState = .running
                move(to: target ?? slide, now: now)
                detail = "Went to slide \(slide)."
            case .startCurrent:
                detail = "The slide show is already running."
            case .end:
                running = false
                detail = "Ended the slide show."
            case .black, .white:
                let wanted: OrbitPresentationState.ShowState = action == .black ? .black : .white
                if showState == wanted {
                    showState = .running
                    detail = "Showing the slide again."
                } else {
                    showState = wanted
                    detail = "The screen is \(action.rawValue). Press \(action == .black ? "Black" : "White") again to show the slide."
                }
            }
        }
        return OrbitPresentationActionReply(action: action.rawValue, via: "powerpoint", detail: detail, presentation: state(at: now))
    }

    private mutating func move(to index: Int, now: Date) {
        if index != slide || slideStartedAt == nil { slideStartedAt = now }
        slide = index
    }
}
