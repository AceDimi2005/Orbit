import QuickLookThumbnailing
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Send to PC sheet: destination PC, a preview of what is shared, and the send actions.
struct SendToPCView: View {
    @ObservedObject var model: SendToPCModel

    var body: some View {
        NavigationStack {
            ZStack {
                ShareTheme.background.ignoresSafeArea()
                switch model.stage {
                case .loading:
                    SendToPCLoadingView(progress: model.preparing)
                case .unavailable(let title, let message):
                    SendToPCUnavailableView(title: title, message: message, showsPairingSteps: model.targets.isEmpty) {
                        model.cancel()
                    }
                case .finished(let title, let message):
                    SendToPCSuccessView(title: title, message: message)
                case .ready, .sending:
                    SendToPCMainView(model: model)
                }
            }
            .navigationTitle("Send to PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ShareTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .finished = model.stage {
                        EmptyView()
                    } else {
                        Button("Cancel") { model.cancel() }
                            .accessibilityHint(model.stage == .sending ? "Stops the upload and closes Send to PC." : "Closes Send to PC without sending anything.")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .finished = model.stage {
                        Button("Done") { model.done() }.fontWeight(.semibold)
                    }
                }
            }
        }
        .tint(ShareTheme.accent)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Main sheet

private struct SendToPCMainView: View {
    @ObservedObject var model: SendToPCModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                destination
                if let content = model.content {
                    SendToPCPreview(content: content, textSummary: model.textSummary, transfer: model.transfer,
                                    alreadySaved: model.alreadySavedIDs)
                }
                if let transfer = model.transfer {
                    SendToPCTransferCard(transfer: transfer, pcName: model.selectedName)
                }
                notices
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .frame(maxWidth: ShareTheme.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SendToPCActionBar(model: model)
        }
    }

    // MARK: Destination

