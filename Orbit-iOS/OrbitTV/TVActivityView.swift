import SwiftUI

/// Activity: the processes using the most, large enough to read from the couch. Selecting
/// one offers to end it, after a confirmation.
struct TVActivityView: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tvToast) private var toast
    @State private var sort: Sort = .processor
    @State private var showsAll = false
    @State private var ending: TVProcessItem?
    @State private var showsAddPC = false

    enum Sort: String, CaseIterable, Identifiable {
        case processor, memory, graphics

        var id: String { rawValue }

        var title: String {
            switch self {
            case .processor: return "Processor"
            case .memory: return "Memory"
            case .graphics: return "Graphics"
            }
        }
    }

    private static let shortList = 10

    private var state: TVPCState { TVPCState(vm: vm) }
    private var hasGraphics: Bool { vm.processes.contains { $0.gpuPercent != nil } }
    private var sorts: [Sort] { hasGraphics ? Sort.allCases : [.processor, .memory] }

    private var sorted: [TVProcessItem] {
        switch sort {
        case .processor: return vm.processes.sorted { ($0.cpuPercent ?? -1, $0.memoryMB ?? -1) > ($1.cpuPercent ?? -1, $1.memoryMB ?? -1) }
        case .memory: return vm.processes.sorted { ($0.memoryMB ?? -1) > ($1.memoryMB ?? -1) }
        case .graphics: return vm.processes.sorted { ($0.gpuPercent ?? -1, $0.vramMB ?? -1) > ($1.gpuPercent ?? -1, $1.vramMB ?? -1) }
        }
    }

    private var shown: [TVProcessItem] { showsAll ? sorted : Array(sorted.prefix(Self.shortList)) }

    var body: some View {
        Group {
            if state.isReachable {
                ScrollView {
                    content
                        .padding(.top, 12)
                        .padding(.bottom, 40)
                }
                .scrollClipDisabled()
                .tvDebugScrollAnchor()
            } else {
                TVPCStatusScreen(state: state, purpose: "see what's running") { showsAddPC = true }
            }
        }
        .fullScreenCover(isPresented: $showsAddPC) {
            TVAddPCView { showsAddPC = false }
                .tvFullScreenPage()
        }
        .onChange(of: vm.selectedPCID) { _, _ in showsAddPC = false }
        .task(id: vm.metrics.isOnline) {
            while !Task.isCancelled {
                if scenePhase == .active, vm.metrics.isOnline, !vm.isDemoMode { await vm.refreshProcesses() }
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
        .onChange(of: hasGraphics) { _, has in if !has, sort == .graphics { sort = .processor } }
        .confirmationDialog("End \(ending.map { TVFormat.processName($0.name) } ?? "")?", isPresented: Binding(
            get: { ending != nil }, set: { if !$0 { ending = nil } }
        ), titleVisibility: .visible) {
            if let process = ending {
                Button("End Task", role: .destructive) {
                    ending = nil
                    Task {
                        await vm.terminateProcess(process)
                        if let message = vm.processStatusMessage { toast(message) }
                    }
                }
            }
            Button("Cancel", role: .cancel) { ending = nil }
        } message: {
            Text("Unsaved work in \(ending.map { TVFormat.processName($0.name) } ?? "the app") will be lost.")
        }
        #if DEBUG
        .task {
            if TVDebugLaunch.sheet == "endtask" {
                try? await Task.sleep(for: .seconds(2))
                ending = sorted.first { $0.canTerminate }
            }
        }
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 40) {
            VStack(alignment: .leading, spacing: 8) {
                Text(takeaway)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(alignment: .center, spacing: 40) {
                    Text(vm.processes.isEmpty ? "Reading the PC's process list…" : "\(vm.processes.count) running · Select one to end it")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .orbitLiveNumber()
                    Spacer(minLength: 32)
                    Picker("Sort By", selection: $sort) {
                        ForEach(sorts) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: hasGraphics ? 760 : 520)
                    .tvDebugFocus("sort")
                }
            }
            .focusSection()

            if !vm.processes.isEmpty {
                VStack(spacing: 22) {
                    columnTitles
                    ForEach(shown) { process in
                        Button {
                            if process.canTerminate {
                                ending = process
                            } else {
                                toast("Windows protects \(TVFormat.processName(process.name)), so Orbit can't end it.")
                            }
                        } label: {
                            TVProcessRow(vm: vm, process: process, sort: sort, showsGraphics: hasGraphics)
                        }
                        .buttonStyle(.card)
                        .tvDebugFocus(process.id == shown.first?.id ? "process" : "")
                    }
                }
                .focusSection()

                if sorted.count > Self.shortList {
                    Button(showsAll ? "Show Fewer" : "Show All \(sorted.count)") {
                        showsAll.toggle()
                    }
                    .tvButton()
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var takeaway: String {
        guard let top = sorted.first else { return vm.isLoadingProcesses ? "Reading what's running…" : "Nothing to show yet" }
        let name = TVFormat.processName(top.name)
        switch sort {
        case .processor:
            if (top.cpuPercent ?? 0) < 2 { return "The PC is resting" }
            return "\(name) is using the most processor"
        case .memory: return "\(name) is using the most memory"
        case .graphics:
            if (top.gpuPercent ?? 0) < 2 { return "Graphics are idle" }
            return "\(name) is using the most graphics"
        }
    }

    private var columnTitles: some View {
        HStack(spacing: 0) {
            Spacer()
            title(.processor)
                .frame(width: TVProcessRow.valueWidth, alignment: .trailing)
            title(.memory)
                .frame(width: TVProcessRow.memoryWidth, alignment: .trailing)
            if hasGraphics {
                title(.graphics)
                    .frame(width: TVProcessRow.valueWidth, alignment: .trailing)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, TVProcessRow.horizontalPadding)
        .accessibilityHidden(true)
    }

    private func title(_ column: Sort) -> some View {
        Text(column.title)
            .foregroundStyle(column == sort ? Color.primary : Color.secondary)
    }
}

/// One process: icon, name and its share of processor, memory and graphics. The sorted
/// column is white; the others are secondary.
struct TVProcessRow: View {
    @ObservedObject var vm: OrbitTVViewModel
    var process: TVProcessItem
    var sort: TVActivityView.Sort
    var showsGraphics: Bool

    static let valueWidth: CGFloat = 220
    static let memoryWidth: CGFloat = 250
    static let horizontalPadding: CGFloat = 34

    var body: some View {
        HStack(spacing: 0) {
            TVAppIcon(store: vm.appIcons, iconID: process.iconID, name: TVFormat.processName(process.name), size: 64)
                .padding(.trailing, 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(TVFormat.processName(process.name))
                    .font(.headline)
                    .lineLimit(1)
                if !process.canTerminate {
                    Text("Protected by Windows")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 24)
            value(TVFormat.percent(process.cpuPercent), column: .processor)
                .frame(width: Self.valueWidth, alignment: .trailing)
            value(TVFormat.memory(megabytes: process.memoryMB), column: .memory)
                .frame(width: Self.memoryWidth, alignment: .trailing)
            if showsGraphics {
                value(TVFormat.percent(process.gpuPercent), column: .graphics)
                    .frame(width: Self.valueWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 22)
        .background(OrbitPalette.surface)
        .accessibilityElement(children: .combine)
    }

    private func value(_ text: String?, column: TVActivityView.Sort) -> some View {
        Text(text ?? "—")
            .font(.orbitReading(46, weight: column == sort ? .semibold : .regular))
            .foregroundStyle(column == sort && text != nil ? Color.primary : Color.secondary)
            .orbitLiveNumber()
            .lineLimit(1)
    }
}
