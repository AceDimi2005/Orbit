import Foundation
import UniformTypeIdentifiers

// Reads what the user shared (NSExtensionContext input items) into links, text or local files.
//
// Files are never read into memory: `loadFileRepresentation` hands over a temporary file, which is
// cloned into the extension's own temporary folder and later streamed to the PC. That keeps the
// extension far below its ~120 MB memory limit even for long videos.
// Foundation + UniformTypeIdentifiers only, so `Tests/check_share_extension.py` can run it on macOS.

/// A file ready to upload: a local copy plus its Windows-safe name.
struct SharedFile: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case image, movie, audio, pdf, document }

    let id: UUID
    let url: URL
    let name: String
    let size: Int64
    let kind: Kind
    let typeIdentifier: String
}

struct SharedLink: Hashable, Sendable {
    let url: URL
    let title: String?
}

/// What the share sheet sends. Files win over links, links over text.
enum SharedContent: Sendable {
    case link(SharedLink)
    case text(String)
    case files([SharedFile])
}

struct SharedItems: Sendable {
    let content: SharedContent
    /// Folders and items that could not be read, already explained in plain words.
    let skippedNote: String?
    /// For `.text` content: excerpt and counts, worked out once while loading (off the main thread).
    let textSummary: SharedTextSummary?

    init(content: SharedContent, skippedNote: String?) {
        self.content = content
        self.skippedNote = skippedNote
        if case .text(let text) = content { textSummary = SharedTextSummary(text) } else { textSummary = nil }
    }
}

/// What the sheet shows of shared text. Shared text can be up to 4 MB, so this is computed once,
/// in a single pass, instead of on every redraw.
struct SharedTextSummary: Equatable, Sendable {
    static let excerptLength = 700

    let excerpt: String
    let words: Int
    let characters: Int

    init(_ text: String, excerptLength: Int = SharedTextSummary.excerptLength) {
        var characters = 0
        var words = 0
        var inWord = false
        for character in text {
            characters += 1
            if character.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        self.characters = characters
        self.words = words
        // The excerpt skips leading and trailing blank space; "…" marks text that goes on.
        let start = text.firstIndex { !$0.isWhitespace } ?? text.endIndex
        let rest = text[start...]
        let head = rest.prefix(max(0, excerptLength))
        let continues = rest[head.endIndex...].contains { !$0.isWhitespace }
        var excerpt = String(head)
        while let last = excerpt.last, last.isWhitespace { excerpt.removeLast() }
        self.excerpt = continues ? excerpt + "…" : excerpt
    }
}

/// How far loading the shared items got: item `index` (0-based) of `count`, and that item's own
/// progress (Photos exports and iCloud downloads report it; quick items jump from 0 to done).
struct SharedLoadProgress: Equatable, Sendable {
    let index: Int
    let count: Int
    let itemFraction: Double

    var overallFraction: Double {
        guard count > 0 else { return 0 }
        return min(1, (Double(index) + min(1, max(0, itemFraction))) / Double(count))
    }
}

enum ShareItemLoaderError: LocalizedError {
    case nothingUsable(skipped: Int)

    var errorDescription: String? {
        switch self {
        case .nothingUsable(let skipped) where skipped > 0:
            "Orbit couldn't read what you shared. Folders can't be sent; share the files inside instead."
        case .nothingUsable:
            "Orbit can send links, text, photos, videos and files. Nothing like that was shared."
        }
    }
}

final class ShareItemLoader: @unchecked Sendable {
    /// Private temporary folder for this share; removed by `cleanUp()`.
    let folder: URL
    private static let folderPrefix = "OrbitShare-"

    init(base: URL = FileManager.default.temporaryDirectory) {
        folder = base.appendingPathComponent(Self.folderPrefix + UUID().uuidString, isDirectory: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Deletes folders an earlier share left behind (the extension was killed before cleaning up).
    static func removeStaleFolders(in base: URL = FileManager.default.temporaryDirectory, olderThan age: TimeInterval = 6 * 60 * 60) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries where entry.lastPathComponent.hasPrefix(folderPrefix) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? manager.removeItem(at: entry) }
        }
    }

