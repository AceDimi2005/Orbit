"""Send to PC (Share Extension): production Swift code against the real agent over pinned TLS.

Compiles `OrbitShare/SendToPCService.swift` and `OrbitShare/ShareItemLoader.swift` with the
production `OrbitAPIClient.swift` and `OrbitError.swift`, then runs them against `orbit_agent.app`
served by uvicorn on loopback TLS. Windows-only steps are replaced by recorders: the PC clipboard,
`orbit_links.open_url` (the agent's real link validation still runs) and the Files roots (Downloads is
a temporary folder). Nothing is opened, copied or written outside the temporary folder.

Covers: item loading (files, text, links, text that is a lone link, other URL schemes, folders, load progress, text summaries,
JPEG preferred over HEIC, file names), capabilities and the older-agent 404, Open on PC, PC
clipboard (limits, null characters), Save to Downloads with conflict-free names, per-file and overall
progress, names and folders with "+", "&" and "#", the PC's upload limit (413), Cancel without leftovers and a retry that
sends only the remaining files, and plain-words errors for a
sleeping PC, a closed port, a rejected token, a missing token and a PC without HTTPS.

Requires macOS Swift and the agent's dev dependencies (run with the venv python).
"""
import hashlib
from pathlib import Path
import platform
import socket
import subprocess
import sys
import tempfile
import threading
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Orbit-Windows-Agent"))
from cryptography import x509
import uvicorn
from fastapi import Request
from starlette.responses import JSONResponse
import orbit_agent as agent
import orbit_desktop
import orbit_files
import orbit_links
import orbit_notify
from orbit_history import SessionRecorder
from orbit_tls import ensure_tls_identity

TOKEN = "share-extension-test-control-token-not-a-real-secret"
OLD_AGENT = {"enabled": False}
clipboard_writes = []
opened_links = []
toasts = []


@agent.app.middleware("http")
async def pretend_older_agent(request: Request, call_next):
    # Agents before 4.4 have neither route, so FastAPI answers 404.
    if OLD_AGENT["enabled"] and request.url.path in ("/api/capabilities", "/api/open-url"):
        return JSONResponse({"detail": "Not Found"}, status_code=404)
    return await call_next(request)


class RecordingClipboard:
    def write(self, text):
        clipboard_writes.append(text)

    def read(self):
        return clipboard_writes[-1] if clipboard_writes else None


def record_link(url, allowed_schemes=orbit_links.WEB_SCHEMES):
    url = orbit_links.validate_url(url, allowed_schemes)
    opened_links.append(url)
    return url