    private var destination: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShareSectionHeader(title: "Send to", icon: "desktopcomputer")
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    // Large text: the PC name gets the full width, the picker goes below it.
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            ShareIconBadge(systemName: "desktopcomputer", tint: ShareTheme.accent, filled: true)
                            pcSummary
                        }
                        picker
                    }
                } else {
                    HStack(spacing: 12) {
                        ShareIconBadge(systemName: "desktopcomputer", tint: ShareTheme.accent, filled: true)
                        pcSummary
                        Spacer(minLength: 8)
                        picker
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shareCard()
        }
    }

    private var pcSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.selectedName)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
            status
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sending to \(model.selectedName), \(statusText)")
    }

    /// Shown only with more than one saved PC; the default PC is listed first.
    @ViewBuilder private var picker: some View {
        if model.targets.count > 1 {
            Menu {
                Picker("PC", selection: Binding(get: { model.selectedID ?? "" }, set: { model.select($0) })) {
                    ForEach(model.targets) { target in
                        Text(target.name).tag(target.id)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Change")
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
            .disabled(model.isBusy)
            .accessibilityLabel("Choose PC")
            .accessibilityValue(model.selectedName)
        }
    }

    private var statusText: String {
        switch model.pcState {
        case .checking: return "checking"
        case .ready: return "ready"
        case .problem(let message): return message == SendToPCText.unreachable ? "not reachable" : "needs attention"
        }
    }

    @ViewBuilder private var status: some View {
        switch model.pcState {
        case .checking:
            ShareStatusPill(text: "Checking…", tint: .white.opacity(0.75), showsSpinner: true)
        case .ready:
            ShareStatusPill(text: "Ready", tint: ShareTheme.success)
        case .problem(let message):
            ShareStatusPill(text: message == SendToPCText.unreachable ? "Not reachable" : "Needs attention", tint: ShareTheme.warning)
        }
    }

    // MARK: Notices

    @ViewBuilder private var notices: some View {
        if let notice = model.notice {
            ShareNotice(title: notice.title, message: notice.message,
                        icon: notice.tone == .error ? "exclamationmark.triangle.fill" : "info.circle.fill",
                        tint: notice.tone == .error ? ShareTheme.danger : (notice.tone == .warning ? ShareTheme.warning : ShareTheme.accent))
                .transition(.opacity)
        }
        if case .problem(let message) = model.pcState {
            ShareNotice(title: message == SendToPCText.unreachable ? "\(model.selectedName) isn't reachable" : "Check \(model.selectedName) in Orbit",
                        message: message,
                        icon: message == SendToPCText.unreachable ? "wifi.exclamationmark" : "desktopcomputer.trianglebadge.exclamationmark",
                        tint: ShareTheme.warning)
        }
        if case .link? = model.content, let readiness = model.readiness, !readiness.canOpenLinks {
            ShareNotice(title: "Opening links needs an update", message: SendToPCText.linksNeedUpdate(model.selectedName),
                        icon: "arrow.down.circle.fill", tint: ShareTheme.accent)
        }
        if let skipped = model.skippedNote {
            ShareNotice(title: "Some items were skipped", message: skipped, icon: "info.circle.fill", tint: ShareTheme.accent)
        }
    }
}

// MARK: - Actions

private struct SendToPCActionBar: View {
    @ObservedObject var model: SendToPCModel

    var body: some View {
        VStack(spacing: 10) {
            buttons
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: ShareTheme.maxContentWidth)
        .frame(maxWidth: .infinity)
        .background {
            ShareTheme.background
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var ready: Bool {
        if case .ready = model.pcState { return true }
        return false
    }

    @ViewBuilder private var buttons: some View {
        if model.stage == .sending {
            Button(role: .cancel) { model.cancelTransfer() } label: {
                Label("Cancel Upload", systemImage: "xmark")
            }
            .buttonStyle(ShareSecondaryButtonStyle(tint: ShareTheme.danger))
            .accessibilityHint("Stops the upload. Files that already arrived stay on the PC.")
        } else {
            switch model.content {
            case .link?:
                if model.readiness?.canOpenLinks ?? true {
                    primary("Open on PC", icon: "safari", action: .openLink) { model.openLink() }
                        .accessibilityHint("Opens the link in the web browser on \(model.selectedName).")
                    secondary("Copy to PC Clipboard", icon: "doc.on.clipboard", action: .copyText) { model.copyText() }
                } else {
                    primary("Copy to PC Clipboard", icon: "doc.on.clipboard", action: .copyText) { model.copyText() }
                }
            case .text?:
                primary("Copy to PC Clipboard", icon: "doc.on.clipboard", action: .copyText) { model.copyText() }
                    .accessibilityHint("Puts the text on the clipboard of \(model.selectedName).")
            case .files(let files)?:
                primary(saveTitle(total: files.count, remaining: model.remainingFiles.count),
                        icon: "square.and.arrow.down", action: .saveFiles) { model.saveFiles() }
                    .accessibilityHint(model.alreadySavedIDs.isEmpty
                                       ? "Saves to the Downloads folder on \(model.selectedName)."
                                       : "Saves the files that aren't on \(model.selectedName) yet to its Downloads folder.")
            case nil:
                EmptyView()
            }
            if case .problem = model.pcState {
                Button { model.retryCheck() } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ShareSecondaryButtonStyle())
            }
        }
    }

    /// After an interrupted upload, the button names only the files the PC does not have yet.
    private func saveTitle(total: Int, remaining: Int) -> String {
        if remaining < total {
            return remaining == 1 ? "Save Remaining File to PC Downloads" : "Save \(remaining) Remaining Files to PC Downloads"
        }
        return total == 1 ? "Save to PC Downloads" : "Save \(total) Files to PC Downloads"
    }

    private func primary(_ title: String, icon: String, action: SendToPCModel.Action, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            label(title, icon: icon, busy: model.busyAction == action, tint: .black)
        }
        .buttonStyle(ShareProminentButtonStyle())
        .disabled(!ready || model.isBusy)
    }

    private func secondary(_ title: String, icon: String, action: SendToPCModel.Action, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            label(title, icon: icon, busy: model.busyAction == action, tint: .white)
        }
        .buttonStyle(ShareSecondaryButtonStyle())
        .disabled(!ready || model.isBusy)
    }

    private func label(_ title: String, icon: String, busy: Bool, tint: Color) -> some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().tint(tint)
            } else {
                Image(systemName: icon).accessibilityHidden(true)
            }
            Text(title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(busy ? "\(title), sending" : title)
    }
}

// MARK: - Preview of the shared items