    // MARK: Loading

    /// `progress` is called from background queues while the items are read.
    func load(_ items: [NSExtensionItem], progress: (@Sendable (SharedLoadProgress) -> Void)? = nil) async throws -> SharedItems {
        let providers = items.flatMap { $0.attachments ?? [] }
        let titles = items.compactMap { item -> String? in
            let text = (item.attributedTitle?.string ?? item.attributedContentText?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return try await load(providers: providers, titles: titles, progress: progress)
    }

    private enum Piece {
        case file(SharedFile)
        case link(URL)
        case text(String)
        case skipped
    }

    func load(providers: [NSItemProvider], titles: [String] = [],
              progress: (@Sendable (SharedLoadProgress) -> Void)? = nil) async throws -> SharedItems {
        var files: [SharedFile] = []
        var links: [URL] = []
        var texts: [String] = []
        var skipped = 0
        // One at a time: Photos exports each item on demand, and parallel exports of large
        // videos would only compete for the same disk and memory.
        for (index, provider) in providers.enumerated() {
            try Task.checkCancellation()
            let count = providers.count
            progress?(SharedLoadProgress(index: index, count: count, itemFraction: 0))
            let report: (@Sendable (Double) -> Void)? = progress.map { progress in
                { @Sendable fraction in progress(SharedLoadProgress(index: index, count: count, itemFraction: fraction)) }
            }
            switch await piece(from: provider, index: index, report: report) {
            case .file(let file): files.append(file)
            case .link(let url): links.append(url)
            case .text(let text): texts.append(text)
            case .skipped: skipped += 1
            }
        }
        let note: String? = skipped == 0 ? nil
            : (skipped == 1 ? "1 item was skipped because it couldn't be read or is a folder."
                            : "\(skipped) items were skipped because they couldn't be read or are folders.")
        if !files.isEmpty {
            return SharedItems(content: .files(files), skippedNote: note)
        }
        if let url = links.first {
            let title = (titles + texts).first { candidate in
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && trimmed != url.absoluteString && URL(string: trimmed) != url
            }
            return SharedItems(content: .link(SharedLink(url: url, title: title.map { String($0.prefix(300)) })), skippedNote: note)
        }
        let joined = texts.joined(separator: "\n\n")
        if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let url = Self.singleWebLink(in: joined) {
                return SharedItems(content: .link(SharedLink(url: url, title: nil)), skippedNote: note)
            }
            return SharedItems(content: .text(joined), skippedNote: note)
        }
        throw ShareItemLoaderError.nothingUsable(skipped: skipped)
    }

    /// Text that is nothing but one http(s) link (as many apps share links) becomes a link.
    static func singleWebLink(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096, !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", !(url.host ?? "").isEmpty else { return nil }
        return url
    }

    private func piece(from provider: NSItemProvider, index: Int, report: (@Sendable (Double) -> Void)?) async -> Piece {
        let identifiers = provider.registeredTypeIdentifiers
        let types = identifiers.compactMap { UTType($0) }
        let hasFileURL = identifiers.contains(UTType.fileURL.identifier)
        let isMedia = types.contains { $0.conforms(to: .image) || $0.conforms(to: .audiovisualContent) }
        do {
            if hasFileURL || isMedia {
                return try await fileOrSkip(provider, index: index, report: report)
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = try await loadURL(provider) {
                    if url.isFileURL { return try await fileOrSkip(provider, index: index, fileURL: url, report: report) }
                    if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", !(url.host ?? "").isEmpty {
                        return .link(url)
                    }
                    // mailto:, tel:, maps links… can still be copied to the PC clipboard.
                    return .text(url.absoluteString)
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = try await loadText(provider) {
                return .text(text)
            }
            if Self.preferredFileType(identifiers) != nil {
                return try await fileOrSkip(provider, index: index, report: report)
            }
        } catch {
            return .skipped
        }
        return .skipped
    }

    private func fileOrSkip(_ provider: NSItemProvider, index: Int, fileURL: URL? = nil,
                            report: (@Sendable (Double) -> Void)?) async throws -> Piece {
        if let file = try await loadFile(provider, index: index, knownURL: fileURL, report: report) { return .file(file) }
        return .skipped
    }

    // MARK: Type choice

    /// The representation to save for a file-like provider: the original movie, the image
    /// (JPEG when Photos also offers it, since every Windows PC opens JPEG), otherwise the first
    /// real data type. Folders, packages and link types are never chosen.
    static func preferredFileType(_ identifiers: [String]) -> String? {
        let candidates = identifiers.filter { identifier in
            guard let type = UTType(identifier) else { return false }
            if type.conforms(to: .url) || type == .fileURL { return false }
            if type.conforms(to: .directory) || type.conforms(to: .package) { return false }
            if identifier.hasPrefix("com.apple.private.") { return false }
            return type.conforms(to: .data) || type.conforms(to: .content) || type.isDynamic
        }
        let types = candidates.compactMap { UTType($0) }
        if let movie = types.first(where: { $0.conforms(to: .movie) || $0.conforms(to: .video) }) { return movie.identifier }
        let images = types.filter { $0.conforms(to: .image) }
        if !images.isEmpty {
            if images.contains(where: { $0.conforms(to: .heic) || $0.conforms(to: .heif) }),
               let jpeg = images.first(where: { $0.conforms(to: .jpeg) }) {
                return jpeg.identifier
            }
            return images[0].identifier
        }
        return types.first(where: { !$0.isDynamic })?.identifier ?? candidates.first
    }

    static func kind(of type: UTType?) -> SharedFile.Kind {
        guard let type else { return .document }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) || (type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio)) { return .movie }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .pdf) { return .pdf }
        return .document
    }

    // MARK: Files

    private func loadFile(_ provider: NSItemProvider, index: Int, knownURL: URL?,
                          report: (@Sendable (Double) -> Void)?) async throws -> SharedFile? {
        let identifiers = provider.registeredTypeIdentifiers
        // Items from Files carry their file URL: it holds the real name, while the temporary copy
        // from loadFileRepresentation may only be called "PDF document.pdf".
        var original = knownURL
        if original == nil, identifiers.contains(UTType.fileURL.identifier) {
            original = try? await loadURL(provider, type: UTType.fileURL.identifier)
        }
        if let url = original, !url.isFileURL { original = nil }
        let suggested = provider.suggestedName ?? original?.lastPathComponent
        if let type = Self.preferredFileType(identifiers) {
            do {
                return try await copyRepresentation(provider, type: type, suggested: suggested, index: index, report: report)
            } catch {
                // Some providers only work through their file URL; try that before giving up.
                guard original != nil, !Task.isCancelled else { throw error }
            }
        }
        guard let url = original else { return nil }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        return try adopt(url, suggestedName: suggested, type: type, index: index)
    }

    private func copyRepresentation(_ provider: NSItemProvider, type identifier: String, suggested: String?, index: Int,
                                    report: (@Sendable (Double) -> Void)?) async throws -> SharedFile? {
        let watch = RepresentationWatch()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let progress = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                    watch.stop()
                    // `url` is deleted when this handler returns, so the copy happens right here.
                    guard let url else {
                        continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                        return
                    }
                    do {
                        continuation.resume(returning: try self.adopt(url, suggestedName: suggested, type: UTType(identifier), index: index))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                watch.start(progress, report: report)
            }
        } onCancel: {
            // Cancelling the Progress ends the export; its handler then runs with an error.
            watch.cancel()
        }
    }

    /// Clones `source` into this share's folder (APFS clones cost no extra space) and describes it.
    /// Returns nil for folders, which the PC upload cannot take.
    private func adopt(_ source: URL, suggestedName: String?, type: UTType?, index: Int) throws -> SharedFile? {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        guard values.isRegularFile == true, values.isDirectory != true else { return nil }
        let name = Self.uploadName(suggested: suggestedName, temporary: source, type: type, index: index)
        let slot = folder.appendingPathComponent(String(index), isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        let destination = slot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return SharedFile(id: UUID(), url: destination, name: name, size: size, kind: Self.kind(of: type),
                          typeIdentifier: type?.identifier ?? "public.data")
    }

    /// A Windows-safe file name. Uses the shared item's name, adds the extension of the format that
    /// was actually saved (Photos may name a photo "IMG_0001.HEIC" while handing over a JPEG).
    static func uploadName(suggested: String?, temporary: URL, type: UTType?, index: Int) -> String {
        let suggestedName = (suggested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var base = suggestedName.isEmpty ? temporary.lastPathComponent : suggestedName
        let actualExtension = !temporary.pathExtension.isEmpty ? temporary.pathExtension : (type?.preferredFilenameExtension ?? "")
        let currentExtension = (base as NSString).pathExtension
        if currentExtension.isEmpty {
            if !actualExtension.isEmpty { base += "." + actualExtension }
        } else if let type, let named = UTType(filenameExtension: currentExtension),
                  !named.conforms(to: type), !type.conforms(to: named), !actualExtension.isEmpty {
            base = (base as NSString).deletingPathExtension + "." + actualExtension
        }
        // A name made only of dots, spaces or symbols ("...", " .png") is replaced, not kept.
        let stem = (base as NSString).deletingPathExtension
        if stem.contains(where: { $0.isLetter || $0.isNumber }), let safe = OrbitFileNames.windowsSafe(base) { return safe }
        let fallback = "Shared item \(index + 1)"
        return actualExtension.isEmpty ? fallback : fallback + "." + actualExtension
    }

    // MARK: Links and text

    private func loadURL(_ provider: NSItemProvider, type: String = UTType.url.identifier) async throws -> URL? {
        let item = try await loadItem(provider, type: type)
        switch item {
        case let url as URL: return url
        case let url as NSURL: return url as URL
        case let data as Data:
            if let url = URL(dataRepresentation: data, relativeTo: nil), url.scheme != nil { return url }
            if let text = String(data: data, encoding: .utf8) { return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return nil
        case let text as String: return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    /// Text up to 4 MB; anything longer cannot fit the PC clipboard anyway and is cut there.
    private static let maxTextBytes = 4 * 1024 * 1024

    private func loadText(_ provider: NSItemProvider) async throws -> String? {
        let item = try await loadItem(provider, type: UTType.plainText.identifier)
        switch item {
        case let text as String: return text
        case let text as NSAttributedString: return text.string
        case let data as Data: return String(decoding: data.prefix(Self.maxTextBytes), as: UTF8.self)
        case let url as URL where url.isFileURL:
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: Self.maxTextBytes)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        default: return nil
        }
    }

    private func loadItem(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: item) }
            }
        }
    }
}

/// Follows the `Progress` of one `loadFileRepresentation` (a Photos export or an iCloud download can
/// take a while) and cancels it when the share is cancelled. The export's handler may run before or
/// after `start`, on any queue.
private final class RepresentationWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?
    private var observation: NSKeyValueObservation?
    private var stopped = false
    private var cancelled = false

    func start(_ progress: Progress, report: (@Sendable (Double) -> Void)?) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        self.progress = progress
        let cancelNow = cancelled
        lock.unlock()
        // Outside the lock: cancelling can run the export's handler (and `stop`) right away.
        if cancelNow { progress.cancel(); return }
        guard let report else { return }
        let observation = progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            report(progress.fractionCompleted)
        }
        lock.lock()
        let late = stopped
        if !late { self.observation = observation }
        lock.unlock()
        if late { observation.invalidate() }
    }

    func stop() {
        lock.lock()
        stopped = true
        let observation = self.observation
        self.observation = nil
        progress = nil
        lock.unlock()
        observation?.invalidate()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let progress = self.progress
        lock.unlock()
        progress?.cancel()
    }
}
