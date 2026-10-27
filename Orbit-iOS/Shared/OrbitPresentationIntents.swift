import AppIntents
import Foundation

// "Control Slide Show" for Shortcuts and Siri (DESIGN F8, free). It drives the slide show on the PC the
// same way Orbit's Presentation screen does: PowerPoint directly while its show runs, otherwise key
// presses in the window in front.
//
// Compiled into Orbit only, like OrbitPCIntents.swift: its App Shortcut ("Next slide with Orbit") must run
// in the app's process, never in the widget extension (see the note in OrbitPCIntents.swift).

/// The slide show actions Shortcuts offers (all of `POST /api/presentation/{action}` except Go to Slide).
enum OrbitPresentationIntentAction: String, AppEnum, CaseIterable {
    case next, previous, first, last, start, startCurrent, end, black, white

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Slide Show Action")
    static let caseDisplayRepresentations: [OrbitPresentationIntentAction: DisplayRepresentation] = [
        .next: DisplayRepresentation(title: "Next slide", synonyms: ["next", "forward", "advance", "next page"]),
        .previous: DisplayRepresentation(title: "Previous slide", synonyms: ["previous", "back", "go back", "previous page"]),
        .first: DisplayRepresentation(title: "First slide", synonyms: ["beginning", "go to the first slide"]),
        .last: DisplayRepresentation(title: "Last slide", synonyms: ["final slide", "go to the last slide"]),
        .start: DisplayRepresentation(title: "Start slide show", subtitle: "From the beginning", synonyms: ["start presentation", "begin slide show", "present"]),
        .startCurrent: DisplayRepresentation(title: "Start from current slide", synonyms: ["resume slide show", "present from here"]),
        .end: DisplayRepresentation(title: "End slide show", synonyms: ["stop slide show", "end presentation", "stop presenting"]),
        .black: DisplayRepresentation(title: "Black screen", subtitle: "Press again to show the slide", synonyms: ["blank screen", "black out"]),
        .white: DisplayRepresentation(title: "White screen", subtitle: "Press again to show the slide", synonyms: ["white out"])
    ]

    var agentAction: OrbitPresentationAction {
        switch self {
        case .next: .next
        case .previous: .previous
        case .first: .first
        case .last: .last
        case .start: .start
        case .startCurrent: .startCurrent
        case .end: .end
        case .black: .black
        case .white: .white
        }
    }
}

enum OrbitPresentationIntentRunner {
    /// Checks the PC's `presentation` capability first (an older agent gets "needs a newer Orbit Companion"
    /// and nothing is sent), then sends the action once; it is never repeated.
    static func perform(_ action: OrbitPresentationIntentAction, pc: OrbitPCEntity?) async throws -> String {
        // A busy PowerPoint can take about 8.5 s before the PC answers an action.
        let client = try OrbitIntentClient.resolve(pc, timeout: 10)
        try await client.require(feature: "presentation")
        let agentAction = action.agentAction
        let data: Data
        do {
            data = try await client.data("POST", agentAction.path)
        } catch let error as OrbitIntentError where error.kind == .unreachable {
            // The PC answered the capability check a moment ago, so the action may have reached it.
            throw OrbitIntentError("\(client.pcName) didn't answer in time, so the slide may or may not have changed. Check it before trying again.", kind: .unreachable)
        }
        let reply = try? JSONDecoder().decode(OrbitPresentationActionReply.self, from: data)
        return OrbitPresentationText.intentSentence(reply, action: agentAction, pc: client.pcName)
    }
}

struct PresentationControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Control Slide Show"
    static let description = IntentDescription(
        "Moves to the next or previous slide, starts or ends the slide show, or blanks the screen on your PC. PowerPoint is controlled directly while its slide show runs; other presenters (Google Slides, a PDF) get key presses in the window in front.",
        categoryName: "Presentation")
    static let openAppWhenRun = false
    // Stays runnable from a locked iPhone (the default policy), like Control PC Media: a presenter says
    // "Next slide with Orbit" with the phone in a pocket, and the only input is a slide key.

    @Parameter(title: "Action", default: .next)
    var action: OrbitPresentationIntentAction

    @Parameter(title: "PC", description: "Leave empty to use your default PC.")
    var pc: OrbitPCEntity?

    static var parameterSummary: some ParameterSummary { Summary("\(\.$action) on \(\.$pc)") }

    init() {}
    init(action: OrbitPresentationIntentAction, pc: OrbitPCEntity? = nil) {
        self.action = action
        self.pc = pc
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await OrbitPresentationIntentRunner.perform(action, pc: pc)))
    }
}
