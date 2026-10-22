import MoonlightCore
import SwiftUI

enum TVSettingsRoute: Hashable {
    case pc(String), addPC, pro, acknowledgements
}

/// Settings, in the order people look for things: your PCs, streaming, Orbit Pro, and the
/// fine print. Every page is the tvOS two-column layout.
struct TVSettingsView: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    @ObservedObject var sunshine: MoonlightHostCoordinator
    @ObservedObject private var proStore = OrbitProStore.shared
    @ObservedObject private var streamSettings = MoonlightStreamSettingsStore.shared
    @Environment(\.tvAccent) private var accent
    @State private var path: [TVSettingsRoute] = []
    @State private var showsPairing = false
    @State private var showsQuality = false

    private var state: TVPCState { TVPCState(vm: vm) }

    var body: some View {
        NavigationStack(path: $path) {
            TVSplitPage {
                OrbitMark(status: state == .setup ? .online : state.markStatus, size: 200)
                VStack(spacing: 10) {
                    Text(vm.currentPC == nil && !vm.isDemoMode ? "Orbit" : vm.pcName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(statusLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } content: {
                list
            }
            .navigationDestination(for: TVSettingsRoute.self) { route in
                switch route {
                case .pc(let id): TVPCDetailPage(pcID: id, sunshine: sunshine)
                case .addPC: TVAddPCView { path.removeAll() }
                case .pro: TVProPage()
                case .acknowledgements: TVAcknowledgementsPage()
                }
            }
        }
        .fullScreenCover(isPresented: $showsPairing) {
            TVSunshinePairingView(sunshine: sunshine)
        }
        .fullScreenCover(isPresented: $showsQuality) {
            MoonlightStreamSettingsView(store: streamSettings, accent: accent, hostSupportsHEVC: sunshine.info.map(\.supportsHEVC)) {
                showsQuality = false
            }
            .tvFullScreenPage()
        }
        #if DEBUG
        .task {
            switch TVDebugLaunch.sheet {
            case "addpc": path = [.addPC]
            case "pc": if let pc = vm.currentPC { path = [.pc(pc.id)] }
            case "pro": path = [.pro]
            case "acknowledgements": path = [.acknowledgements]
            case "settings-pairing": showsPairing = true
            default: break
            }
        }
        #endif
    }

    private var list: some View {
        List {
            Section {
                ForEach(vm.savedPCs) { pc in
                    NavigationLink(value: TVSettingsRoute.pc(pc.id)) {
                        HStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pc.name)
                                    .lineLimit(1)
                                Text(pc.address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 16)
                            if pc.id == vm.currentPC?.id && !vm.isDemoMode {
                                Text(state == .online || state == .locked ? "Online" : "In Use")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                NavigationLink(value: vm.canAddNewPC ? TVSettingsRoute.addPC : TVSettingsRoute.pro) {
                    Label("Add PC", systemImage: "plus")
                }
                .tvDebugFocus("row-addpc")
            } header: {
                TVListHeader("PCs")
            } footer: {
                if !vm.canAddNewPC { Text("Orbit Pro lets you save more than one PC.") }
            }

            Section {
                Button {
                    showsPairing = true
                } label: {
                    LabeledContent("Sunshine", value: sunshineStatus)
                        .tvRowLabel()
                }
                .disabled(vm.isDemoMode || vm.currentPC == nil || !vm.metrics.isOnline)
                .tvDebugFocus("row-sunshine")
                Button {
                    showsQuality = true
                } label: {
                    LabeledContent("Stream Quality",
                                   value: "\(streamSettings.settings.pixelSize.height)p · \(streamSettings.settings.frameRate) fps")
                        .tvRowLabel()
                }
            } header: {
                TVListHeader("Streaming")
            }

            Section {
                NavigationLink(value: TVSettingsRoute.pro) {
                    LabeledContent("Orbit Pro", value: proStore.isProUnlocked ? "Unlocked" : (proStore.displayPrice ?? ""))
                }
            } header: {
                TVListHeader("Orbit Pro")
            }

            Section {
                Toggle(isOn: Binding(get: { vm.isDemoMode }, set: { vm.setDemoMode($0) })) {
                    Text("Demo Mode").tvRowLabel()
                }
                LabeledContent("Version", value: Self.version)
                NavigationLink("Acknowledgements", value: TVSettingsRoute.acknowledgements)
            } header: {
                TVListHeader("About")
            }
        }
        .listStyle(.grouped)
        .tint(nil)
    }

    private var statusLine: String {
        switch state {
        case .setup: return "No PC yet"
        case .demo: return "Sample data"
        case .online: return vm.metrics.agentVersion.map { "Online · Orbit Companion \($0)" } ?? "Online"
        case .locked: return "Online · Windows is locked"
        case .connecting: return "Connecting…"
        case .waking: return "Waking up…"
        case .offline: return "Asleep or off"
        }
    }

    private var sunshineStatus: String {
        if vm.isDemoMode || vm.currentPC == nil { return "Needs a PC" }
        if !vm.metrics.isOnline { return "PC is offline" }
        if sunshine.isPaired { return sunshine.reachable ? "Paired" : "Not answering" }
        if sunshine.reachable { return "Not paired" }
        if let info = vm.sunshineInfo, info.installed { return info.running ? "Not answering" : "Not running" }
        return "Not installed"
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}

// MARK: - One PC

private struct TVPCDetailPage: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    var pcID: String
    @ObservedObject var sunshine: MoonlightHostCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tvToast) private var toast
    @State private var confirmsRemove = false

    private var pc: TVSavedPC? { vm.savedPCs.first { $0.id == pcID } }
    private var isCurrent: Bool { vm.currentPC?.id == pcID && !vm.isDemoMode }
    private var state: TVPCState { TVPCState(vm: vm) }

    var body: some View {
        if let pc {
            TVSplitPage {
                OrbitMark(status: isCurrent ? state.markStatus : .plain, size: 200)
                VStack(spacing: 10) {
                    Text(pc.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(isCurrent ? statusLine : "Not in use")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } content: {
                List {
                    Section {
                        if !isCurrent {
                            Button {
                                vm.selectPC(pc)
                                dismiss()
                            } label: {
                                Text("Use This PC").tvRowLabel()
                            }
                        }
                        if !pc.macAddress.isEmpty && !(isCurrent && vm.metrics.isOnline) {
                            Button {
                                vm.selectPC(pc)
                                Task {
                                    await vm.wakePC()
                                    toast("Sent the wake-up signal to \(pc.name)")
                                }
                            } label: {
                                Text("Wake PC").tvRowLabel()
                            }
                        }
                    }
                    Section {
                        LabeledContent("Address", value: pc.address)
                        LabeledContent("Network Card", value: pc.macAddress.isEmpty ? "Learned when the PC is on" : pc.macAddress)
                        if isCurrent && vm.metrics.isOnline {
                            if let cpu = Self.named(vm.metrics.cpuName, placeholder: "Processor") {
                                LabeledContent("Processor", value: cpu)
                            }
                            if let gpu = Self.named(vm.metrics.gpuName, placeholder: "Graphics") {
                                LabeledContent("Graphics", value: gpu)
                            }
                            if vm.metrics.ramTotalGB > 0 {
                                LabeledContent("Memory", value: "\(OrbitFormat.gigabytes(vm.metrics.ramTotalGB, digits: 0) ?? "") GB")
                            }
                            if let version = vm.metrics.agentVersion {
                                LabeledContent("Orbit Companion", value: version)
                            }
                        }
                    } header: {
                        TVListHeader("Details")
                    }
                    Section {
                        Button("Remove PC", role: .destructive) { confirmsRemove = true }
                    }
                }
                .listStyle(.grouped)
                .tint(nil)
            }
            .confirmationDialog("Remove \(pc.name)?", isPresented: $confirmsRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    vm.deletePC(pc)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Orbit forgets its address and pairing on this Apple TV. You can pair it again any time.")
            }
        }
    }

    private var statusLine: String {
        switch state {
        case .online: return "Online"
        case .locked: return "Online · Windows is locked"
        case .connecting: return "Connecting…"
        case .waking: return "Waking up…"
        default: return "Asleep or off"
        }
    }

    /// A part's name, or nil for the placeholders the PC sends when it can't tell.
    static func named(_ name: String, placeholder: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == placeholder || trimmed == "Unavailable" ? nil : trimmed
    }
}

// MARK: - Add a PC

/// Three ways in, easiest first: from the iPhone, from the network, or by address. Pairing
/// asks for the code Orbit Companion shows on the PC.
struct TVAddPCView: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    var onDone: (() -> Void)? = nil
    @State private var address = ""
    @State private var port = "8765"
    @State private var showsCode = false

    var body: some View {
        TVSplitPage {
            OrbitMark(status: vm.isScanningNetwork || vm.isPairingInProgress ? .working : .online, size: 200)
            VStack(spacing: 10) {
                Text("Add a PC")
                    .font(.title3.weight(.semibold))
                Text("Install Orbit Companion on the Windows PC. It shows a 6-digit code when you pair.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } content: {
            List {
                Section {
                    Button {
                        Task { await vm.syncFromiPhone(silent: false) }
                    } label: {
                        HStack {
                            Label("Sync from iPhone", systemImage: "iphone")
                            Spacer()
                            if vm.isSyncingFromiPhone { ProgressView() }
                        }
                        .tvRowLabel()
                    }
                } header: {
                    TVListHeader("From Your iPhone")
                } footer: {
                    Text(vm.iPhoneSyncStatusMessage ?? "PCs paired in Orbit on iPhone arrive through iCloud, or from an iPhone with Orbit open on the same Wi-Fi.")
                }

                Section {
                    ForEach(vm.discoveredPCs) { pc in
                        Button {
                            Task {
                                await vm.beginPINPairing(with: pc)
                                if vm.activePairingTarget != nil { showsCode = true }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pc.name)
                                    .lineLimit(1)
                                Text("\(pc.host) · Orbit Companion \(pc.agentVersion)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tvRowLabel()
                        }
                    }
                    Button {
                        vm.startDiscovery()
                    } label: {
                        HStack {
                            Text(vm.isScanningNetwork ? "Looking for PCs…" : "Look Again")
                            Spacer()
                            if vm.isScanningNetwork { ProgressView() }
                        }
                        .tvRowLabel()
                    }
                    .disabled(vm.isScanningNetwork)
                } header: {
                    TVListHeader("On This Network")
                } footer: {
                    if vm.discoveredPCs.isEmpty && !vm.isScanningNetwork {
                        Text("No PCs found yet. Make sure Orbit Companion is running on the PC and it's on the same network.")
                    }
                }

                Section {
                    TextField("Address, like 192.168.1.50", text: $address)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                    Button {
                        connect()
                    } label: {
                        HStack {
                            Text(vm.isProbingManualHost ? "Connecting…" : "Connect")
                            Spacer()
                            if vm.isProbingManualHost || vm.isPairingInProgress { ProgressView() }
                        }
                        .tvRowLabel()
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || vm.isProbingManualHost)
                } header: {
                    TVListHeader("By Address")
                } footer: {
                    if let error = vm.pairingErrorMessage {
                        Text(error)
                            .foregroundStyle(OrbitPalette.warm)
                    } else {
                        Text("Orbit Companion shows the PC's address in its menu in the Windows system tray.")
                    }
                }
            }
            .listStyle(.grouped)
            .tint(nil)
        }
        .onAppear {
            #if DEBUG
            if TVDebugLaunch.discoveryOff { return }
            #endif
            vm.startDiscovery()
        }
        .onDisappear { vm.stopDiscovery() }
        .alert("Enter the Code", isPresented: $showsCode) {
            TextField("6-digit code", text: $vm.pairingPIN)
            Button("Pair") {
                Task {
                    await vm.finishPINPairing()
                    if vm.activePairingTarget == nil, vm.pairingErrorMessage == nil { onDone?() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Type the 6-digit code Orbit Companion shows on \(vm.activePairingTarget?.name ?? "the PC").")
        }
    }

    private func connect() {
        let host = address
        let discoveryPort = Int(port) ?? 8765
        Task {
            await vm.probeManualHost(host, discoveryPort: discoveryPort)
            if vm.activePairingTarget != nil { showsCode = true }
        }
    }
}

// MARK: - Orbit Pro

private struct TVProPage: View {
    @ObservedObject private var store = OrbitProStore.shared

    var body: some View {
        TVSplitPage {
            OrbitMark(status: .online, size: 200)
            VStack(spacing: 10) {
                Text("Orbit Pro")
                    .font(.title3.weight(.semibold))
                Text("One purchase for iPhone, iPad, Apple TV and Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } content: {
            List {
                Section {
                    feature("More than one PC", "Save every PC you own and switch between them.")
                    feature("Accent colors and app icons", "Make Orbit yours on iPhone and iPad.")
                    feature("Power widgets and Siri", "Wake, sleep and shut down from widgets, Control Center and Siri.")
                    feature("Session history", "Frame rate, temperatures and power across a whole session.")
                } header: {
                    TVListHeader("Included")
                }
                Section {
                    if store.isProUnlocked {
                        Label("Unlocked on this Apple Account", systemImage: "checkmark")
                    } else {
                        Button {
                            Task { await store.purchase() }
                        } label: {
                            Text(purchaseTitle).tvRowLabel()
                        }
                        .disabled(store.isPurchasing || store.product == nil)
                    }
                    Button {
                        Task { await store.restorePurchases() }
                    } label: {
                        Text("Restore Purchases").tvRowLabel()
                    }
                    .disabled(store.isPurchasing)
                } footer: {
                    if let message = store.errorMessage ?? store.statusMessage {
                        Text(message)
                    }
                }
            }
            .listStyle(.grouped)
            .tint(nil)
        }
        .task {
            if store.product == nil { await store.loadProducts() }
        }
    }

    private func feature(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var purchaseTitle: String {
        if store.isPurchasing { return "Purchasing…" }
        switch store.productState {
        case .loaded: return "Unlock for \(store.displayPrice ?? "")"
        case .unavailable: return "Not available right now"
        default: return "Loading price…"
        }
    }
}

// MARK: - Acknowledgements

/// The licenses, from the same notices as the shared acknowledgements screen. Rows are
/// focusable so the list scrolls with the remote; they have nothing to open on a TV.
private struct TVAcknowledgementsPage: View {
    var body: some View {
        TVSplitPage {
            OrbitMark(status: .online, size: 200)
            VStack(spacing: 10) {
                Text("Acknowledgements")
                    .font(.title3.weight(.semibold))
                Text("Orbit is free software, built with these open-source projects.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } content: {
            List {
                Section {
                    row(OrbitThirdPartyNotices.orbitLicenseSummary, detail: nil)
                    row("Source code", detail: OrbitThirdPartyNotices.repositoryURL.absoluteString)
                    row("GNU General Public License v3", detail: OrbitThirdPartyNotices.gplURL.absoluteString)
                } header: {
                    TVListHeader("Orbit")
                }
                Section {
                    ForEach(OrbitThirdPartyNotices.bundled) { component in
                        row(component.name, detail: "\(component.license) · \(component.author)\n\(component.role)")
                    }
                } header: {
                    TVListHeader("In This App")
                } footer: {
                    Text("The streaming engine is Moonlight's open-source code. Its App Store Distribution Exception allows this app on the App Store because Orbit's full source is available under the GPL.")
                }
                Section {
                    ForEach(OrbitThirdPartyNotices.external) { component in
                        row(component.name, detail: "\(component.license) · \(component.author)\n\(component.role)")
                    }
                    row("Sunshine for Windows", detail: OrbitThirdPartyNotices.sunshineDownloadURL.absoluteString)
                } header: {
                    TVListHeader("Works With")
                } footer: {
                    Text("Orbit is not affiliated with or endorsed by the Moonlight project, LizardByte, NVIDIA or Apple.")
                }
                Section {
                    row(OrbitThirdPartyNotices.appStoreException, detail: nil, small: true)
                } header: {
                    TVListHeader("App Store Distribution Exception")
                }
            }
            .listStyle(.grouped)
            .tint(nil)
        }
    }

    private func row(_ title: String, detail: String?, small: Bool = false) -> some View {
        Button {} label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(small ? .caption : .body)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .tvRowLabel()
        }
        .accessibilityElement(children: .combine)
    }
}
