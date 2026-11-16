import SwiftUI

/// Win+P from the iPhone: PC screen only, Duplicate, Extend or Second screen only, plus the displays
/// Windows sees. The PC side is `orbit_display_mode.py` (Shared/OrbitPCDisplayAudio.swift).
struct DisplayModeView: View {
    @ObservedObject var vm: OrbitViewModel
    @StateObject private var model = OrbitDisplayModeController()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.orbitTheme) private var theme

    private var canUsePC: Bool { !vm.isDemoMode && vm.metrics.isOnline }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    OrbitIconBadge(systemName: "display.2", tint: .teal, size: 40, filled: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Display Mode").font(.headline.weight(.bold))
                        Text(headerSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if model.isLoading || model.switching != nil { ProgressView().tint(theme.accent) }
                }
                .padding(.vertical, 2)
                if vm.isDemoMode {
                    Label("Connect a PC to change its displays", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .orbitRow(tint: .teal)

            if let error = model.error {
                Section { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                    .orbitRow(tint: .orange)
            } else if let message = model.message {
                Section { Label(message, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.mint) }
                    .orbitRow(tint: .mint)
            }

            if model.olderAgent {
                Section {
                    OrbitEmptyState(icon: "arrow.down.circle", title: "Update the PC Companion",
                                    message: "Changing the display mode needs PC Companion 4.6.0 or later on the PC.", tint: .teal)
                }
                .orbitRow()
            } else if let status = model.status, !status.available {
                Section {
                    OrbitEmptyState(icon: "display.trianglebadge.exclamationmark", title: "Display mode unavailable",
                                    message: status.reason ?? "Windows didn't report its displays.", tint: .orange)
                }
                .orbitRow()
            } else {
                Section {
                    ForEach(OrbitDisplayMode.allCases) { mode in modeRow(mode) }
                } header: {
                    Text("Project")
                } footer: {
                    Text("Like Win+P on the PC. Windows remembers each mode's layout, so resolutions and positions come back as you left them.")
                }
                .orbitRow()

                if let displays = model.status?.displays, !displays.isEmpty {
                    Section("Displays") {
                        ForEach(Array(displays.enumerated()), id: \.offset) { _, display in displayRow(display) }
                    }
                    .orbitRow()
                }
            }
        }
        .orbitListChrome(isOnline: vm.metrics.isOnline)
        .navigationTitle("Display Mode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await model.refresh(vm.companionClient) } } label: {
                    if model.isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(model.isLoading || model.switching != nil || !canUsePC)
                .accessibilityLabel("Refresh displays")
            }
        }
        .refreshable { if canUsePC { await model.refresh(vm.companionClient) } }
        // Another PC or demo mode turning on or off starts over. Displays change rarely (a cable,
        // a TV turned on): a slow poll keeps the list honest.
        .task(id: "\(vm.connectionID)|\(vm.isDemoMode)") {
            model.reset()
            while !Task.isCancelled {
                if vm.isDemoMode { model.showDemo() }
                else if scenePhase == .active, vm.metrics.isOnline { await model.refresh(vm.companionClient) }
                do { try await Task.sleep(for: .seconds(8)) } catch { break }
            }
        }
    }

    private var headerSubtitle: String {
        guard let status = model.status, status.available else { return "PC screen only, Duplicate, Extend, Second screen only" }
        let count = status.displays.count
        let displays = count == 1 ? "1 display connected" : "\(count) displays connected"
        guard let mode = status.currentMode else { return "\(displays) · custom layout" }
        return "\(displays) · \(mode.title)"
    }

    private func modeRow(_ mode: OrbitDisplayMode) -> some View {
        let current = model.status?.currentMode == mode
        let refusal = model.status?.refusal(for: mode)
        let tint: Color = current ? theme.accent : .teal
        return Button {
            OrbitHaptics.tap()
            if vm.isDemoMode { model.selectDemo(mode); return }
            Task { await model.select(mode, vm.companionClient) }
        } label: {
            HStack(spacing: 12) {
                OrbitIconBadge(systemName: mode.symbol, tint: tint, size: 36, filled: current)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(refusal ?? mode.subtitle).font(.caption2)
                        .foregroundStyle(refusal == nil ? Color.secondary : Color.orange)
                        .lineLimit(2)
                }
                Spacer()
                if model.switching == mode {
                    ProgressView().controlSize(.small)
                } else if current {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(theme.accent)
                        .accessibilityLabel("Current mode")
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.orbitPressable)
        .disabled(model.switching != nil || refusal != nil || (!canUsePC && !vm.isDemoMode) || model.status == nil)
        .opacity(refusal != nil ? 0.55 : 1)
        .accessibilityHint(mode.subtitle)
    }

    private func displayRow(_ display: OrbitPCDisplay) -> some View {
        HStack(spacing: 12) {
            OrbitIconBadge(systemName: display.symbol, tint: display.active ? .mint : .secondary, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(display.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(display.detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(display.active ? Color.mint : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                .accessibilityLabel(display.active ? "On" : "Off")
        }
        .padding(.vertical, 2)
    }
}