SWIFT = r'''
import Foundation
import UniformTypeIdentifiers

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: \(message)"); exit(1) }
}

func expectError(_ label: String, contains needle: String, pc: String = "Test-PC", _ body: () async throws -> Void) async {
    do {
        try await body()
        check(false, "\(label): expected an error")
    } catch {
        let message = SendToPCService.message(for: error, pcName: pc)
        check(message.contains(needle), "\(label): got \"\(message)\", expected it to contain \"\(needle)\"")
    }
}

final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<[SendToPCSavedFile], Error>?
    private var cancelled = false
    func set(_ value: Task<[SendToPCSavedFile], Error>) {
        lock.lock(); task = value; let cancel = cancelled; lock.unlock()
        if cancel { value.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock()
        current?.cancel()
    }
}

final class ProgressLog<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []
    func add(_ value: Value) { lock.lock(); items.append(value); lock.unlock() }
    var all: [Value] { lock.lock(); defer { lock.unlock() }; return items }
}

@main struct Check {
    static func main() async throws {
        let args = CommandLine.arguments
        let port = Int(args[1])!, token = args[2], fingerprint = args[3]
        let downloads = args[4], work = URL(fileURLWithPath: args[5]), mode = args[6]
        let target = SendToPCTarget(id: "pc", name: "Test-PC", host: "127.0.0.1", port: port, fingerprint: fingerprint, token: token)
        switch mode {
        case "loader": try await loader(work)
        case "full": try await full(target, downloads: downloads, work: work)
        case "old-agent": try await oldAgent(target)
        case "errors": try await errors(target, work: work, closedPort: Int(args[7])!, silentPort: Int(args[8])!)
        default: fatalError("unknown mode")
        }
        print("PASS \(mode)")
    }

    static func loader(_ work: URL) async throws {
        let source = work.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let pdf = source.appendingPathComponent("Report: Q3?.pdf")
        try Data("%PDF-1.4 test".utf8).write(to: pdf)
        let photo = source.appendingPathComponent("photo.jpg")
        try Data(repeating: 0xFF, count: 2048).write(to: photo)
        let folder = source.appendingPathComponent("Holiday", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Files from the Files app: a file URL provider; the name is made Windows-safe.
        var loader = ShareItemLoader(base: work)
        let loading = ProgressLog<SharedLoadProgress>()
        var shared = try await loader.load(providers: [NSItemProvider(contentsOf: pdf)!, NSItemProvider(contentsOf: photo)!],
                                           progress: { loading.add($0) })
        guard case .files(let files) = shared.content else { fatalError("files expected") }
        // "Preparing 1 of 2…", "Preparing 2 of 2…": every item is announced, fractions stay in range.
        check(Set(loading.all.map(\.index)) == [0, 1] && loading.all.allSatisfy { $0.count == 2 }, "load progress \(loading.all)")
        check(loading.all.allSatisfy { (0...1).contains($0.overallFraction) && (0...1).contains($0.itemFraction) }, "load fractions in range")
        check(SharedLoadProgress(index: 1, count: 4, itemFraction: 0.5).overallFraction == 0.375, "overall load fraction")
        check(shared.textSummary == nil, "no text summary for files")
        check(files.count == 2, "two files")
        check(files[0].name == "Report_ Q3_.pdf", "windows-safe name, got \(files[0].name)")
        check(files[0].kind == .pdf && files[1].kind == .image, "kinds \(files.map(\.kind))")
        check(files[1].size == 2048, "size")
        check(files.allSatisfy { $0.url.path.hasPrefix(loader.folder.path) }, "copies live in the share folder")
        check(shared.skippedNote == nil, "nothing skipped")
        loader.cleanUp()
        check(!FileManager.default.fileExists(atPath: loader.folder.path), "cleanUp removes the folder")

        // Photos offering HEIC and JPEG: JPEG is saved, with a matching extension.
        loader = ShareItemLoader(base: work)
        let both = NSItemProvider()
        both.suggestedName = "IMG_0042.HEIC"
        let heic = source.appendingPathComponent("IMG_0042.heic")
        try Data(repeating: 1, count: 100).write(to: heic)
        both.registerFileRepresentation(forTypeIdentifier: UTType.heic.identifier, visibility: .all) { done in
            done(heic, false, nil); return nil
        }
        both.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { done in
            done(photo, false, nil); return nil
        }
        shared = try await loader.load(providers: [both])
        guard case .files(let photos) = shared.content else { fatalError("photo expected") }
        check(photos[0].typeIdentifier == UTType.jpeg.identifier, "JPEG preferred, got \(photos[0].typeIdentifier)")
        check(["IMG_0042.jpg", "IMG_0042.jpeg"].contains(photos[0].name), "extension follows the saved format, got \(photos[0].name)")
        check(photos[0].size == 2048, "JPEG bytes copied")
        check(ShareItemLoader.preferredFileType(["com.apple.live-photo-bundle", "public.heic"]) == "public.heic", "bundles are never chosen")
        check(ShareItemLoader.preferredFileType(["public.url", "public.file-url"]) == nil, "links are not files")
        check(ShareItemLoader.preferredFileType(["com.apple.quicktime-movie", "public.jpeg"]) == "com.apple.quicktime-movie", "movie first")
        loader.cleanUp()

        // A web link with the page title from the extension item.
        loader = ShareItemLoader(base: work)
        shared = try await loader.load(providers: [NSItemProvider(object: URL(string: "https://example.com/news/today?id=7")! as NSURL)],
                                       titles: ["Today's news"])
        guard case .link(let link) = shared.content else { fatalError("link expected") }
        check(link.url.absoluteString == "https://example.com/news/today?id=7" && link.title == "Today's news", "link + title")

        // Plain text; text that is only a link becomes a link; other schemes become text.
        shared = try await loader.load(providers: [NSItemProvider(object: "Buy milk\nand bread" as NSString)])
        guard case .text(let text) = shared.content else { fatalError("text expected") }
        check(text == "Buy milk\nand bread", "text")
        check(shared.textSummary == SharedTextSummary("Buy milk\nand bread") && shared.textSummary?.words == 4, "text summary while loading")

        // Text summary: one pass for words and characters; the excerpt drops blank space around it
        // and marks text that goes on.
        let small = SharedTextSummary("  Hello   big\n\nworld  \n")
        check(small.words == 3 && small.characters == 23 && small.excerpt == "Hello   big\n\nworld", "small summary \(small)")
        let long = SharedTextSummary(String(repeating: "word ", count: 1000))
        check(long.words == 1000 && long.characters == 5000, "long counts \(long.words) \(long.characters)")
        check(long.excerpt.count == 700 && long.excerpt.hasSuffix("word…"), "long excerpt ends with … (\(long.excerpt.suffix(8)))")
        let emoji = SharedTextSummary("👍🏽 ok")
        check(emoji.characters == 4 && emoji.words == 2 && emoji.excerpt == "👍🏽 ok", "graphemes \(emoji)")
        check(SharedTextSummary(" \n\t ").words == 0 && SharedTextSummary(" \n\t ").excerpt.isEmpty, "blank text")
        shared = try await loader.load(providers: [NSItemProvider(object: "  https://example.org/a  \n" as NSString)])
        guard case .link(let lone) = shared.content else { fatalError("lone link expected") }
        check(lone.url.absoluteString == "https://example.org/a", "lone link")
        shared = try await loader.load(providers: [NSItemProvider(object: URL(string: "mailto:pc@example.com")! as NSURL)])
        guard case .text(let mail) = shared.content else { fatalError("mailto as text expected") }
        check(mail == "mailto:pc@example.com", "mailto text")
        check(ShareItemLoader.singleWebLink(in: "see https://example.org") == nil, "sentence is not a link")

        // A folder alone cannot be sent; next to a file it is skipped with a note.
        do {
            _ = try await loader.load(providers: [NSItemProvider(contentsOf: folder)!])
            check(false, "a folder alone must fail")
        } catch {
            check((error as? LocalizedError)?.errorDescription?.contains("Folders can't be sent") == true, "folder message: \(error)")
        }
        shared = try await loader.load(providers: [NSItemProvider(contentsOf: folder)!, NSItemProvider(contentsOf: pdf)!])
        guard case .files(let mixed) = shared.content else { fatalError("files expected") }
        check(mixed.count == 1 && shared.skippedNote?.contains("1 item was skipped") == true, "skipped note: \(String(describing: shared.skippedNote))")
        loader.cleanUp()

        // Names: empty, reserved and odd names still give a usable Windows name.
        let temp = URL(fileURLWithPath: "/tmp/abc.png")
        check(ShareItemLoader.uploadName(suggested: nil, temporary: temp, type: .png, index: 0) == "abc.png", "temp name")
        check(ShareItemLoader.uploadName(suggested: "CON", temporary: temp, type: .png, index: 0) == "_CON.png", "reserved name")
        check(ShareItemLoader.uploadName(suggested: "...", temporary: URL(fileURLWithPath: "/tmp/..."), type: .png, index: 2) == "Shared item 3.png", "fallback name")
    }

    static func full(_ target: SendToPCTarget, downloads: String, work: URL) async throws {
        let service = try SendToPCService(target: target)
        let readiness = try await service.readiness()
        check(readiness.reportsCapabilities && readiness.canOpenLinks, "capabilities: \(readiness)")
        let folder = try await service.downloadsFolder()
        check(folder == downloads, "Downloads from /api/files/roots, got \(folder)")

        try await service.openOnPC(URL(string: "https://example.com/a?b=1#c")!)
        await expectError("credentials in link", contains: "user name or password") {
            try await service.openOnPC(URL(string: "https://user:pass@example.com/")!)
        }
        await expectError("long link", contains: "4,096") {
            try await service.openOnPC(URL(string: "https://example.com/" + String(repeating: "a", count: 4100))!)
        }

        try await service.copyToClipboard("Hello PC\u{0} ✓")
        check(SendToPCService.fitsClipboard(String(repeating: "a", count: 524_287)), "largest clipboard text fits")
        check(!SendToPCService.fitsClipboard(String(repeating: "a", count: 524_288)), "1 MB limit")
        await expectError("huge clipboard", contains: "too long") {
            try await service.copyToClipboard(String(repeating: "a", count: 600_000))
        }

        // Uploads: duplicate names in the batch and on the PC get " (2)", progress ends at 1.
        let source = work.appendingPathComponent("upload", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let small = source.appendingPathComponent("notes.txt")
        try Data("first".utf8).write(to: small)
        let other = source.appendingPathComponent("notes-copy.txt")
        try Data("second".utf8).write(to: other)
        let big = source.appendingPathComponent("clip.mov")
        try Data(repeating: 7, count: 3 * 1024 * 1024).write(to: big)
        let existing = source.appendingPathComponent("photo.jpg")
        try Data("new photo".utf8).write(to: existing)
        let items = [
            SendToPCService.UploadItem(url: small, name: "notes.txt", size: 5),
            SendToPCService.UploadItem(url: other, name: "notes.txt", size: 6),
            SendToPCService.UploadItem(url: big, name: "clip.mov", size: 3 * 1024 * 1024),
            SendToPCService.UploadItem(url: existing, name: "photo.jpg", size: 9),
        ]
        let log = ProgressLog<SendToPCUploadProgress>()
        let saved = try await service.save(items, into: downloads) { log.add($0) }
        check(saved.map(\.savedName) == ["notes.txt", "notes (2).txt", "clip.mov", "photo (2).jpg"], "saved names \(saved.map(\.savedName))")
        check(saved.filter(\.wasRenamed).count == 2, "two renamed")
        let updates = log.all
        check(updates.last?.overallFraction == 1, "overall progress ends at 1")
        check(updates.contains { $0.index == 2 && $0.fileFraction > 0 && $0.fileFraction < 1 } || updates.contains { $0.index == 2 && $0.fileFraction == 1 }, "per-file progress for the big file")
        var previous = -1.0
        for update in updates {
            check(update.overallFraction >= 0 && update.overallFraction <= 1, "overall in range")
            check(update.fileFraction >= 0 && update.fileFraction <= 1, "file in range")
            check(update.overallFraction + 1e-9 >= previous, "overall progress never goes back: \(previous) → \(update.overallFraction)")
            previous = update.overallFraction
        }

        // Names and folders with "+", "&", "=" and "#" arrive exactly as written: in a query the
        // agent reads a bare "+" as a space ("C++" became "C  ", "notes+" became "notes " and a 422).
        let plus = source.appendingPathComponent("plus.txt")
        try Data("plus".utf8).write(to: plus)
        let plusNames = try await service.save([SendToPCService.UploadItem(url: plus, name: "C++ notes+1.txt", size: 4),
                                                SendToPCService.UploadItem(url: plus, name: "plus+", size: 4)], into: downloads) { _ in }
        check(plusNames.map(\.savedName) == ["C++ notes+1.txt", "plus+"] && !plusNames.contains(where: \.wasRenamed),
              "plus signs kept, got \(plusNames.map(\.savedName))")
        let inFolder = try await service.save([SendToPCService.UploadItem(url: plus, name: "a+b.txt", size: 4)],
                                              into: downloads + "/Q&A C++ a=b #1") { _ in }
        check(inFolder.map(\.savedName) == ["a+b.txt"], "plus signs in the folder path, got \(inFolder.map(\.savedName))")

        // Cancel before the Downloads folder is known: a cancellation, not an error.
        let lookup = Task { try await service.downloadsFolder() }
        lookup.cancel()
        do {
            _ = try await lookup.value
            check(false, "a cancelled Downloads lookup must stop")
        } catch {
            check(SendToPCService.isCancellation(error), "cancelled Downloads lookup: \(error)")
        }

        // The PC's upload limit (the test agent allows 4 MB): the plain message, and what arrived.
        let tooBig = source.appendingPathComponent("movie.mp4")
        try Data(repeating: 9, count: 5 * 1024 * 1024).write(to: tooBig)
        do {
            _ = try await service.save([items[0], SendToPCService.UploadItem(url: tooBig, name: "movie.mp4", size: 5 * 1024 * 1024)], into: downloads) { _ in }
            check(false, "413 expected")
        } catch let error as SendToPCBatchError {
            check(error.saved.map(\.savedName) == ["notes (3).txt"], "first file saved before the limit, got \(error.saved)")
            check(error.failedName == "movie.mp4", "failed name")
            let message = SendToPCService.message(for: error, pcName: "Test-PC")
            check(message.contains("upload limit"), "limit message: \(message)")
        }
        check(SendToPCService.oversized([SendToPCService.UploadItem(url: tooBig, name: "huge.mov", size: SendToPCService.maxFileBytes + 1)])?.name == "huge.mov", "client-side 2 GB check")

        // Cancel during an upload: the batch reports cancellation and the PC keeps no partial file.
        let large = source.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 3_900_000)
        try handle.close()
        let slow = (0..<6).map { SendToPCService.UploadItem(url: large, name: "large-\($0).bin", size: 3_900_000) }
        let box = TaskBox()
        let task = Task { try await service.save(slow, into: downloads) { update in
            if update.index >= 1 && update.fileFraction > 0 { box.cancel() }
        } }
        box.set(task)
        let slowIDs = slow.map { _ in UUID() }
        var deliveries = SendToPCDeliveries()
        do {
            _ = try await task.value
            check(false, "cancellation expected")
        } catch let error as SendToPCBatchError {
            check(error.isCancellation, "cancelled, got \(error.underlying)")
            check(error.saved.count >= 1 && error.saved.count < 6, "some files saved before Cancel: \(error.saved.count)")
            check(SendToPCService.message(for: error, pcName: "Test-PC").contains("cancelled"), "cancel message")
            deliveries.record(error.saved, forFirstOf: slowIDs, on: target.id)
        }
        // Saving again sends only what the PC does not have: no "large-0 (2).bin" copies.
        let savedBefore = deliveries.saved(on: target.id).count
        let rest = deliveries.remaining(slowIDs, on: target.id)
        check(rest.count == 6 - savedBefore && rest == Array(slowIDs.dropFirst(savedBefore)), "remaining after Cancel")
        check(deliveries.remaining(slowIDs, on: "other-pc") == slowIDs && deliveries.saved(on: "other-pc").isEmpty, "other PCs have nothing yet")
        let retry = rest.compactMap { id in slowIDs.firstIndex(of: id).map { slow[$0] } }
        let resumed = try await service.save(retry, into: downloads) { _ in }
        deliveries.record(resumed, forFirstOf: rest, on: target.id)
        check(resumed.allSatisfy { !$0.wasRenamed }, "the retry renamed nothing: \(resumed.map(\.savedName))")
        check(deliveries.remaining(slowIDs, on: target.id).isEmpty, "everything delivered after the retry")
        check(slowIDs.compactMap { deliveries.saved(on: target.id)[$0]?.savedName } == (0..<6).map { "large-\($0).bin" }, "each file once, in order")
    }

    static func oldAgent(_ target: SendToPCTarget) async throws {
        let service = try SendToPCService(target: target)
        let readiness = try await service.readiness()
        check(!readiness.reportsCapabilities && !readiness.canOpenLinks && readiness.features.isEmpty, "older agent: \(readiness)")
        await expectError("open link on older agent", contains: "newer Orbit Companion on Test-PC") {
            try await service.openOnPC(URL(string: "https://example.com")!)
        }
        try await service.copyToClipboard("still works")
    }

    static func errors(_ target: SendToPCTarget, work: URL, closedPort: Int, silentPort: Int) async throws {
        // A sleeping PC: the port accepts but never answers.
        let asleep = try SendToPCService(target: SendToPCTarget(id: "a", name: "Asleep", host: "127.0.0.1", port: silentPort, fingerprint: target.fingerprint, token: "x"))
        let started = Date()
        await expectError("sleeping PC", contains: "isn't reachable") { _ = try await asleep.readiness(timeout: 1.5) }
        check(Date().timeIntervalSince(started) < 6, "the check gives up quickly")
        // Nothing listening.
        let off = try SendToPCService(target: SendToPCTarget(id: "o", name: "Off", host: "127.0.0.1", port: closedPort, fingerprint: target.fingerprint, token: "x"))
        await expectError("closed port", contains: "isn't reachable") { _ = try await off.readiness() }
        // Wrong token.
        let rejected = try SendToPCService(target: SendToPCTarget(id: "r", name: "Desk", host: target.host, port: target.port, fingerprint: target.fingerprint, token: "wrong-token"))
        await expectError("rejected token", contains: "no longer accepts this iPhone", pc: "Desk") { _ = try await rejected.readiness() }
        await expectError("rejected token on upload", contains: "no longer accepts this iPhone", pc: "Desk") {
            let file = work.appendingPathComponent("x.txt"); try Data("x".utf8).write(to: file)
            _ = try await rejected.save([SendToPCService.UploadItem(url: file, name: "x.txt", size: 1)], into: "/") { _ in }
        }
        // Wrong certificate.
        let impostor = try SendToPCService(target: SendToPCTarget(id: "i", name: "Desk", host: target.host, port: target.port, fingerprint: String(repeating: "0", count: 64), token: target.token))
        await expectError("wrong certificate", contains: "fingerprint does not match") { _ = try await impostor.readiness() }
        // Missing token / no HTTPS set up.
        do { _ = try SendToPCService(target: SendToPCTarget(id: "t", name: "Desk", host: "h", port: 1, fingerprint: target.fingerprint, token: nil)); check(false, "token") }
        catch { check(error.localizedDescription == SendToPCText.needsToken("Desk"), "missing token message") }
        do { _ = try SendToPCService(target: SendToPCTarget(id: "f", name: "Desk", host: "h", port: 1, fingerprint: "", token: "t")); check(false, "fingerprint") }
        catch { check(error.localizedDescription == SendToPCText.needsEncryption("Desk"), "missing fingerprint message") }
        // URL errors in plain words.
        check(SendToPCService.message(for: URLError(.timedOut), pcName: "Desk") == SendToPCText.unreachable, "timeout")
        check(SendToPCService.message(for: OrbitError(message: "x", statusCode: 401), pcName: "Desk") == SendToPCText.tokenRejected("Desk"), "401")
        check(SendToPCService.message(for: OrbitError(message: "There is not enough space on this drive.", statusCode: 507), pcName: "Desk").contains("not enough space"), "507 detail")
        // Cancel in every shape it arrives in; connection loss (what a send paused in the background
        // ends with) versus an answer from the PC.
        check(SendToPCService.isCancellation(URLError(.cancelled)) && SendToPCService.isCancellation(CancellationError()), "cancel shapes")
        check(SendToPCService.isCancellation(SendToPCBatchError(saved: [], failedName: "a", underlying: CancellationError())), "batch cancel")
        check(!SendToPCService.isCancellation(URLError(.timedOut)) && !SendToPCService.isCancellation(OrbitError(message: "x", statusCode: 409)), "not cancel")
        check(SendToPCService.isConnectionLoss(URLError(.networkConnectionLost)) && SendToPCService.isConnectionLoss(SendToPCTimeout())
              && SendToPCService.isConnectionLoss(SendToPCBatchError(saved: [], failedName: "a", underlying: URLError(.timedOut))), "connection loss")
        check(!SendToPCService.isConnectionLoss(OrbitError(message: "x", statusCode: 413)) && !SendToPCService.isConnectionLoss(URLError(.cancelled)),
              "answers and Cancel are not connection loss")
    }
}
'''


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def run(binary, port, fingerprint, downloads, work, mode, *extra):
    result = subprocess.run([str(binary), str(port), TOKEN, fingerprint, str(downloads), str(work), mode, *map(str, extra)],
                            capture_output=True, text=True, timeout=90)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    assert result.returncode == 0, f"{mode} failed with exit code {result.returncode}"
    assert f"PASS {mode}" in result.stdout


