import SwiftUI
#if canImport(UIKit)
import UIKit
typealias OrbitAppIconImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias OrbitAppIconImage = NSImage
#endif

/// `GET /api/icons?ids=…` (agent 4.4+): base64 PNGs for the opaque `iconID`s of the
/// process list and the audio mixer. `null` means the app has no icon of its own;
/// IDs the agent never listed are left out.
struct OrbitAppIconBatch: Decodable {
    let icons: [String: String?]
}

/// The Windows app icons of one PC. Rows ask for their icon when they appear, and
/// the requests of one moment share a call (at most 48 IDs). Icons stay in memory
/// only, and a different PC or connection starts from scratch.
@MainActor
final class OrbitAppIconStore: ObservableObject {
    typealias Loader = @MainActor ([String]) async throws -> OrbitAppIconBatch

    static let batchLimit = 48
    @Published private(set) var images: [String: OrbitAppIconImage] = [:]
    /// Changes whenever the store points at another PC, so visible rows ask again.
    @Published private(set) var scopeVersion = 0
    private var settled = Set<String>()
    private var queue: [String] = []
    private var queued = Set<String>()
    private var retryAfter: [String: Date] = [:]
    private var unsupported = false
    private var worker: Task<Void, Never>?
    private var scope: String?
    private var loader: Loader?
    private var epoch = 0

    /// Points the store at a PC. A new scope drops everything loaded for the previous one;
    /// rows that asked before any PC was set keep their place in the queue.
    func configure(scope: String, loader: @escaping Loader) {
        if let current = self.scope, current != scope { reset() }
        if self.scope != scope {
            self.scope = scope
            scopeVersion &+= 1
        }
        self.loader = loader
        startWorker()
    }

    func reset() {
        epoch += 1
        worker?.cancel()
        worker = nil
        images = [:]
        settled = []
        queue = []
        queued = []
        retryAfter = [:]
        unsupported = false
        scope = nil
        loader = nil
    }

    func image(for id: String?) -> OrbitAppIconImage? {
        guard let id else { return nil }
        return images[id]
    }

    func request(_ id: String?) {
        guard let id, !unsupported, Self.isValid(id), images[id] == nil,
              !settled.contains(id), !queued.contains(id) else { return }
        if let retry = retryAfter[id], retry > Date() { return }
        queued.insert(id)
        queue.append(id)
        startWorker()
    }

    nonisolated static func isValid(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func startWorker() {
        guard worker == nil, loader != nil, !queue.isEmpty else { return }
        let current = epoch
        worker = Task { [weak self] in
            // Rows that appear together (one screen of a list) share a request.
            try? await Task.sleep(for: .milliseconds(60))
            while !Task.isCancelled {
                guard let self, self.epoch == current, let loader = self.loader, !self.queue.isEmpty else { break }
                let batch = Array(self.queue.prefix(Self.batchLimit))
                self.queue.removeFirst(batch.count)
                do {
                    let reply = try await loader(batch)
                    guard self.epoch == current else { return }
                    self.apply(reply, for: batch)
                } catch {
                    guard self.epoch == current else { return }
                    batch.forEach { self.queued.remove($0) }
                    if (error as? OrbitError)?.statusCode == 404 {
                        // Agents before 4.4 have no icons: stop asking this PC.
                        self.unsupported = true
                        self.queue = []
                        self.queued = []
                    } else {
                        let later = Date().addingTimeInterval(30)
                        batch.forEach { self.retryAfter[$0] = later }
                    }
                }
            }
            guard let self, self.epoch == current else { return }
            self.worker = nil
        }
    }

    private func apply(_ reply: OrbitAppIconBatch, for batch: [String]) {
        var added: [String: OrbitAppIconImage] = [:]
        for id in batch {
            queued.remove(id)
            settled.insert(id)
            guard let encoded = reply.icons[id] ?? nil, encoded.utf8.count <= 1_400_000,
                  let data = Data(base64Encoded: encoded),
                  let image = OrbitAppIconImage(data: data) else { continue }
            added[id] = image
        }
        if !added.isEmpty { images.merge(added) { _, new in new } }
    }
}

/// A Windows app icon on a soft tile, or `fallback` while it loads and for apps without one.
struct OrbitAppIconView<Fallback: View>: View {
    @ObservedObject var store: OrbitAppIconStore
    let iconID: String?
    var size: CGFloat
    /// Muted audio sessions fade their icon, the way a muted symbol turns orange.
    var dimmed = false
    @ViewBuilder var fallback: () -> Fallback

    var body: some View {
        Group {
            if let image = store.image(for: iconID) {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        )
                    Self.picture(image)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .padding(size * 0.13)
                        .saturation(dimmed ? 0.15 : 1)
                        .opacity(dimmed ? 0.6 : 1)
                }
                .frame(width: size, height: size)
                .accessibilityHidden(true)
            } else {
                fallback()
            }
        }
        .task(id: "\(store.scopeVersion):\(iconID ?? "-")") { store.request(iconID) }
    }

    private static func picture(_ image: OrbitAppIconImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }
}

/// The stand-in for an app without a Windows icon, and for one still loading: the name's first
/// letter on the same tile the icons sit on, so it reads as an app and not as an empty box.
struct OrbitIconMonogram: View {
    var name: String
    var size: CGFloat

    var body: some View {
        Text(Self.letter(for: name))
            .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )
            }
            .accessibilityHidden(true)
    }

    /// "chrome.exe" → "C"; a name without a letter or digit gets a dot.
    static func letter(for name: String) -> String {
        let base = name.lowercased().hasSuffix(".exe") ? String(name.dropLast(4)) : name
        return base.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "•"
    }
}

/// How the agent groups audio sessions (agent 4.4+), in the order Windows Task Manager uses.
enum OrbitAudioSessionKind: String, CaseIterable, Identifiable {
    case app, background, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return "Apps"
        case .background: return "Background processes"
        case .system: return "Windows"
        }
    }

    /// Unknown or missing kinds count as background processes.
    init(agentValue: String?) {
        self = agentValue.flatMap(OrbitAudioSessionKind.init(rawValue:)) ?? .background
    }

    /// Splits sessions into Task Manager–style groups, keeping the agent's order inside each.
    /// Agents before 4.4 send no kind: then everything stays in one unnamed group.
    static func groups<Session>(_ sessions: [Session], kind: (Session) -> String?) -> [OrbitAudioSessionGroup<Session>] {
        guard sessions.contains(where: { kind($0) != nil }) else {
            return sessions.isEmpty ? [] : [OrbitAudioSessionGroup(kind: nil, sessions: sessions)]
        }
        return allCases.compactMap { group in
            let members = sessions.filter { OrbitAudioSessionKind(agentValue: kind($0)) == group }
            return members.isEmpty ? nil : OrbitAudioSessionGroup(kind: group, sessions: members)
        }
    }
}

struct OrbitAudioSessionGroup<Session>: Identifiable {
    /// nil: an agent before 4.4, which does not group sessions.
    let kind: OrbitAudioSessionKind?
    let sessions: [Session]
    var id: String { kind?.rawValue ?? "all" }

    /// "Apps (3)", like the group headers in Windows Task Manager.
    var title: String { kind.map { "\($0.title) (\(sessions.count))" } ?? "Applications" }
}
