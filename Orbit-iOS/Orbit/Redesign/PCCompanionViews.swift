import SwiftUI

// MARK: - Power

/// A pending shutdown, timer or keep-awake on the PC, counting down, with the way to stop it.
struct PCPowerStatus: View {
    @EnvironmentObject var companion: PCCompanion

    var body: some View {
        if let power = companion.power, power.timer != nil || power.keepAwake != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 0) {
                    if let timer = power.timer {
                        row(symbol: symbol(for: timer.action),
                            title: timer.summary(remaining: companion.remaining(timer.remainingSeconds, at: context.date)),
                            detail: timer.requestedBy.map { "Asked from \($0)" },
                            urgent: timer.state == "countdown",
                            button: "Cancel") { Task { await companion.cancelPending() } }
                    }
                    if power.timer != nil && power.keepAwake != nil {
                        Divider().overlay(OrbitPalette.hairline)
                    }
                    if let keep = power.keepAwake {
                        row(symbol: "cup.and.saucer",
                            title: keep.summary(remaining: companion.remaining(keep.remainingSeconds, at: context.date)),
                            detail: nil,
                            urgent: false,
                            button: "Stop") { Task { await companion.stopKeepAwake() } }
                    }
                }
                .orbitSurface(padding: 16, radius: 22)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func symbol(for action: String) -> String {
        switch action {
        case "sleep", "hibernate": return "moon"
        case "restart": return "arrow.clockwise"
        case "signout": return "rectangle.portrait.and.arrow.right"
        case "displayOff": return "display"
        default: return "power"
        }
    }