private struct SendToPCPreview: View {
    let content: SharedContent
    let textSummary: SharedTextSummary?
    let transfer: SendToPCModel.Transfer?
    /// Files the selected PC already received in an earlier, interrupted attempt.
    let alreadySaved: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch content {
            case .link(let link):
                ShareSectionHeader(title: "Link", icon: "link")
                SendToPCLinkCard(link: link)
            case .text:
                ShareSectionHeader(title: "Text", icon: "text.alignleft")
                if let textSummary {
                    SendToPCTextCard(summary: textSummary)
                }
            case .files(let files):
                ShareSectionHeader(title: Self.filesHeader(files), icon: "doc.on.doc")
                VStack(spacing: 0) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        if index > 0 {
                            Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 72)
                        }
                        SendToPCFileRow(file: file, state: state(for: file))
                    }
                }
                .shareCard()
            }
        }
    }

    static func filesHeader(_ files: [SharedFile]) -> String {
        let total = SendToPCService.format(files.reduce(Int64(0)) { $0 + $1.size })
        return "\(files.count) \(files.count == 1 ? "item" : "items") · \(total)"
    }

    private func state(for file: SharedFile) -> SendToPCFileRow.State {
        if alreadySaved.contains(file.id) { return .saved }
        guard let transfer else { return .idle }
        if transfer.savedIDs.contains(file.id) { return .saved }
        if file.id == transfer.currentID { return transfer.fileFraction >= 0.999 ? .finishing : .sending(transfer.fileFraction) }
        return .waiting
    }
}

private struct SendToPCLinkCard: View {
    let link: SharedLink

    private var host: String { link.url.host ?? link.url.absoluteString }
    private var detail: String {
        var text = link.url.path
        if text == "/" { text = "" }
        if let query = link.url.query, !query.isEmpty { text += "?" + query }
        if let fragment = link.url.fragment, !fragment.isEmpty { text += "#" + fragment }
        return String(text.prefix(400))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ShareIconBadge(systemName: link.url.scheme?.lowercased() == "https" ? "lock.fill" : "globe")
            VStack(alignment: .leading, spacing: 4) {
                if let title = link.title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                }
                Text(host)
                    .font(.headline)
                    .foregroundStyle(link.title == nil ? .white : ShareTheme.accent)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.footnote.monospaced())
                        .foregroundStyle(ShareTheme.secondaryText)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shareCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([link.title, "Link to \(host)", detail.isEmpty ? nil : detail].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Shared text: excerpt and counts come precomputed (`SharedTextSummary`), since the text can be
/// megabytes long and this view is redrawn whenever the sheet's state changes.
private struct SendToPCTextCard: View {
    let summary: SharedTextSummary

    private var countText: String {
        let words = summary.words, characters = summary.characters
        return "\(words.formatted()) \(words == 1 ? "word" : "words") · \(characters.formatted()) \(characters == 1 ? "character" : "characters")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.excerpt)
                .font(.body)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(countText)
                .font(.caption.weight(.medium))
                .foregroundStyle(ShareTheme.secondaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shareCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Text, \(countText)")
        .accessibilityValue(summary.excerpt)
    }
}

private struct SendToPCFileRow: View {
    enum State: Equatable { case idle, waiting, sending(Double), finishing, saved }

    let file: SharedFile
    let state: State

    private var kindText: String {
        switch file.kind {
        case .image: return "Photo"
        case .movie: return "Video"
        case .audio: return "Audio"
        case .pdf: return "PDF"
        case .document:
            return UTType(file.typeIdentifier).flatMap { $0.isDynamic ? nil : $0.localizedDescription }?.capitalizedFirst ?? "File"
        }
    }

    private var stateText: String {
        switch state {
        case .idle: return ""
        case .waiting: return "Waiting"
        case .sending(let fraction): return "\(Int((fraction * 100).rounded())) percent"
        case .finishing: return "Finishing"
        case .saved: return "Saved"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            SendToPCThumbnail(file: file)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("\(kindText) · \(SendToPCService.format(file.size))")
                    .font(.caption)
                    .foregroundStyle(ShareTheme.secondaryText)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.name), \(kindText), \(SendToPCService.format(file.size))")
        .accessibilityValue(stateText)
    }

    @ViewBuilder private var trailing: some View {
        switch state {
        case .idle:
            EmptyView()
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.white.opacity(0.4))
        case .sending(let fraction):
            SendToPCRing(fraction: fraction)
        case .finishing:
            ProgressView()
                .tint(ShareTheme.accent)
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(ShareTheme.success)
        }
    }
}

/// Small determinate ring for the file that is uploading.
private struct SendToPCRing: View {
    let fraction: Double
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(ShareTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.15), value: fraction)
        }
        .frame(width: side, height: side)
    }
}

