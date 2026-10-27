#if DEBUG && os(iOS)
import SwiftUI
import UIKit

/// DEBUG only: the stream surface with the software keyboard and its key bar up, but no stream, listing what
/// the PC would receive. The iPhone app opens it when launched with `ORBIT_KEYBAR_PREVIEW` set, for screenshots
/// and trying the keys without a PC.
///
/// A value other than `1` is a comma-separated script run once the keyboard is up, through the keycaps' own
/// actions: `win`, `ctrl`, `alt`, `shift` tap a modifier (the same one twice in a row locks it), `key:<title>`
/// presses a key (`key:tab`, `key:f5`), `shortcut:<name>` (`shortcut:taskManager`), `type:<text>` types on the
/// software keyboard and `scroll:<title or name>` scrolls the row to that key.
public struct MoonlightKeyBarPreview: View {
    @StateObject private var log = MoonlightKeyBarPreviewLog()
    private let script: String

    public init(script: String = ProcessInfo.processInfo.environment["ORBIT_KEYBAR_PREVIEW"] ?? "") {
        self.script = script
    }

    public var body: some View {
        ZStack(alignment: .top) {
            MoonlightKeyBarPreviewSurface(log: log, script: script)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 6) {
                Text("Key bar preview · no stream")
                    .font(.headline)
                Text(log.lines.isEmpty ? "Keys you press show up here as the PC would get them." : "Sent to the PC, newest last:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(log.lines.suffix(6)) { line in
                    Text(line.text)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(14)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(16)
            .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
    }
}

@MainActor
private final class MoonlightKeyBarPreviewLog: ObservableObject {
    struct Line: Identifiable {
        let id: Int
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    private var pending: [String] = []
    private var nextID = 0

    /// Everything one tap sends arrives in the same turn of the run loop and becomes one line ("C↓ C↑ Ctrl↑").
    func record(_ output: MoonlightKeyOutput) {
        switch output {
        case let .key(key, pressed, _): pending.append(MoonlightVirtualKey.name(of: key) + (pressed ? "↓" : "↑"))
        case let .text(text): pending.append("text “\(text)”")
        }
        guard pending.count == 1 else { return }
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        lines.append(Line(id: nextID, text: pending.joined(separator: " ")))
        nextID += 1
        pending = []
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
    }
}

private struct MoonlightKeyBarPreviewSurface: UIViewRepresentable {
    let log: MoonlightKeyBarPreviewLog
    let script: String

    @MainActor
    final class Coordinator {
        let handle = MoonlightSurfaceHandle()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MoonlightStreamSurfaceView {
        let view = MoonlightStreamSurfaceView(frame: .zero)
        view.handle = context.coordinator.handle
        context.coordinator.handle.view = view
        // Never started: the library drops input while no connection is up.
        view.session = MoonlightStreamSession()
        view.keyOutputObserver = { [weak log] output in log?.record(output) }
        let steps = script == "1" ? [] : script.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task { @MainActor [weak view] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            view?.setSoftwareKeyboard(visible: true)
            // Give the keyboard time to come up, then one step every 50 ms: two taps of the same modifier land
            // inside the double-tap window and lock it.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for step in steps {
                guard let view else { return }
                Self.perform(step, on: view)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return view
    }

    func updateUIView(_ view: MoonlightStreamSurfaceView, context: Context) {}

    @MainActor
    private static func perform(_ step: String, on view: MoonlightStreamSurfaceView) {
        guard let bar = view.keyBarView else { return }
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0].lowercased() {
        case "win": bar.cap(for: .modifier(.windows))?.sendActions(for: .touchUpInside)
        case "ctrl": bar.cap(for: .modifier(.control))?.sendActions(for: .touchUpInside)
        case "alt": bar.cap(for: .modifier(.alt))?.sendActions(for: .touchUpInside)
        case "shift": bar.cap(for: .modifier(.shift))?.sendActions(for: .touchUpInside)
        case "type": view.insertText(argument)
        case "key":
            guard let item = item(named: argument), let cap = bar.cap(for: item) else { return }
            cap.sendActions(for: .touchDown)
            cap.sendActions(for: .touchUpInside)
        case "shortcut":
            guard let item = item(named: argument), let cap = bar.cap(for: item) else { return }
            cap.sendActions(for: .touchUpInside)
        case "scroll":
            if let item = item(named: argument) { bar.scrollToShow(item, animated: false) }
        default: break
        }
    }

    /// A key by its title ("Tab", "F5", "PgUp") or a shortcut by its name ("taskManager"), ignoring case.
    private static func item(named name: String) -> MoonlightKeyBarItem? {
        MoonlightKeyBarLayout.groups.joined().first { item in
            switch item {
            case .key(let key): return key.title.caseInsensitiveCompare(name) == .orderedSame
            case .shortcut(let shortcut): return shortcut.rawValue.caseInsensitiveCompare(name) == .orderedSame
            case .modifier(let modifier): return modifier.title.caseInsensitiveCompare(name) == .orderedSame
            }
        }
    }
}
#endif
