import SwiftUI
import UIKit

// The Buttons editor: add from presets, edit name, symbol, colour and action, reorder, delete,
// then save the whole deck to the PC with `PUT /api/deck`.

private enum DeckEditorRoute: Hashable {
    case presets
    case newButton(OrbitDeckButton)
    case edit(String)
}

struct DeckEditorView: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject var store: OrbitDeckStore
    var startsWithPresets = false

    @ObservedObject private var proStore = OrbitProStore.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @State private var draft: [OrbitDeckButton] = []
    @State private var original: [OrbitDeckButton] = []
    @State private var path: [DeckEditorRoute] = []
    @State private var editMode: EditMode = .inactive
    @State private var saveError: String?
    @State private var showsPaywall = false
    @State private var confirmDiscard = false
    @State private var didLoad = false

    private var hasChanges: Bool { draft != original }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.isDemo {
                    Section {
                        Label("Demo mode: changes last until you leave Buttons, and nothing is sent to a PC.", systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .orbitRow(tint: theme.accent)
                }

                Section {
                    if draft.isEmpty {
                        Text("No buttons yet. Tap Add a Button to start with Discord mute, a clip shortcut, OBS or your own shortcut.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(draft.enumerated()), id: \.element.id) { index, button in
                        NavigationLink(value: DeckEditorRoute.edit(button.id)) {
                            DeckButtonRow(button: button, locked: !proStore.isProUnlocked && !OrbitDeckLimits.isIncludedForFree(index: index))
                        }
                    }
                    .onMove { draft.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { draft.remove(atOffsets: $0) }
                } header: {
                    HStack {
                        Text("Your buttons")
                        Spacer()
                        if draft.count > 1 {
                            Button(editMode.isEditing ? "Done" : "Reorder") {
                                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                            }
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                        }
                    }
                } footer: {
                    Text(proStore.isProUnlocked
                         ? "Swipe left to delete. The order here is the order on every device, the widget and Control Center."
                         : "Swipe left to delete. The first \(OrbitDeckLimits.freeButtons) buttons are free; buttons after them need Orbit Pro.")
                }
                .orbitRow()

                Section {
                    Button {
                        addButton()
                    } label: {
                        Label("Add a Button", systemImage: "plus.circle.fill")
                            .font(.body.weight(.semibold))
                    }
                    .disabled(draft.count >= OrbitDeckLimits.maxButtons)
                } footer: {
                    if draft.count >= OrbitDeckLimits.maxButtons {
                        Text("You have the most buttons a PC can keep (\(OrbitDeckLimits.maxButtons)).")
                    } else if !proStore.isProUnlocked {
                        Text("\(min(draft.count, OrbitDeckLimits.freeButtons)) of \(OrbitDeckLimits.freeButtons) free buttons used. Orbit Pro allows up to \(OrbitDeckLimits.maxButtons).")
                    }
                }
                .orbitRow()

                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .orbitRow(tint: .orange)
                }
            }
            .environment(\.editMode, $editMode)
            .orbitListChrome(isOnline: vm.metrics.isOnline || vm.isDemoMode)
            .navigationTitle("Edit Buttons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(!hasChanges)
                    }
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .navigationDestination(for: DeckEditorRoute.self) { route in
                destination(route)
            }
        }
        .interactiveDismissDisabled(hasChanges || store.isSaving)
        .sheet(isPresented: $showsPaywall) { OrbitProPaywallView() }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            draft = store.deck.buttons
            original = store.deck.buttons
            if startsWithPresets, OrbitDeckLimits.canAddButton(existingCount: draft.count, isPro: proStore.isProUnlocked) {
                path = [.presets]
            }
        }
        .orbitAppearance()
    }

    @ViewBuilder
    private func destination(_ route: DeckEditorRoute) -> some View {
        switch route {
        case .presets:
            DeckPresetPicker(store: store) { button in
                path.append(.newButton(button))
            }
        case .newButton(let button):
            DeckButtonEditor(vm: vm, store: store, initial: button, isNew: true) { result in
                draft.append(result)
                saveError = nil
                path.removeAll()
            }
        case .edit(let id):
            if let button = draft.first(where: { $0.id == id }) {
                DeckButtonEditor(vm: vm, store: store, initial: button, isNew: false) { result in
                    if let index = draft.firstIndex(where: { $0.id == id }) { draft[index] = result }
                    saveError = nil
                    path.removeAll()
                } onDelete: {
                    draft.removeAll { $0.id == id }
                    path.removeAll()
                }
            } else {
                OrbitEmptyState(icon: "questionmark.square.dashed", title: "Button removed", message: "This button is no longer in the list.")
            }
        }
    }

    private func addButton() {
        guard draft.count < OrbitDeckLimits.maxButtons else { return }
        guard OrbitDeckLimits.canAddButton(existingCount: draft.count, isPro: proStore.isProUnlocked) else {
            OrbitHaptics.warning()
            showsPaywall = true
            return
        }
        path.append(.presets)
    }

    private func save() {
        var buttons = draft
        for index in buttons.indices {
            buttons[index].title = buttons[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
            buttons[index].normalizeConfirmation()
        }
        if let broken = buttons.first(where: { $0.validationProblem() != nil }), let problem = broken.validationProblem() {
            saveError = "Fix “\(broken.displayTitle)”: \(problem)"
            OrbitHaptics.error()
            return
        }
        saveError = nil
        Task {
            do {
                try await store.save(buttons)
                OrbitHaptics.success()
                store.show(buttons.count == 1 ? "Saved 1 button" : "Saved \(buttons.count) buttons", kind: .success)
                dismiss()
            } catch {
                saveError = error.localizedDescription
                OrbitHaptics.error()
            }
        }
    }
}

