import SwiftUI

/// Which readings the PC tab shows under Right Now, and in what order.
struct DashboardCustomizationView: View {
    @ObservedObject var vm: OrbitViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @State private var draft: DashboardConfiguration

    init(vm: OrbitViewModel) {
        self.vm = vm
        _draft = State(initialValue: vm.dashboardConfiguration)
    }

    private static let presets: [(String, DashboardConfiguration)] = [
        ("Balanced", .balanced), ("Gaming", .gaming), ("Work", .workstation), ("Cooling", .cooling), ("Everything", .allMetrics)
    ]

    private var presetName: String {
        Self.presets.first { $0.1.orderedVisibleMetrics == draft.orderedVisibleMetrics }?.0 ?? "Your Own"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Menu {
                        ForEach(Self.presets, id: \.0) { name, configuration in
                            Button(name) {
                                OrbitHaptics.selection()
                                withAnimation(OrbitMotion.standard) { draft = configuration }
                            }
                        }
                    } label: {
                        HStack {
                            Text("Start From")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(presetName)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                } footer: {
                    Text("A starting point you can change below.")
                }

                Section {
                    ForEach(draft.metricOrder) { metric in row(metric) }
                        .onMove { source, destination in draft.metricOrder.move(fromOffsets: source, toOffset: destination) }
                } header: {
                    Text("\(draft.orderedVisibleMetrics.count) Shown")
                } footer: {
                    Text("Drag to change the order. A reading your PC doesn't report stays hidden on the PC tab.")
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            .orbitListBackground()
            .navigationTitle("Readings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                        .tint(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        OrbitHaptics.success()
                        vm.dashboardConfiguration = draft
                        dismiss()
                    }
                }
            }
        }
        .tint(theme.orbitTint)
        .preferredColorScheme(.dark)
    }

    private func row(_ metric: DashboardMetric) -> some View {
        let visible = draft.visibleMetrics.contains(metric)
        let vital = PCVital(metric, vm: vm)
        let reported = vital.hasData || vm.isDemoMode || !vm.metrics.isOnline
        return HStack(spacing: 12) {
            Button {
                OrbitHaptics.selection()
                withAnimation(OrbitMotion.quick) { draft.setVisible(metric, !visible) }
            } label: {
                Image(systemName: visible ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(visible ? AnyShapeStyle(theme.orbitTint) : AnyShapeStyle(Color.white.opacity(0.3)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(visible ? "Hide \(vital.label)" : "Show \(vital.label)")
            VStack(alignment: .leading, spacing: 1) {
                Text(vital.label)
                    .foregroundStyle(visible ? .primary : .secondary)
                if !reported {
                    Text("Not reported by this PC")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if let value = vital.value {
                Text(value + (vital.unit.map { $0 == "%" ? $0 : " \($0)" } ?? ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .orbitLiveNumber()
                    .lineLimit(1)
            }
        }
    }
}
