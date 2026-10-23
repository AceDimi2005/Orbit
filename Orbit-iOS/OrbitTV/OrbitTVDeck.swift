import SwiftUI

// "My Buttons" on Apple TV (DESIGN F4): the custom buttons built in Orbit on iPhone, stored on the PC,
// shown as a grid at the top of the Controls tab and run through `OrbitTVViewModel`.
// Feature detection uses `GET /api/capabilities` (404 = an older agent).

@MainActor
final class TVDeckModel: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, ready, unsupported
        case failed(String)
    }

    @Published fileprivate(set) var buttons: [OrbitRemoteDeckButton] = []
    @Published fileprivate(set) var phase: Phase = .idle
    @Published fileprivate(set) var runningButtonID: String?
    @Published var message: String?
    @Published var messageIsError = false
    fileprivate var scope = ""
}

extension OrbitTVViewModel {
    fileprivate var deckScope: String { "\(currentPC?.id ?? "")#\(isDemoMode)" }

    func loadDeck(into model: TVDeckModel, silent: Bool = false) async {
        let scope = deckScope
        if model.scope != scope {
            model.buttons = []
            model.phase = .idle
            model.message = nil
            model.scope = scope
        }
        if isDemoMode {
            model.buttons = OrbitRemoteDeck.demo.buttons
            model.phase = .ready
            return
        }
        guard let pc = currentPC, metrics.isOnline else { return }
        if model.buttons.isEmpty { model.phase = .loading }
        let client: OrbitAPIClient
        do { client = try self.client(for: pc) } catch {
            model.phase = .failed((error as? OrbitError)?.message ?? error.localizedDescription)
            return
        }
        let outcome = await OrbitRemoteDeckService.load(get: { try await client.data($0) }, status: { ($0 as? OrbitError)?.statusCode })
        guard model.scope == scope, deckScope == scope else { return }
        switch outcome {
        case let .deck(deck):
            if model.buttons != deck.buttons { model.buttons = deck.buttons }
            model.phase = .ready
        case .unsupported:
            model.buttons = []
            model.phase = .unsupported
        case let .failed(message):
            if model.buttons.isEmpty {
                model.phase = .failed(message)
            } else if !silent {
                model.message = message
                model.messageIsError = true
            }
        }
    }

    func isDeckButtonLocked(_ button: OrbitRemoteDeckButton, in model: TVDeckModel) -> Bool {
        let index = model.buttons.firstIndex { $0.id == button.id } ?? 0
        return OrbitRemoteDeck.isLocked(index: index, proUnlocked: OrbitProStore.shared.isProUnlocked || isDemoMode)
    }

    func runDeckButton(_ button: OrbitRemoteDeckButton, in model: TVDeckModel) async {
        guard model.runningButtonID == nil, !isDeckButtonLocked(button, in: model) else { return }
        let title = button.displayTitle
        if isDemoMode {
            model.message = "Preview · “\(title)” would run on your PC"
            model.messageIsError = false
            statusBanner = "Preview Command Sent · \(title)"
            return
        }
        guard let pc = currentPC, metrics.isOnline else {
            model.message = "Your PC is offline. Power it on from the Dashboard first."
            model.messageIsError = true
            return
        }
        let scope = deckScope
        let client: OrbitAPIClient
        do { client = try self.client(for: pc) } catch {
            model.message = (error as? OrbitError)?.message ?? error.localizedDescription
            model.messageIsError = true
            return
        }
        model.runningButtonID = button.id
        defer { if model.runningButtonID == button.id { model.runningButtonID = nil } }
        let outcome = await OrbitRemoteDeckService.run(buttonID: button.id, post: { try await client.data($0, method: "POST") },
                                                       status: { ($0 as? OrbitError)?.statusCode })
        guard deckScope == scope else { return }
        switch outcome {
        case let .done(detail):
            let text = detail ?? "“\(title)” ran on \(pc.name)"
            model.message = text
            model.messageIsError = false
            statusBanner = text
            if button.powerAction != nil { metrics.isOnline = false }
        case let .failed(message, missing):
            model.message = message
            model.messageIsError = true
            if missing { await loadDeck(into: model, silent: true) }
        case .unsupported:
            model.phase = .unsupported
            model.message = nil
        }
    }
}