def main():
    with tempfile.TemporaryDirectory(prefix="orbit-share-check-") as temporary:
        root = Path(temporary).resolve()
        downloads = root / "pc" / "Downloads"
        downloads.mkdir(parents=True)
        (downloads / "photo.jpg").write_bytes(b"already on the PC")
        (downloads / "Q&A C++ a=b #1").mkdir()  # a folder whose path needs "+", "&", "=" and "#" encoded
        work = root / "work"
        work.mkdir()
        with patch("orbit_tls.local_names", return_value=[x509.DNSName("share-test.invalid")]):
            cert, key, fingerprint = ensure_tls_identity(root / "tls")
        swift = root / "Check.swift"
        swift.write_text(SWIFT)
        binary = root / "check"
        # macOS 14, like the oldest Mac Orbit supports, so APIs deprecated later stay quiet.
        subprocess.run(["swiftc", "-parse-as-library", "-target", f"{platform.machine()}-apple-macos14.0",
                        str(ROOT / "Orbit-iOS/Orbit/OrbitAPIClient.swift"),
                        str(ROOT / "Orbit-iOS/Shared/OrbitError.swift"),
                        str(ROOT / "Orbit-iOS/OrbitShare/SendToPCService.swift"),
                        str(ROOT / "Orbit-iOS/OrbitShare/ShareItemLoader.swift"),
                        str(swift), "-o", str(binary)], check=True)

        port = free_port()
        closed_port = free_port()
        silent = socket.socket()
        silent.bind(("127.0.0.1", 0))
        silent.listen(8)  # accepts connections, never answers: a PC that fell asleep
        silent_port = silent.getsockname()[1]

        roots = {"roots": [{"name": "C:", "path": str(root / "pc"), "kind": "drive"}],
                 "shortcuts": [{"name": "Desktop", "path": str(root / "pc"), "kind": "shortcut"},
                               {"name": "Downloads", "path": str(downloads), "kind": "shortcut"}]}
        agent.API_TOKEN = TOKEN
        agent.HISTORY_RECORDER = SessionRecorder(root / "history.sqlite3")
        orbit_notify.set_notifier(lambda title, message: toasts.append((title, message)) or True)
        server = uvicorn.Server(uvicorn.Config(agent.app, host="127.0.0.1", port=port, lifespan="off",
                                               ssl_certfile=str(cert), ssl_keyfile=str(key), proxy_headers=False,
                                               access_log=False, log_level="critical"))  # a cancelled upload logs ClientDisconnect
        thread = threading.Thread(target=server.run, daemon=True)
        with patch.object(agent, "require_windows", lambda: None), \
                patch.object(orbit_links, "open_url", record_link), \
                patch.object(orbit_desktop, "WindowsClipboard", RecordingClipboard), \
                patch.object(orbit_files, "file_roots", lambda: roots), \
                patch.object(orbit_files, "MAX_UPLOAD_BYTES", 4 * 1024 * 1024), \
                patch.object(orbit_files.UPLOAD_TOASTS, "quiet", 0.2), \
                patch.object(orbit_files.UPLOAD_TOASTS, "max_delay", 0.5):
            thread.start()
            try:
                for _ in range(200):
                    if server.started:
                        break
                    time.sleep(.025)
                assert server.started, "Local TLS server did not start"
                run(binary, port, fingerprint, downloads, work, "loader")
                run(binary, port, fingerprint, downloads, work, "full")
                OLD_AGENT["enabled"] = True
                run(binary, port, fingerprint, downloads, work, "old-agent")
                OLD_AGENT["enabled"] = False
                run(binary, port, fingerprint, downloads, work, "errors", closed_port, silent_port)
                time.sleep(1.0)  # let the agent finish cleaning up the cancelled upload
            finally:
                server.should_exit = True
                thread.join(5)
                silent.close()
                orbit_notify.set_notifier(None)
                agent.HISTORY_RECORDER.close()
                agent.HISTORY_RECORDER = None
        assert not thread.is_alive(), "Local TLS server did not stop"

        assert opened_links == ["https://example.com/a?b=1#c"], opened_links
        assert clipboard_writes == ["Hello PC ✓", "still works"], clipboard_writes
        names = sorted(path.name for path in downloads.iterdir())
        assert not any(name.startswith(".orbit-upload-") for name in names), f"partial upload left behind: {names}"
        expected = {"notes.txt": b"first", "notes (2).txt": b"second", "photo.jpg": b"already on the PC",
                    "photo (2).jpg": b"new photo", "notes (3).txt": b"first",
                    "C++ notes+1.txt": b"plus", "plus+": b"plus", "Q&A C++ a=b #1/a+b.txt": b"plus"}
        for name, content in expected.items():
            assert (downloads / name).read_bytes() == content, name
        assert not any(name.startswith(("C   notes", "plus ", "Q&A C   ")) for name in names), f"a '+' arrived as a space: {names}"
        assert hashlib.sha256((downloads / "clip.mov").read_bytes()).hexdigest() == hashlib.sha256(bytes([7]) * 3 * 1024 * 1024).hexdigest()
        assert "movie.mp4" not in names, names
        large = [name for name in names if name.startswith("large-")]
        # Cancel, then "Save Remaining Files": every file exactly once, none twice.
        assert sorted(large) == [f"large-{index}.bin" for index in range(6)], large
        for name in large:
            assert (downloads / name).stat().st_size == 3_900_000, f"{name} is incomplete"
        # Uploads close together share one toast; with the "+" folder it names two folders instead of Downloads.
        assert any(title in ("File received", "Files received") and ("Downloads" in message or "folders" in message)
                   for title, message in toasts), toasts
        print("PASS: Send to PC loads shared files, text and links; opens links, fills the PC clipboard and saves files to "
              "Downloads over pinned TLS with conflict-free names, progress, the PC's size limit, Cancel without leftovers, "
              "older agents and plain-words errors")


if __name__ == "__main__":
    main()