// MARK: - Rows and previews

private struct DeckButtonRow: View {
    let button: OrbitDeckButton
    var locked = false

    var body: some View {
        HStack(spacing: 12) {
            DeckSymbolBadge(symbol: button.symbol, color: button.color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(button.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(button.action.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if locked {
                Image(systemName: "lock.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Needs Orbit Pro")
            } else if button.needsConfirmation {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Asks before running")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DeckSymbolBadge: View {
    let symbol: String
    let color: String
    var size: CGFloat = 36

    var body: some View {
        let tint = OrbitDeckColor.color(color)
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [tint, tint.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.black.opacity(0.82))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Presets

private struct DeckPreset: Identifiable {
    let id: String
    let name: String
    let detail: String
    let button: () -> OrbitDeckButton

    init(_ id: String, _ name: String, detail: String, title: String? = nil, symbol: String, color: String, action: OrbitDeckAction) {
        self.id = id
        self.name = name
        self.detail = detail
        let title = title ?? name
        button = { OrbitDeckButton(title: title, symbol: symbol, color: color, action: action) }
    }

    var symbol: String { button().symbol }
    var color: String { button().color }
}

private enum DeckPresets {
    static let voice: [DeckPreset] = [
        DeckPreset("discord-mute", "Discord mute", detail: "Ctrl+Shift+M", title: "Mute Discord", symbol: "mic.slash.fill", color: "#5865F2", action: .hotkey(["ctrl", "shift", "m"])),
        DeckPreset("discord-deafen", "Discord deafen", detail: "Ctrl+Shift+D", title: "Deafen Discord", symbol: "headphones", color: "#5865F2", action: .hotkey(["ctrl", "shift", "d"]))
    ]
    static let clips: [DeckPreset] = [
        DeckPreset("gamebar-clip", "Xbox Game Bar clip", detail: "Win+Alt+G · records the last 30 seconds", title: "Game Bar clip", symbol: "film", color: "#30D158", action: .hotkey(["win", "alt", "g"])),
        DeckPreset("nvidia-clip", "NVIDIA instant replay", detail: "Alt+F10 · NVIDIA App or GeForce Experience", title: "NVIDIA clip", symbol: "film.stack", color: "#76B900", action: .hotkey(["alt", "f10"])),
        DeckPreset("amd-clip", "AMD instant replay", detail: "Ctrl+Shift+S · AMD Software", title: "AMD clip", symbol: "film", color: "#ED1C24", action: .hotkey(["ctrl", "shift", "s"])),
        DeckPreset("screenshot", "Screenshot", detail: "Win+Print Screen · saved to Pictures", symbol: "camera.viewfinder", color: "#40C8E0", action: .system("screenshot"))
    ]
    static let obs: [DeckPreset] = [
        DeckPreset("obs-record", "Record", detail: "Starts or stops recording", symbol: "record.circle", color: "#FF453A", action: .obs("ToggleRecord")),
        DeckPreset("obs-stream", "Go live", detail: "Starts or stops streaming", symbol: "dot.radiowaves.left.and.right", color: "#BF5AF2", action: .obs("ToggleStream")),
        DeckPreset("obs-replay", "Save replay", detail: "Saves the replay buffer", symbol: "clock.arrow.circlepath", color: "#FF9F0A", action: .obs("SaveReplayBuffer")),
        DeckPreset("obs-scene", "Switch scene", detail: "Pick one of your OBS scenes", symbol: "rectangle.on.rectangle", color: "#64D2FF", action: .obs("SetCurrentProgramScene", ["sceneName": .string("")]))
    ]
    static let windows: [DeckPreset] = [
        DeckPreset("task-manager", "Task Manager", detail: "Ctrl+Shift+Esc", symbol: "list.bullet.rectangle.fill", color: "#30D158", action: .hotkey(["ctrl", "shift", "esc"])),
        DeckPreset("lock", "Lock PC", detail: "Locks Windows", symbol: "lock.fill", color: "#8E8E93", action: .system("lock")),
        DeckPreset("show-desktop", "Show desktop", detail: "Win+D", symbol: "menubar.dock.rectangle", color: "#0A84FF", action: .system("show_desktop")),
        DeckPreset("task-view", "Task view", detail: "Win+Tab", symbol: "rectangle.3.group", color: "#5E5CE6", action: .system("task_view"))
    ]
    static let media: [DeckPreset] = OrbitDeckCatalog.mediaActions.map {
        DeckPreset("media-\($0.id)", $0.title, detail: "Media key", symbol: $0.symbol, color: "#FF375F", action: .media($0.id))
    }
    static let power: [DeckPreset] = [
        DeckPreset("power-sleep", "Sleep", detail: "Asks before running", title: "Sleep PC", symbol: "moon.zzz.fill", color: "#FFD60A", action: .system("sleep")),
        DeckPreset("power-restart", "Restart", detail: "Asks before running", title: "Restart PC", symbol: "arrow.clockwise.circle.fill", color: "#FF9F0A", action: .system("restart")),
        DeckPreset("power-shutdown", "Shut down", detail: "Asks before running", title: "Shut down PC", symbol: "power", color: "#FF453A", action: .system("shutdown"))
    ]
    static let custom: [DeckPreset] = [
        DeckPreset("custom-hotkey", "Custom shortcut", detail: "Any key with Ctrl, Shift, Alt or Win", title: "Shortcut", symbol: "command", color: "#64D2FF", action: .hotkey([])),
        DeckPreset("open-url", "Open a link", detail: "Websites and steam://, spotify:, discord:// links", title: "Open link", symbol: "globe", color: "#0A84FF", action: OrbitDeckAction(.openURL("https://"))),
        DeckPreset("launch-app", "Open an app", detail: "Any app from the PC's Start menu", title: "Open app", symbol: "square.grid.2x2.fill", color: "#5E5CE6", action: OrbitDeckAction(.launch(appID: ""))),
        DeckPreset("type-text", "Type text", detail: "Types a phrase as if you typed it", symbol: "keyboard", color: "#66D4CF", action: OrbitDeckAction(.text(""))),
        DeckPreset("sequence", "Sequence", detail: "Up to \(OrbitDeckLimits.maxSequenceSteps) steps in a row", symbol: "list.number", color: "#BF5AF2",
                   action: OrbitDeckAction(.sequence(steps: [], delayMs: OrbitDeckLimits.defaultSequenceDelayMs)))
    ]
}

private struct DeckPresetPicker: View {
    @ObservedObject var store: OrbitDeckStore
    var onPick: (OrbitDeckButton) -> Void

    var body: some View {
        List {
            section("Voice chat", icon: "bubble.left.and.bubble.right.fill", presets: DeckPresets.voice)
            section("Clips & screenshots", icon: "film.fill", presets: DeckPresets.clips)
            obsSection
            section("Windows", icon: "macwindow", presets: DeckPresets.windows)
            section("Media", icon: "music.note", presets: DeckPresets.media)
            section("Power", icon: "power", presets: DeckPresets.power)
            section("Make your own", icon: "wand.and.stars", presets: DeckPresets.custom)
        }
        .orbitListChrome()
        .navigationTitle("Add a Button")
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.supportsOBS && store.obs == nil { await store.loadOBS() } }
    }

    private func section(_ title: String, icon: String, presets: [DeckPreset], disabled: Bool = false) -> some View {
        Section {
            ForEach(presets) { preset in
                Button {
                    OrbitHaptics.selection()
                    onPick(preset.button())
                } label: {
                    HStack(spacing: 12) {
                        DeckSymbolBadge(symbol: preset.symbol, color: preset.color, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(preset.detail)
                                .font(.caption)
                                .foregroundStyle(Color(.secondaryLabel))
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .disabled(disabled)
            }
        } header: {
            Label(title, systemImage: icon)
        }
        .orbitRow()
    }

    @ViewBuilder
    private var obsSection: some View {
        if store.supportsOBS {
            Section {
                ForEach(DeckPresets.obs) { preset in
                    Button {
                        OrbitHaptics.selection()
                        onPick(preset.button())
                    } label: {
                        HStack(spacing: 12) {
                            DeckSymbolBadge(symbol: preset.symbol, color: preset.color, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                Text(preset.detail).font(.caption).foregroundStyle(Color(.secondaryLabel))
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Label("OBS Studio", systemImage: "record.circle")
            } footer: {
                if store.isLoadingOBS {
                    Text("Checking OBS on the PC…")
                } else if let obs = store.obs {
                    Text(obs.explanation)
                } else if let error = store.obsError {
                    Text(error)
                }
            }
            .orbitRow()
        } else {
            Section {
                Label("OBS buttons need a newer Orbit agent on the PC.", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("OBS Studio", systemImage: "record.circle")
            }
            .orbitRow()
        }
    }
}

// MARK: - Button editor

private struct DeckButtonEditor: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject var store: OrbitDeckStore
    let initial: OrbitDeckButton
    let isNew: Bool
    var onCommit: (OrbitDeckButton) -> Void
    var onDelete: (() -> Void)? = nil

    @State private var button: OrbitDeckButton
    @State private var confirmDelete = false

    init(vm: OrbitViewModel, store: OrbitDeckStore, initial: OrbitDeckButton, isNew: Bool,
         onCommit: @escaping (OrbitDeckButton) -> Void, onDelete: (() -> Void)? = nil) {
        self.vm = vm
        self.store = store
        self.initial = initial
        self.isNew = isNew
        self.onCommit = onCommit
        self.onDelete = onDelete
        _button = State(initialValue: initial)
    }

    private var problem: String? { button.validationProblem() }

    var body: some View {
        Form {
            Section {
                preview
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    .listRowBackground(Color.clear)
            }

            Section {
                TextField("Name", text: $button.title)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .onChange(of: button.title) { _, value in
                        if value.count > OrbitDeckLimits.maxTitleLength { button.title = String(value.prefix(OrbitDeckLimits.maxTitleLength)) }
                    }
            } header: {
                Text("Name")
            } footer: {
                Text("\(button.title.count)/\(OrbitDeckLimits.maxTitleLength)")
            }
            .orbitRow()

            Section("Look") {
                NavigationLink {
                    DeckSymbolPicker(selection: $button.symbol, color: button.color)
                } label: {
                    HStack {
                        Text("Symbol")
                        Spacer()
                        DeckSymbolBadge(symbol: button.symbol, color: button.color, size: 30)
                    }
                }
                DeckColorPicker(selection: $button.color)
            }
            .orbitRow()

            DeckActionEditor(vm: vm, store: store, action: $button.action, allowsSequence: true, allowsPower: true) { suggestion in
                let current = button.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if current.isEmpty || current == initial.title { button.title = String(suggestion.prefix(OrbitDeckLimits.maxTitleLength)) }
            }

            Section {
                Toggle("Ask before running", isOn: Binding(
                    get: { button.needsConfirmation },
                    set: { button.confirm = $0 ? true : nil; button.normalizeConfirmation() }
                ))
                .disabled(button.action.isPowerAction)
            } footer: {
                Text(button.action.isPowerAction
                     ? "Sleep, restart and shut down always ask first. From the widget, Orbit opens to ask."
                     : "Orbit asks “Are you sure?” before running it from the app, Siri or Control Center.")
            }
            .orbitRow()

            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .orbitRow(tint: .orange)
            }

            if !isNew, let onDelete {
                Section {
                    Button("Delete Button", role: .destructive) { confirmDelete = true }
                }
                .orbitRow()
                .confirmationDialog("Delete “\(button.displayTitle)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete Button", role: .destructive) { onDelete() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("It disappears from every device after you save.")
                }
            }
        }
        .orbitListChrome()
        .navigationTitle(isNew ? "New Button" : "Edit Button")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Done") {
                    var result = button
                    result.title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    result.normalizeConfirmation()
                    OrbitHaptics.tap()
                    onCommit(result)
                }
                .fontWeight(.semibold)
                .disabled(problem != nil)
            }
        }
    }

    private var preview: some View {
        let tint = OrbitDeckColor.color(button.color)
        return HStack(spacing: 14) {
            DeckSymbolBadge(symbol: button.symbol, color: button.color, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(button.displayTitle)
                    .font(.headline.weight(.bold))
                    .lineLimit(2)
                Text(button.action.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 22, tint: tint)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Action editor

private enum DeckActionType: String, CaseIterable, Identifiable {
    case hotkey, text, openUrl, launch, system, media, obs, sequence
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hotkey: return "Keyboard shortcut"
        case .text: return "Type text"
        case .openUrl: return "Open a link"
        case .launch: return "Open an app"
        case .system: return "Windows action"
        case .media: return "Media key"
        case .obs: return "OBS Studio"
        case .sequence: return "Sequence"
        }
    }

    var defaultAction: OrbitDeckAction {
        switch self {
        case .hotkey: return .hotkey([])
        case .text: return OrbitDeckAction(.text(""))
        case .openUrl: return OrbitDeckAction(.openURL("https://"))
        case .launch: return OrbitDeckAction(.launch(appID: ""))
        case .system: return .system("lock")
        case .media: return .media("playpause")
        case .obs: return .obs("ToggleRecord")
        case .sequence: return OrbitDeckAction(.sequence(steps: [], delayMs: OrbitDeckLimits.defaultSequenceDelayMs))
        }
    }
}

/// The sections that edit one action. Used for buttons and for the steps of a sequence.
private struct DeckActionEditor: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject var store: OrbitDeckStore
    @Binding var action: OrbitDeckAction
    var allowsSequence: Bool
    var allowsPower: Bool
    /// Offers a better name, for example the app's name after choosing an app.
    var suggestTitle: (String) -> Void = { _ in }

    private var types: [DeckActionType] {
        DeckActionType.allCases.filter { (allowsSequence || $0 != .sequence) && (store.supportsOBS || $0 != .obs || action.type == "obs") }
    }

    private var currentType: DeckActionType? { DeckActionType(rawValue: action.type) }

    var body: some View {
        Section {
            Picker("Action", selection: Binding(
                get: { currentType?.rawValue ?? "" },
                set: { value in
                    guard let type = DeckActionType(rawValue: value), type != currentType else { return }
                    OrbitHaptics.selection()
                    action = type.defaultAction
                }
            )) {
                if currentType == nil { Text("Newer action").tag("") }
                ForEach(types) { type in Text(type.title).tag(type.rawValue) }
            }
        } header: {
            Text("What it does")
        }
        .orbitRow()

        switch action.kind {
        case .hotkey(let keys): hotkeyEditor(keys)
        case .text(let text): textEditor(text)
        case .openURL(let url): urlEditor(url)
        case .launch(let appID): launchEditor(appID)
        case .system(let name): systemEditor(name)
        case .media(let name): mediaEditor(name)
        case .obs(let request, let data): obsEditor(request, data)
        case .sequence(let steps, let delayMs): sequenceEditor(steps, delayMs)
        case .unsupported(let type):
            Section {
                Label("This action\(type.isEmpty ? "" : " (“\(type)”)") was made by a newer version of Orbit. You can rename, recolour, reorder or delete the button, or choose a new action above.",
                      systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .orbitRow()
        }
    }

    // MARK: Shortcut

    private func hotkeyEditor(_ keys: [String]) -> some View {
        let lowered = keys.map { $0.lowercased() }
        let mainKeys = lowered.filter { !OrbitDeckKeys.isModifier($0) }
        return Section {
            HStack(spacing: 8) {
                ForEach(OrbitDeckKeys.modifiers, id: \.self) { modifier in
                    let isOn = lowered.contains(modifier)
                    Button {
                        OrbitHaptics.selection()
                        var updated = lowered.filter { $0 != modifier }
                        if !isOn { updated.append(modifier) }
                        action = .hotkey(OrbitDeckKeys.ordered(updated))
                    } label: {
                        Text(OrbitDeckKeys.label(modifier))
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .foregroundStyle(isOn ? Color.black.opacity(0.85) : .white)
                            .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.white.opacity(0.08)),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(OrbitDeckKeys.label(modifier))
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            Picker("Key", selection: Binding(
                get: { mainKeys.first ?? "" },
                set: { key in
                    let modifiers = lowered.filter(OrbitDeckKeys.isModifier)
                    action = .hotkey(OrbitDeckKeys.ordered(modifiers + (key.isEmpty ? [] : [key])))
                }
            )) {
                Text("None").tag("")
                ForEach(OrbitDeckKeys.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.keys, id: \.self) { key in
                            Text(OrbitDeckKeys.pickerLabel(key)).tag(key)
                        }
                    }
                }
            }
            .pickerStyle(.navigationLink)
            LabeledContent("Presses", value: keys.isEmpty ? "—" : OrbitDeckKeys.chordLabel(keys))
        } header: {
            Text("Shortcut")
        } footer: {
            Text(mainKeys.count > 1
                 ? "This shortcut presses several keys; choosing a key replaces them. Games and apps that run as administrator may ignore shortcuts from Orbit."
                 : "Turn on the modifiers, then choose the key. Games and apps that run as administrator may ignore shortcuts from Orbit.")
        }
        .orbitRow()
    }

    // MARK: Text

    private func textEditor(_ text: String) -> some View {
        Section {
            TextField("Text to type", text: Binding(
                get: { text },
                set: { action = OrbitDeckAction(.text(String($0.prefix(OrbitDeckLimits.maxTextLength)))) }
            ), axis: .vertical)
            .lineLimit(3...8)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        } header: {
            Text("Text")
        } footer: {
            Text("Orbit types this on the PC where the cursor is, as if you typed it (\(text.count)/\(OrbitDeckLimits.maxTextLength)). Buttons are saved on the PC, so don't put passwords here.")
        }
        .orbitRow()
    }

    // MARK: Link

    private func urlEditor(_ url: String) -> some View {
        Section {
            TextField("https://example.com", text: Binding(
                get: { url },
                set: { action = OrbitDeckAction(.openURL($0.trimmingCharacters(in: .whitespacesAndNewlines))) }
            ))
            .keyboardType(.URL)
            .textContentType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        } header: {
            Text("Link")
        } footer: {
            Text("Opens on the PC: websites (https://), Steam (steam://rungameid/…), Epic (com.epicgames.launcher://), Spotify (spotify:), Discord (discord://) and Windows settings (ms-settings:).")
        }
        .orbitRow()
    }

    // MARK: App

    private func launchEditor(_ appID: String) -> some View {
        Section {
            NavigationLink {
                DeckAppPicker(vm: vm, store: store, selection: appID) { app in
                    action = OrbitDeckAction(.launch(appID: app.id))
                    suggestTitle(app.name)
                }
            } label: {
                HStack {
                    Text("App")
                    Spacer()
                    Text(appID.isEmpty ? "Choose" : (store.appName(for: appID) ?? "Chosen app"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } header: {
            Text("App")
        } footer: {
            Text("Apps come from the Start menu on the PC.")
        }
        .orbitRow()
        .task { if store.apps == nil && !appID.isEmpty { await store.loadApps() } }
    }

    // MARK: Windows action

    private func systemEditor(_ name: String) -> some View {
        Section {
            Picker("Windows action", selection: Binding(
                get: { name },
                set: { value in
                    action = .system(value)
                    if let title = OrbitDeckCatalog.systemAction(value)?.title { suggestTitle(title) }
                }
            )) {
                ForEach(OrbitDeckCatalog.systemActions.filter { allowsPower || !OrbitDeckCatalog.powerSystemActions.contains($0.id) }) { choice in
                    Label(choice.title, systemImage: choice.symbol).tag(choice.id)
                }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("Windows action")
        } footer: {
            if OrbitDeckCatalog.powerSystemActions.contains(name) {
                Text("Orbit always asks before sleeping, restarting or shutting down the PC.")
            }
        }
        .orbitRow()
    }

    // MARK: Media

    private func mediaEditor(_ name: String) -> some View {
        Section("Media key") {
            Picker("Key", selection: Binding(
                get: { name },
                set: { value in
                    action = .media(value)
                    if let title = OrbitDeckCatalog.mediaAction(value)?.title { suggestTitle(title) }
                }
            )) {
                ForEach(OrbitDeckCatalog.mediaActions) { choice in
                    Label(choice.title, systemImage: choice.symbol).tag(choice.id)
                }
            }
            .pickerStyle(.navigationLink)
        }
        .orbitRow()
    }

    // MARK: OBS

    @ViewBuilder
    private func obsEditor(_ request: String, _ data: [String: OrbitDeckJSON]) -> some View {
        Section {
            Picker("Request", selection: Binding(
                get: { request },
                set: { value in
                    switch value {
                    case "SetCurrentProgramScene": action = .obs(value, ["sceneName": .string(store.obs?.scenes.first ?? "")])
                    case "ToggleInputMute": action = .obs(value, ["inputName": .string("Mic/Aux")])
                    default: action = .obs(value)
                    }
                }
            )) {
                ForEach(OrbitDeckCatalog.obsRequests) { choice in
                    Label(choice.title, systemImage: choice.symbol).tag(choice.id)
                }
            }
            .pickerStyle(.navigationLink)

            if request == "SetCurrentProgramScene" {
                let scene = data["sceneName"]?.stringValue ?? ""
                let scenes = store.obs?.scenes ?? []
                if !scenes.isEmpty {
                    Picker("Scene", selection: Binding(
                        get: { scene },
                        set: { value in
                            action = .obs(request, ["sceneName": .string(value)])
                            suggestTitle(value)
                        }
                    )) {
                        if !scene.isEmpty && !scenes.contains(scene) { Text(scene).tag(scene) }
                        if scene.isEmpty { Text("Choose").tag("") }
                        ForEach(scenes, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                }
                TextField("Scene name", text: Binding(
                    get: { scene },
                    set: { action = .obs(request, ["sceneName": .string($0)]) }
                ))
                .autocorrectionDisabled()
            }
            if request == "ToggleInputMute" {
                TextField("Audio source, for example Mic/Aux", text: Binding(
                    get: { data["inputName"]?.stringValue ?? "" },
                    set: { action = .obs(request, ["inputName": .string($0)]) }
                ))
                .autocorrectionDisabled()
            }
        } header: {
            HStack {
                Text("OBS Studio")
                Spacer()
                if store.isLoadingOBS {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Refresh") { Task { await store.loadOBS() } }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                }
            }
        } footer: {
            if let obs = store.obs {
                Text(obs.explanation)
            } else if let error = store.obsError {
                Text(error)
            } else {
                Text("Orbit talks to OBS through its WebSocket server on the PC. The password stays on the PC.")
            }
        }
        .orbitRow()
        .task { if store.obs == nil { await store.loadOBS() } }
    }

    // MARK: Sequence

    private func sequenceEditor(_ steps: [OrbitDeckAction], _ delayMs: Int) -> some View {
        Section {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                NavigationLink {
                    DeckStepEditor(vm: vm, store: store, draft: DeckStepDraft(index: index, action: step)) { result in
                        commitStep(result, steps: steps, delayMs: delayMs)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.heavy))
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.1), in: Circle())
                        Text(step.summary)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        if step.validationProblem(asStep: true) != nil {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        }
                    }
                }
            }
            .onDelete { offsets in
                var updated = steps
                updated.remove(atOffsets: offsets)
                action = OrbitDeckAction(.sequence(steps: updated, delayMs: delayMs))
            }
            .onMove { from, to in
                var updated = steps
                updated.move(fromOffsets: from, toOffset: to)
                action = OrbitDeckAction(.sequence(steps: updated, delayMs: delayMs))
            }

            if steps.count < OrbitDeckLimits.maxSequenceSteps {
                NavigationLink {
                    DeckStepEditor(vm: vm, store: store, draft: DeckStepDraft(index: nil, action: DeckActionType.hotkey.defaultAction)) { result in
                        commitStep(result, steps: steps, delayMs: delayMs)
                    }
                } label: {
                    Label("Add a Step", systemImage: "plus.circle.fill")
                }
            }

            Picker("Pause between steps", selection: Binding(
                get: { delayMs },
                set: { action = OrbitDeckAction(.sequence(steps: steps, delayMs: $0)) }
            )) {
                ForEach(Self.delays(including: delayMs), id: \.self) { value in
                    Text(value == 0 ? "None" : (value < 1000 ? "\(value) ms" : String(format: "%.1f s", Double(value) / 1000))).tag(value)
                }
            }
        } header: {
            Text("Steps")
        } footer: {
            Text("Runs the steps in order, for example a scene switch, then a shortcut. At most \(OrbitDeckLimits.maxSequenceSteps) steps; sleep, restart and shut down can't be steps.")
        }
        .orbitRow()
    }

    private func commitStep(_ result: DeckStepDraft, steps: [OrbitDeckAction], delayMs: Int) {
        // Re-read the current steps: the list may have changed while the step was open.
        var updated = steps
        if case .sequence(let current, _) = action.kind { updated = current }
        if let index = result.index, updated.indices.contains(index) {
            updated[index] = result.action
        } else {
            updated.append(result.action)
        }
        action = OrbitDeckAction(.sequence(steps: Array(updated.prefix(OrbitDeckLimits.maxSequenceSteps)), delayMs: delayMs))
    }

    private static func delays(including value: Int) -> [Int] {
        var values = [0, 50, 100, 150, 250, 500, 1000, 2000, 5000]
        if !values.contains(value) { values.append(value); values.sort() }
        return values
    }
}

private struct DeckStepDraft {
    let index: Int?
    var action: OrbitDeckAction
}

/// One step of a sequence, pushed from the button editor. Back discards; Add/Done keeps it.
private struct DeckStepEditor: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject var store: OrbitDeckStore
    @State var draft: DeckStepDraft
    var onCommit: (DeckStepDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            DeckActionEditor(vm: vm, store: store, action: $draft.action, allowsSequence: false, allowsPower: false)
            if let problem = draft.action.validationProblem(asStep: true) {
                Section {
                    Label(problem, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .orbitRow(tint: .orange)
            }
        }
        .orbitListChrome()
        .navigationTitle(draft.index == nil ? "New Step" : "Step \((draft.index ?? 0) + 1)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(draft.index == nil ? "Add" : "Done") {
                    OrbitHaptics.tap()
                    onCommit(draft)
                    dismiss()
                }
                .fontWeight(.semibold)
                .disabled(draft.action.validationProblem(asStep: true) != nil)
            }
        }
    }
}

// MARK: - App picker

private struct DeckAppPicker: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject var store: OrbitDeckStore
    let selection: String
    var onPick: (OrbitDeckApp) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [OrbitDeckApp] {
        let apps = store.apps ?? []
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if store.isLoadingApps && store.apps == nil {
                HStack { ProgressView(); Text("Loading apps from the PC…").font(.subheadline) }
                    .orbitRow()
            } else if let error = store.appsError, store.apps == nil {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Try Again") { Task { await store.loadApps() } }
                }
                .orbitRow(tint: .orange)
            } else if filtered.isEmpty {
                Text(search.isEmpty ? "No apps were found in the PC's Start menu." : "No app matches “\(search)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .orbitRow()
            } else {
                Section {
                    ForEach(filtered) { app in
                        Button {
                            OrbitHaptics.selection()
                            onPick(app)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                OrbitAppIconView(store: vm.appIcons, iconID: app.iconID, size: 32) {
                                    OrbitIconBadge(systemName: "app.fill", tint: .indigo, size: 32)
                                }
                                Text(app.name)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer()
                                if app.id == selection {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("\(filtered.count) app\(filtered.count == 1 ? "" : "s") from the Start menu")
                }
                .orbitRow()
            }
        }
        .searchable(text: $search, prompt: "Search apps")
        .orbitListChrome()
        .navigationTitle("Choose App")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.loadApps() }
        .task { if store.apps == nil { await store.loadApps() } }
    }
}

// MARK: - Symbol and colour

private struct DeckSymbolPicker: View {
    @Binding var selection: String
    let color: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private static let symbols: [String] = [
        "mic.slash.fill", "mic.fill", "headphones", "speaker.slash.fill", "speaker.wave.3.fill", "speaker.wave.1.fill",
        "playpause.fill", "play.fill", "pause.fill", "forward.fill", "backward.fill", "music.note",
        "record.circle", "dot.radiowaves.left.and.right", "video.fill", "film", "film.stack", "camera.fill",
        "camera.viewfinder", "clock.arrow.circlepath", "rectangle.on.rectangle", "rectangle.3.group", "macwindow", "menubar.dock.rectangle",
        "gamecontroller.fill", "keyboard", "command", "option", "text.cursor", "character.cursor.ibeam",
        "lock.fill", "moon.zzz.fill", "power", "arrow.clockwise.circle.fill", "display", "display.2",
        "desktopcomputer", "list.bullet.rectangle.fill", "square.grid.2x2.fill", "square.grid.3x2.fill", "list.number", "wand.and.stars",
        "globe", "link", "safari", "bubble.left.fill", "message.fill", "phone.fill",
        "bolt.fill", "flame.fill", "star.fill", "heart.fill", "flag.fill", "bell.fill",
        "sparkles", "lightbulb.fill", "sun.max.fill", "eye.fill", "eye.slash.fill", "hand.raised.fill",
        "hand.thumbsup.fill", "trophy.fill", "crown.fill", "timer", "stopwatch.fill", "folder.fill",
        "doc.fill", "trash.fill", "square.and.arrow.up", "arrow.up.left.and.arrow.down.right", "xmark.square.fill", "checkmark.circle.fill",
        "cpu.fill", "memorychip.fill", "fanblades.fill", "thermometer.medium", "wifi", "antenna.radiowaves.left.and.right",
        "1.circle.fill", "2.circle.fill", "3.circle.fill", "4.circle.fill", "house.fill", "cart.fill"
    ].filter { UIImage(systemName: $0) != nil }

    private var filtered: [String] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? Self.symbols : Self.symbols.filter { $0.contains(query) }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 12)], spacing: 12) {
                ForEach(filtered, id: \.self) { symbol in
                    Button {
                        OrbitHaptics.selection()
                        selection = symbol
                        dismiss()
                    } label: {
                        DeckSymbolBadge(symbol: symbol, color: symbol == selection ? color : "#3A3A3C", size: 52)
                            .overlay(Circle().strokeBorder(symbol == selection ? Color.white : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
                    .accessibilityAddTraits(symbol == selection ? .isSelected : [])
                }
            }
            .padding(18)
        }
        .background(OrbitAmbientBackground(isOnline: true))
        .searchable(text: $search, prompt: "Search symbols")
        .navigationTitle("Symbol")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DeckColorPicker: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Colour")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 10)], spacing: 10) {
                ForEach(OrbitDeckColor.palette, id: \.self) { hex in
                    Button {
                        OrbitHaptics.selection()
                        selection = hex
                    } label: {
                        Circle()
                            .fill(OrbitDeckColor.color(hex))
                            .frame(width: 32, height: 32)
                            .overlay(Circle().strokeBorder(.white, lineWidth: selection == hex ? 2.5 : 0))
                            .overlay {
                                if selection == hex {
                                    Image(systemName: "checkmark").font(.caption.weight(.heavy)).foregroundStyle(.black.opacity(0.8))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour \(hex)")
                    .accessibilityAddTraits(selection == hex ? .isSelected : [])
                }
            }
            ColorPicker("Custom colour", selection: Binding(
                get: { OrbitDeckColor.color(selection) },
                set: { color in
                    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                    guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
                    selection = OrbitDeckColor.hex(red: Double(red), green: Double(green), blue: Double(blue))
                }
            ), supportsOpacity: false)
        }
        .padding(.vertical, 4)
    }
}
