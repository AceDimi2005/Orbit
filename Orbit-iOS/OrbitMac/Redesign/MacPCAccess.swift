import SwiftUI

/// Orbit Companion 5: the devices that may use the current PC, with Remove, and what they did
/// on it lately. Shown for the selected PC while it is online.
struct MacPCAccessSection: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @State private var removing: OrbitDevice?

    private var pcName: String { vm.selectedPCName }

    var body: some View {
        if !vm.isDemoMode, vm.metrics.isOnline, vm.has("devices") {
            VStack(alignment: .leading, spacing: 30) {
                devicesSection
                if vm.has("activity") { activitySection }
            }
            .task(id: vm.selectedPCID) {
                await vm.refreshDevices()
                await vm.refreshActivity()
            }
            .confirmationDialog("Remove \(removing?.name ?? "this device") from \(pcName)?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { device in
                Button("Remove", role: .destructive) { Task { await vm.revoke(device) } }
                Button("Cancel", role: .cancel) {}
            } message: { device in
                Text(device.legacy
                     ? "Orbit apps paired before Orbit Companion 5 stop working with \(pcName) until they're paired again."
                     : "\(device.name) can't use \(pcName) until it's paired again.")
            }
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            OrbitSectionHeader("Who Can Use \(pcName)") {
                if vm.isLoadingDevices { ProgressView().controlSize(.small) }
            }
            VStack(spacing: 0) {
                if let error = vm.devicesError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else if vm.devices.isEmpty {
                    Text("Reading the list from the PC…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(vm.devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { Divider().overlay(OrbitPalette.hairline) }
                        deviceRow(device)
                    }
                }
            }
            .orbitSurface(padding: 18, radius: 20)
            if vm.devices.contains(where: \.legacy) {
                Text("Older Orbit apps share one key with the PC. Once every device is paired again, remove them so each device has its own key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func deviceRow(_ device: OrbitDevice) -> some View {
        HStack(spacing: 14) {
            Image(systemName: device.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.legacy ? "Older Orbit Apps" : device.name)
                        .font(.headline)
                    if device.current {
                        Text("This Mac")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(detail(for: device))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if !device.current {
                Button("Remove…") { removing = device }
                    .buttonStyle(MacHoverButtonStyle())
                    .help("Stop \(device.legacy ? "older Orbit apps" : device.name) from using \(pcName)")
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func detail(for device: OrbitDevice) -> String {
        var parts = [device.kind]
        if let seen = device.lastSeen {
            parts.append(device.current ? "now" : "used \(seen.formatted(.relative(presentation: .named)))")
        }
        if !device.legacy, !Set(device.scopes).isSuperset(of: ["control", "input", "files"]) {
            parts.append(device.scopes.contains("control") ? "no files" : "view only")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Activity

    private var recent: [OrbitActivityEntry] { Array(vm.activity.prefix(12)) }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            OrbitSectionHeader("Recent Activity") {
                Button("Refresh") { Task { await vm.refreshActivity() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
            VStack(spacing: 0) {
                if let error = vm.activityError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else if recent.isEmpty {
                    Text("Nothing yet. Power, files, sound and other changes made from Orbit appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().overlay(OrbitPalette.hairline) }
                        activityRow(entry)
                    }
                }
            }
            .orbitSurface(padding: 18, radius: 20)
        }
    }

    private func activityRow(_ entry: OrbitActivityEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: entry.result == "ok" ? "circle.fill" : "exclamationmark.triangle.fill")
                .font(entry.result == "ok" ? .system(size: 6) : .caption)
                .foregroundStyle(entry.result == "ok" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(OrbitPalette.warm))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.summary)
                    .lineLimit(2)
                Text([entry.deviceName == "Legacy device" ? "An older Orbit app" : entry.deviceName, entry.result == "denied" ? "not allowed" : (entry.result == "error" ? "failed" : nil)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let date = entry.date {
                Text(date.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