/// The "My Buttons" section of the Controls tab.
struct TVDeckSection: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @StateObject private var deck = TVDeckModel()
    @State private var confirmButton: OrbitRemoteDeckButton?
    @State private var showsPaywall = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 20), count: 4)
    private var loadKey: String { "\(vm.currentPC?.id ?? "")|\(vm.metrics.isOnline)|\(vm.isDemoMode)" }
    private var canRun: Bool { vm.isDemoMode || (vm.metrics.isOnline && vm.currentPC != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TVSectionHeader("My Buttons", subtitle: subtitle) {
                if deck.phase == .loading {
                    ProgressView()
                }
                if canRun {
                    Button {
                        Task { await vm.loadDeck(into: deck) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))
                    .disabled(deck.phase == .loading)
                }
            }
            content
            if let message = deck.message {
                Label(message, systemImage: deck.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(deck.messageIsError ? TVPalette.amber : TVPalette.accent)
                    .lineLimit(2)
            }
        }
        .focusSection()
        .task(id: loadKey) {
            await vm.loadDeck(into: deck, silent: !deck.buttons.isEmpty)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                await vm.loadDeck(into: deck, silent: true)
            }
        }
        .confirmationDialog(confirmButton?.confirmationTitle ?? "Run this button?",
                            isPresented: Binding(get: { confirmButton != nil }, set: { if !$0 { confirmButton = nil } }),
                            titleVisibility: .visible) {
            if let button = confirmButton {
                Button(button.confirmationButton, role: button.powerAction == nil || button.powerAction == "sleep" ? nil : .destructive) {
                    confirmButton = nil
                    Task { await vm.runDeckButton(button, in: deck) }
                }
            }
            Button("Cancel", role: .cancel) { confirmButton = nil }
        } message: {
            Text(confirmButton?.confirmationMessage(pcName: vm.metrics.hostname) ?? "")
        }
        .sheet(isPresented: $showsPaywall) {
            OrbitProUnlockView(accent: TVPalette.accent) { showsPaywall = false }
        }
    }

    private var subtitle: String {
        if vm.isDemoMode { return "Sample buttons · build your own in Orbit on iPhone: Tools → Buttons" }
        return "Built in Orbit on iPhone (Tools → Buttons) and stored on your PC"
    }

    @ViewBuilder
    private var content: some View {
        if !deck.buttons.isEmpty {
            if !canRun {
                // The cards stay visible but disabled, so say why.
                banner(icon: "moon.zzz.fill", tint: TVPalette.amber, title: "PC offline — buttons unavailable",
                       message: "Power on your PC from the Dashboard to run these buttons.")
            }
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(deck.buttons) { button in
                    card(button)
                }
            }
            if !OrbitProStore.shared.isProUnlocked && !vm.isDemoMode && deck.buttons.count > OrbitRemoteDeck.freeButtonLimit {
                Text("The first \(OrbitRemoteDeck.freeButtonLimit) buttons are free. Orbit Pro unlocks the rest.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        } else if vm.currentPC == nil && !vm.isDemoMode {
            banner(icon: "desktopcomputer", tint: TVPalette.accent, title: "Pair a PC to use its buttons",
                   message: "Sync your PC from iPhone or pair it in the My PCs tab.")
        } else if !canRun {
            banner(icon: "moon.zzz.fill", tint: TVPalette.amber, title: "PC offline — buttons unavailable",
                   message: "Power on your PC to load the buttons you built in Orbit on iPhone.")
        } else {
            switch deck.phase {
            case .unsupported:
                banner(icon: "arrow.down.circle.fill", tint: TVPalette.amber, title: "Update Orbit on your PC",
                       message: OrbitRemoteDeckService.updateAgentMessage)
            case let .failed(message):
                banner(icon: "exclamationmark.triangle.fill", tint: TVPalette.amber, title: "Couldn't load your buttons", message: message)
            case .ready:
                banner(icon: "square.grid.2x2.fill", tint: TVPalette.accent, title: "No buttons yet",
                       message: "Create buttons in Orbit on your iPhone (Tools → Buttons): mute Discord, save a clip, start OBS and more. They appear here.")
            case .idle, .loading:
                HStack(spacing: 14) {
                    ProgressView()
                    Text("Loading your buttons…")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tvGlass()
            }
        }
    }

    private func card(_ button: OrbitRemoteDeckButton) -> some View {
        let locked = vm.isDeckButtonLocked(button, in: deck)
        let running = deck.runningButtonID == button.id
        return TVQuickActionCard(
            title: button.displayTitle,
            subtitle: locked ? "Orbit Pro" : (running ? "Running…" : button.subtitle),
            icon: locked ? "lock.fill" : button.displaySymbol,
            tint: locked ? Color.secondary : button.tint(fallback: TVPalette.accent)
        ) {
            if locked {
                showsPaywall = true
            } else if button.needsConfirmation {
                confirmButton = button
            } else {
                Task { await vm.runDeckButton(button, in: deck) }
            }
        }
        .disabled(!canRun || (deck.runningButtonID != nil && !running))
        .accessibilityHint(button.needsConfirmation ? "Asks before it runs on your PC" : "Runs on your PC")
    }

    private func banner(icon: String, tint: Color, title: String, message: String) -> some View {
        HStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(tint.opacity(0.18))
                    .frame(width: 68, height: 68)
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvGlass(tint: tint)
    }
}
