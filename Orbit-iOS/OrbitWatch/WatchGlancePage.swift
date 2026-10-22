import SwiftUI
import WatchKit

/// The first page: the mark, the PC's name, one sentence about how it is doing and the two
/// readings that matter. When something stands in the way (asleep, locked, not set up), the
/// one action that fixes it takes the readings' place.
struct WatchGlancePage: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @State private var showsPCs = false
    @State private var showsUnlock = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var readingSize: CGFloat = WatchScreen.isCompact ? 25 : 30

    var body: some View {
        let status = WatchPCStatus(vm: vm)
        let telemetry = vm.telemetry
        ScrollView {
            VStack(spacing: 0) {
                OrbitMark(status: status.markStatus, size: WatchScreen.isCompact ? 28 : 38)
                    .padding(.bottom, WatchScreen.isCompact ? 4 : 6)
                header(status, telemetry)
                details(status, telemetry)
                    .padding(.top, WatchScreen.isCompact ? 8 : 10)
            }
            .frame(maxWidth: .infinity)
            .watchAnimation(value: status)
            .tint(vm.tint)
        }
        .watchDebugScrollAnchor()
        .containerBackground(pageTint(status, telemetry), for: .tabView)
        .toolbar {
            if status != .setup {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showsPCs = true
                    } label: {
                        Image(systemName: "desktopcomputer")
                    }
                    .accessibilityLabel("Your PCs")
                }
            }
        }
        .sheet(isPresented: $showsPCs) { WatchPCListSheet(vm: vm) }
        .sheet(isPresented: $showsUnlock) { WatchUnlockSheet(vm: vm) }
        #if DEBUG
        .onAppear {
            if WatchDebugOptions.sheet == "pcs" { showsPCs = true }
        }
        #endif
    }

    // MARK: Header

    private func header(_ status: WatchPCStatus, _ telemetry: WatchTelemetry) -> some View {
        VStack(spacing: 1) {
            if status != .setup {
                Text(vm.pcName)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(headline(status, telemetry))
                .font(WatchScreen.isCompact ? .headline : .title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .orbitLiveNumber()
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func headline(_ status: WatchPCStatus, _ telemetry: WatchTelemetry) -> String {
        guard status == .online else { return status.title }
        guard vm.telemetryAvailable else { return "Online" }
        // "Processor is hot · 93°": keep "hot · 93°" together when the line has to wrap.
        return telemetry.headline.replacingOccurrences(of: " · ", with: "\u{00A0}·\u{00A0}")
    }

    // MARK: Below the header

    @ViewBuilder
    private func details(_ status: WatchPCStatus, _ telemetry: WatchTelemetry) -> some View {
        switch status {
        case .online:
            if vm.telemetryAvailable {
                readings(telemetry)
            } else {
                WatchHint("Waiting for the first readings from the PC.")
            }
        case .locked:
            VStack(spacing: 10) {
                WatchHint("Windows is waiting for your password.")
                Button {
                    showsUnlock = true
                } label: {
                    WatchButtonLabel(title: "Unlock", systemImage: "lock.open", isWorking: vm.isUnlocking)
                }
                .watchButton(prominent: true)
                .disabled(vm.isUnlocking)
                .handGestureShortcut(.primaryAction)
                WatchFeedbackLine(vm: vm)
            }
        case .offline:
            VStack(spacing: 10) {
                WatchHint(offlineHint)
                Button {
                    Task { await vm.wakePC() }
                } label: {
                    WatchButtonLabel(title: "Wake PC", systemImage: "power")
                }
                .watchButton(prominent: true)
                .disabled(!vm.isPhoneReachable)
                .handGestureShortcut(.primaryAction)
                WatchFeedbackLine(vm: vm)
            }
        case .waking:
            WatchHint("The wake signal is on its way. This takes up to a minute.")
        case .connecting:
            // The orbiting satellite says it; this lasts a few seconds at most.
            EmptyView()
        case .setup:
            VStack(spacing: 10) {
                WatchHint("Pair your PC in Orbit on iPhone. It shows up here when both apps are open.")
                Button {
                    vm.requestSyncFromPhone()
                } label: {
                    WatchButtonLabel(title: "Sync with iPhone", systemImage: "arrow.triangle.2.circlepath")
                }
                .watchButton(prominent: true)
                .disabled(!vm.isPhoneReachable)
            }
        }
    }

    private func readings(_ telemetry: WatchTelemetry) -> some View {
        // Side by side; one above the other at accessibility text sizes.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        return layout {
            ForEach(WatchVitals.glance(telemetry), id: \.kind) { vital in
                WatchReadingView(vital: vital, valueSize: readingSize)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var offlineHint: String {
        guard vm.isPhoneReachable else { return "Keep your iPhone nearby to wake it. It sends the signal." }
        guard let seen = vm.lastTelemetryAt else { return "Orbit can't reach it right now." }
        if Calendar.current.isDateInToday(seen) {
            return "Last seen \(seen.formatted(date: .omitted, time: .shortened))"
        }
        return "Last seen \(seen.formatted(.relative(presentation: .named)))"
    }

    /// The page turns red only when a component is hot: the one state worth a color.
    private func pageTint(_ status: WatchPCStatus, _ telemetry: WatchTelemetry) -> AnyShapeStyle {
        if status == .online, vm.telemetryAvailable, telemetry.isHot {
            return AnyShapeStyle(OrbitPalette.critical.opacity(0.55).gradient)
        }
        return AnyShapeStyle(OrbitPalette.canvas)
    }
}

// MARK: - PCs

/// Your PCs from the iPhone, the sync button and the iPhone Lock Screen activity.
struct WatchPCListSheet: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                list
                    .tint(vm.tint)
                    .watchDebugScrollToEnd(proxy)
            }
            .navigationTitle("Your PCs")
            .containerBackground(OrbitPalette.canvas, for: .navigation)
        }
    }

    private var list: some View {
        List {
            Section {
                if vm.savedPCs.isEmpty {
                    Text("PCs you pair in Orbit on iPhone appear here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(vm.savedPCs) { pc in
                    Button {
                        vm.selectPC(pc)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pc.name)
                                    .lineLimit(2)
                                Text(pc.address)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if pc.id == vm.selectedPCID {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .accessibilityAddTraits(pc.id == vm.selectedPCID ? .isSelected : [])
                }
            }
            Section {
                Button {
                    vm.requestSyncFromPhone()
                } label: {
                    Label("Sync with iPhone", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!vm.isPhoneReachable)
                Toggle(isOn: Binding(get: { vm.isLiveActivityActive }, set: { _ in vm.togglePhoneLiveActivity() })) {
                    Text("Show on iPhone Lock Screen")
                }
                .disabled(!vm.isPhoneReachable)
                .id("end")
            } footer: {
                Text(vm.isPhoneReachable
                     ? "The Lock Screen keeps this PC's readings in view while Orbit runs on iPhone."
                     : "Your iPhone isn't nearby. Sync and the Lock Screen need it.")
            }
        }
    }
}
