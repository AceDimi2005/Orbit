import SwiftUI

/// Everything Orbit Companion detected about the PC's hardware, like a spec sheet.
struct FullSpecsView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var showsNames = false

    var body: some View {
        Group {
            if let specs = vm.specs {
                inventory(specs)
            } else if vm.isLoadingSpecs {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Reading the hardware…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OrbitPalette.canvas)
            } else {
                OrbitEmptyMessage(systemImage: "cpu", title: "No specifications yet",
                                  message: vm.specsError ?? (vm.metrics.isOnline ? "Orbit Companion hasn't sent them yet." : "Connect to your PC to read its hardware."),
                                  actionTitle: vm.metrics.isOnline ? "Try Again" : nil) {
                    Task { await vm.fetchSpecs() }
                }
                .frame(maxHeight: .infinity)
                .background(OrbitPalette.canvas)
            }
        }
        .navigationTitle("Specifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit Names", systemImage: "pencil") { showsNames = true }
                    .tint(.primary)
                    .disabled(vm.specs == nil)
            }
        }
        .sheet(isPresented: $showsNames) { ComponentNamesView(vm: vm) }
        .task { if vm.specs == nil && vm.metrics.isOnline { await vm.fetchSpecs() } }
    }

    private func inventory(_ specs: PCSpecs) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(specs.hostname)
                        .font(.title3.weight(.semibold))
                    if let system = systemLine(specs) {
                        Text(system)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
            } footer: {
                Text(sourceLine(specs))
            }

            let topSpeed = specs.cpu.maxClockMHz.map { "\(OrbitScreenFormat.number($0 / 1000, digits: 2)) GHz" }
            let temperature = vm.metrics.cpuTemp.flatMap { OrbitFormat.temperature($0) }
            if reported([vm.componentOverrides["cpu"], specs.cpu.name, cores(specs.cpu), topSpeed, temperature]) {
                Section("Processor") {
                    customName("cpu")
                    row("Model", specs.cpu.name)
                    row("Cores", cores(specs.cpu))
                    row("Top Speed", topSpeed)
                    row("Temperature", temperature)
                }
            }

            if !specs.gpus.isEmpty || vm.componentOverrides["gpu"] != nil {
                Section("Graphics") {
                    customName("gpu")
                    ForEach(Array(specs.gpus.enumerated()), id: \.offset) { index, gpu in
                        row(specs.gpus.count > 1 ? "Card \(index + 1)" : "Model", gpu.name)
                        row("Video Memory", gpu.vramGB.map { "\(OrbitScreenFormat.number($0)) GB" })
                        row("Driver", gpu.driverVersion)
                    }
                }
            }

            let installed = specs.memory.totalGB.map { "\(OrbitScreenFormat.number($0)) GB" }
            if reported([vm.componentOverrides["memory"], installed]) || !specs.memory.modules.isEmpty {
                Section("Memory") {
                    customName("memory")
                    row("Installed", installed)
                    ForEach(Array(specs.memory.modules.enumerated()), id: \.offset) { index, module in
                        row(module.slot ?? "Module \(index + 1)", moduleLine(module))
                    }
                }
            }

            let board = [specs.motherboard.manufacturer, specs.motherboard.model].compactMap { $0 }.joined(separator: " ")
            if reported([vm.componentOverrides["motherboard"], board, specs.motherboard.biosVersion,
                         vm.componentOverrides["cooler"], specs.coolerName]) {
                Section("Motherboard and Cooling") {
                    customName("motherboard")
                    row("Board", board)
                    row("BIOS", specs.motherboard.biosVersion)
                    customName("cooler")
                    row("Cooler", specs.coolerName)
                }
            }

            if !specs.disks.isEmpty || !specs.volumes.isEmpty {
                Section("Storage") {
                    customName("storage")
                    ForEach(Array(specs.disks.enumerated()), id: \.offset) { index, disk in
                        row(disk.name ?? "Drive \(index + 1)", diskLine(disk))
                    }
                    ForEach(Array(specs.volumes.enumerated()), id: \.offset) { _, volume in
                        if let mount = volume.mountpoint {
                            row(mount, volumeLine(volume))
                        }
                    }
                }
            }

            if !specs.networkAdapters.isEmpty {
                Section("Network") {
                    ForEach(Array(specs.networkAdapters.enumerated()), id: \.offset) { index, adapter in
                        row(adapter.name ?? "Adapter \(index + 1)", adapter.ipv4Addresses.isEmpty ? nil : adapter.ipv4Addresses.joined(separator: ", "))
                        row("Hardware Address", adapter.macAddress)
                    }
                }
            }
        }
        .orbitListBackground()
        .refreshable { if vm.metrics.isOnline { await vm.fetchSpecs() } }
    }

    // MARK: Rows

    /// Whether any of these values was reported, so a section without any stays hidden.
    private func reported(_ values: [String?]) -> Bool {
        values.contains { $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }

    /// A row for a value the PC reported; nothing when it didn't.
    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            LabeledContent(title) {
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func customName(_ key: String) -> some View {
        if let name = vm.componentOverrides[key], !name.isEmpty {
            row("Your Name", name)
        }
    }

    // MARK: Lines

    private func systemLine(_ specs: PCSpecs) -> String? {
        let parts = [specs.osName, specs.osVersion, specs.architecture].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func sourceLine(_ specs: PCSpecs) -> String {
        if vm.isDemoMode { return "Sample hardware, not a real PC." }
        let detected = specs.source.map { "Detected through \($0)." } ?? "Detected by Orbit Companion."
        return vm.metrics.isOnline ? detected : "Saved from the last time the PC was online."
    }

    private func cores(_ cpu: PCSpecs.CPU) -> String? {
        guard let physical = cpu.physicalCores else { return nil }
        if let logical = cpu.logicalCores, logical != physical { return "\(physical) cores · \(logical) threads" }
        return "\(physical) cores"
    }

    private func moduleLine(_ module: PCSpecs.MemoryModule) -> String? {
        let parts = [module.capacityGB.map { "\(OrbitScreenFormat.number($0)) GB" },
                     module.speedMHz.map { "\(Int($0.rounded())) MHz" },
                     module.partNumber?.trimmingCharacters(in: .whitespaces)]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func diskLine(_ disk: PCSpecs.Disk) -> String? {
        let size = disk.sizeGB.map { $0 >= 1000 ? "\(OrbitScreenFormat.number($0 / 1000, digits: 2)) TB" : "\(Int($0.rounded())) GB" }
        let kind = [disk.interfaceType, disk.mediaType].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let parts = [size, kind.isEmpty ? nil : kind].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func volumeLine(_ volume: PCSpecs.Volume) -> String? {
        var parts: [String] = []
        if let used = volume.usedGB, let total = volume.totalGB, total > 0 {
            parts.append("\(Int(used.rounded())) of \(Int(total.rounded())) GB used")
        } else if let total = volume.totalGB {
            parts.append("\(Int(total.rounded())) GB")
        }
        if let fileSystem = volume.fileSystem, !fileSystem.isEmpty { parts.append(fileSystem) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Your own names for the PC's parts, shown in Specifications for this PC only.
struct ComponentNamesView: View {
    @ObservedObject var vm: OrbitViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String: String] = [:]

    private let components = [("cpu", "Processor"), ("gpu", "Graphics Card"), ("memory", "Memory"),
                              ("motherboard", "Motherboard"), ("cooler", "Cooler"), ("storage", "Storage")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(components, id: \.0) { key, title in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            TextField(title, text: Binding(get: { names[key] ?? "" }, set: { names[key] = $0 }),
                                      prompt: Text(detectedName(key)))
                                .autocorrectionDisabled()
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("Leave a name empty to use the one Windows reports.")
                }
                Section {
                    Button("Use the Detected Names", role: .destructive) { names = [:] }
                        .disabled(names.values.allSatisfy { $0.isEmpty })
                }
            }
            .orbitListBackground()
            .navigationTitle("Names")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                        .tint(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        for (key, _) in components { vm.setComponentOverride(key, value: names[key] ?? "") }
                        OrbitHaptics.success()
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { names = vm.componentOverrides }
    }

    private func detectedName(_ key: String) -> String {
        switch key {
        case "cpu": return vm.specs?.cpu.name ?? "Detected processor"
        case "gpu": return vm.specs?.gpus.first?.name ?? "Detected graphics card"
        case "memory": return vm.specs?.memory.totalGB.map { "\(OrbitScreenFormat.number($0)) GB" } ?? "Detected memory"
        case "motherboard": return vm.specs?.motherboard.model ?? "Detected motherboard"
        case "cooler": return vm.specs?.coolerName ?? "Detected cooler"
        case "storage": return vm.specs?.disks.first?.name ?? "Detected storage"
        default: return "Detected name"
        }
    }
}