    private func row(symbol: String, title: String, detail: String?, urgent: Bool, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(urgent ? OrbitPalette.warm : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .orbitLiveNumber()
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(button) {
                OrbitHaptics.press()
                action()
            }
            .orbitGlassButton(prominent: urgent)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Sleep or shut down later, keep the PC awake, choose its power plan, cancel what is pending.
struct PCPowerLaterMenu: View {
    @EnvironmentObject var companion: PCCompanion
    var gameRunning: Bool

    var body: some View {
        if companion.has("power.timer") {
            Section {
                timerMenu("Sleep Later", action: "sleep", symbol: "moon.zzz")
                timerMenu("Shut Down Later", action: "shutdown", symbol: "power.dotted")
                if companion.has("power.keepAwake") {
                    Menu("Keep Awake", systemImage: "cup.and.saucer") {
                        Button("For 1 Hour") { Task { await companion.keepAwake(minutes: 60) } }
                        Button("For 4 Hours") { Task { await companion.keepAwake(minutes: 240) } }
                        Button("Until I Turn It Off") { Task { await companion.keepAwake(minutes: nil) } }
                        if companion.power?.keepAwake != nil {
                            Button("Stop Keeping Awake", role: .destructive) { Task { await companion.stopKeepAwake() } }
                        }
                    }
                }
                if companion.has("power.plans"), let plans = companion.power?.plans, !plans.isEmpty {
                    Menu("Power Plan", systemImage: "gauge.with.dots.needle.67percent") {
                        Picker("Power Plan", selection: Binding(get: { plans.first(where: \.active)?.id ?? "" },
                                                                 set: { id in if let plan = plans.first(where: { $0.id == id }) { Task { await companion.setPlan(plan) } } })) {
                            ForEach(plans) { Text($0.name).tag($0.id) }
                        }
                    }
                }
            }
        }
        if let timer = companion.power?.timer {
            Button("Cancel \(timer.actionTitle)", systemImage: "xmark.circle") { Task { await companion.cancelPending() } }
        }
    }

    private func timerMenu(_ title: String, action: String, symbol: String) -> some View {
        Menu(title, systemImage: symbol) {
            ForEach(OrbitPowerTimerChoice.allCases) { choice in
                Button(choice.title) { Task { await companion.setTimer(choice, action: action) } }
                    .disabled(choice == .gameExits && !gameRunning)
            }
        }
    }
}

// MARK: - Sound

/// The microphone and the default output, under the PC tab's volume.
struct PCSoundExtras: View {
    @EnvironmentObject var companion: PCCompanion

    var body: some View {
        let defaultOutput = companion.outputs.first { $0.isDefault == true }
        if companion.microphone?.available == true || (companion.canSwitchOutput && companion.outputs.count > 1) {
            VStack(spacing: 0) {
                if companion.canSwitchOutput, companion.outputs.count > 1 {
                    Menu {
                        Picker("Output", selection: Binding(get: { defaultOutput?.id ?? "" },
                                                            set: { id in if let output = companion.outputs.first(where: { $0.id == id }) { Task { await companion.makeDefault(output) } } })) {
                            ForEach(companion.outputs) { Text($0.name).tag($0.id) }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "hifispeaker")
                                .foregroundStyle(.secondary)
                                .frame(width: 30)
                            Text("Output")
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Text(defaultOutput?.name ?? "Choose")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.subheadline)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Output, \(defaultOutput?.name ?? "not set")")
                }
                if let microphone = companion.microphone, microphone.available {
                    if companion.canSwitchOutput, companion.outputs.count > 1 { Divider().overlay(OrbitPalette.hairline) }
                    Toggle(isOn: Binding(get: { !microphone.muted }, set: { on in
                        OrbitHaptics.selection()
                        Task { await companion.setMicrophoneMuted(!on) }
                    })) {
                        HStack(spacing: 12) {
                            Image(systemName: microphone.muted ? "mic.slash" : "mic")
                                .foregroundStyle(microphone.muted ? OrbitPalette.warm : .secondary)
                                .frame(width: 30)
                            Text("Microphone")
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 6)
                }
            }
            .orbitSurface(padding: 16, radius: 22)
        }
    }
}

// MARK: - Devices

/// Who may use the PC, with Remove; this iPhone can't remove itself here.
struct PCDevicesView: View {
    @ObservedObject var vm: OrbitViewModel
    @EnvironmentObject var companion: PCCompanion
    @State private var removing: OrbitDevice?

    var body: some View {
        List {
            Section {
                if let error = companion.devicesError {
                    Text(error).foregroundStyle(.secondary)
                } else if companion.devices.isEmpty {
                    Text(companion.isLoadingDevices ? "Reading the list from the PC…" : "No devices.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(companion.devices) { device in
                        row(device)
                    }
                }
            } footer: {
                if companion.devices.contains(where: \.legacy) {
                    Text("Older Orbit apps share one key with the PC. Once every device is paired again, remove them so each device has its own key.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(OrbitPalette.canvas)
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await companion.refreshDevices() }
        .refreshable { await companion.refreshDevices() }
        .confirmationDialog("Remove \(removing.map { $0.legacy ? "older Orbit apps" : $0.name } ?? "this device") from \(vm.selectedPCName)?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { device in
            Button("Remove", role: .destructive) { Task { await companion.revoke(device) } }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text(device.legacy
                 ? "Orbit apps paired before Orbit Companion 5 stop working with this PC until they're paired again."
                 : "\(device.name) can't use this PC until it's paired again.")
        }
    }

    private func row(_ device: OrbitDevice) -> some View {
        HStack(spacing: 14) {
            Image(systemName: device.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.legacy ? "Older Orbit Apps" : device.name)
                        .font(.body.weight(.medium))
                    if device.current {
                        Text("This iPhone")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text([device.kind, device.lastSeen.map { device.current ? "now" : "used \($0.formatted(.relative(presentation: .named)))" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .swipeActions {
            if !device.current {
                Button("Remove", role: .destructive) { removing = device }
            }
        }
        .contextMenu {
            if !device.current {
                Button("Remove…", systemImage: "minus.circle", role: .destructive) { removing = device }
            }
        }
    }
}

// MARK: - Activity

/// What devices did on the PC lately, newest first.
struct PCActivityLogView: View {
    @EnvironmentObject var companion: PCCompanion

    var body: some View {
        List {
            if let error = companion.activityError {
                Text(error).foregroundStyle(.secondary)
            } else if companion.activity.isEmpty {
                Text("Nothing yet. Power, files, sound and other changes made from Orbit appear here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(companion.activity) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: entry.result == "ok" ? "circle.fill" : "exclamationmark.triangle.fill")
                            .font(entry.result == "ok" ? .system(size: 6) : .caption)
                            .foregroundStyle(entry.result == "ok" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(OrbitPalette.warm))
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.summary)
                                .font(.subheadline)
                            Text([entry.deviceName, entry.date?.formatted(.relative(presentation: .named)),
                                  entry.result == "denied" ? "not allowed" : (entry.result == "error" ? "failed" : nil)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(OrbitPalette.canvas)
        .navigationTitle("Activity on the PC")
        .navigationBarTitleDisplayMode(.inline)
        .task { await companion.refreshActivity() }
        .refreshable { await companion.refreshActivity() }
    }
}