/// Thumbnail made by Quick Look from the local copy (never the full image in memory).
private struct SendToPCThumbnail: View {
    let file: SharedFile
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 46
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private var symbol: String {
        switch file.kind {
        case .image: return "photo"
        case .movie: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .document: return "doc"
        }
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.08)
                Image(systemName: symbol)
                    .font(.system(size: side * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .overlay(alignment: .bottomLeading) {
            if file.kind == .movie, image != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: side * 0.2, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .shadow(color: .black.opacity(0.6), radius: 2)
            }
        }
        .accessibilityHidden(true)
        .task(id: file.id) {
            let request = QLThumbnailGenerator.Request(fileAt: file.url, size: CGSize(width: side, height: side),
                                                       scale: displayScale, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }
    }
}

private struct SendToPCTransferCard: View {
    let transfer: SendToPCModel.Transfer
    let pcName: String

    /// Bytes handed to the network are not yet saved: the bar stops at 99 % until the PC confirms.
    private var fraction: Double { min(0.99, max(0, transfer.overallFraction)) }
    private var percent: Int { Int((fraction * 100).rounded(.down)) }
    private var finishing: Bool { transfer.fileFraction >= 0.999 }

    private var title: String {
        if transfer.count == 1 { return transfer.resuming ? "Saving the last file" : "Saving to Downloads" }
        return "Saving \(transfer.index + 1) of \(transfer.count)" + (transfer.resuming ? " remaining" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Text("\(percent)%")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(ShareTheme.accent)
            }
            ProgressView(value: fraction)
                .tint(ShareTheme.accent)
                .accessibilityHidden(true)
            HStack {
                Text(finishing ? "Finishing on \(pcName)…" : transfer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(SendToPCService.format(transfer.bytesSent)) of \(SendToPCService.format(transfer.bytesTotal))")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(ShareTheme.secondaryText)
            // iOS pauses the share sheet soon after you leave the app it came from.
            Label("Keep this sheet open until it finishes.", systemImage: "hand.raised")
                .font(.caption)
                .foregroundStyle(ShareTheme.secondaryText)
        }
        .padding(14)
        .shareCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(transfer.count == 1 ? "Saving \(transfer.name) to Downloads" : "Saving file \(transfer.index + 1) of \(transfer.count), \(transfer.name)")
        .accessibilityValue("\(percent) percent")
        .accessibilityHint("Keep this sheet open until it finishes.")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Other states

/// Shown while the shared items are copied (Photos exports videos and may first download them from
/// iCloud, which can take a while): which item, and how far, so the sheet never looks frozen.
private struct SendToPCLoadingView: View {
    let progress: SharedLoadProgress?

    private var title: String {
        guard let progress, progress.count > 1 else { return "Getting your items ready…" }
        return "Preparing \(progress.index + 1) of \(progress.count)…"
    }

    /// A bar once there is something to show: several items, or one item that reports progress.
    private var fraction: Double? {
        guard let progress else { return nil }
        if progress.count > 1 || progress.itemFraction > 0 { return progress.overallFraction }
        return nil
    }

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(ShareTheme.accent)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(ShareTheme.secondaryText)
                .monospacedDigit()
                .multilineTextAlignment(.center)
            if let fraction {
                ProgressView(value: fraction)
                    .tint(ShareTheme.accent)
                    .frame(maxWidth: 240)
                    .animation(.linear(duration: 0.2), value: fraction)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct SendToPCUnavailableView: View {
    let title: String
    let message: String
    let showsPairingSteps: Bool
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(ShareTheme.accent.opacity(0.12))
                    Circle().strokeBorder(ShareTheme.accent.opacity(0.25), lineWidth: 1)
                    Image(systemName: showsPairingSteps ? "desktopcomputer" : "tray")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(ShareTheme.accent)
                }
                .frame(width: 76, height: 76)
                .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(ShareTheme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                if showsPairingSteps {
                    VStack(alignment: .leading, spacing: 12) {
                        step(1, "Open Orbit on this iPhone.")
                        step(2, "Tap Find my PC and pair your Windows PC.")
                        step(3, "Share again and choose Send to PC.")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shareCard()
                }
                Button("Close", action: close)
                    .buttonStyle(ShareSecondaryButtonStyle())
            }
            .padding(24)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold).monospacedDigit())
                .foregroundStyle(.black.opacity(0.85))
                .frame(minWidth: 22, minHeight: 22)
                .background(ShareTheme.accent, in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
    }
}

private struct SendToPCSuccessView: View {
    let title: String
    let message: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(ShareTheme.success.opacity(0.14))
                Circle().strokeBorder(ShareTheme.success.opacity(0.32), lineWidth: 1)
                Image(systemName: "checkmark")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(ShareTheme.success)
            }
            .frame(width: 96, height: 96)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.7)
            .opacity(appeared || reduceMotion ? 1 : 0)
            .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.body)
                .foregroundStyle(ShareTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) { appeared = true }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
