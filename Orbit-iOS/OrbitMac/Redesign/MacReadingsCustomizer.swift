import SwiftUI

/// Which readings the PC page shows, and in what order.
struct MacDashboardCustomizer: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var shown: [MacMetric] = []

    private var hidden: [MacMetric] { MacMetric.allCases.filter { !shown.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Readings on the PC Page")
                    .font(.title3.weight(.semibold))
                Text("Drag to reorder. Readings your PC doesn't report stay hidden.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            List {
                Section("Shown") {
                    ForEach(shown) { metric in
                        row(metric, isShown: true)
                    }
                    .onMove { shown.move(fromOffsets: $0, toOffset: $1) }
                }
                if !hidden.isEmpty {
                    Section("Hidden") {
                        ForEach(hidden) { metric in
                            row(metric, isShown: false)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)

            HStack(spacing: 10) {
                Menu("Presets") {
                    Button("Balanced") { withAnimation(OrbitMotion.standard) { shown = MacMetric.defaultDashboard } }
                    Button("Gaming") { withAnimation(OrbitMotion.standard) { shown = [.fps, .gpuLoad, .gpuTemperature, .vram, .cpuLoad, .cpuTemperature, .gpuPower, .cpuPower] } }
                    Button("Everything") { withAnimation(OrbitMotion.standard) { shown = MacMetric.allCases } }
                }
                .fixedSize()
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    vm.dashboardMetrics = shown
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(shown.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 420, height: 560)
        .onAppear { shown = vm.dashboardMetrics }
    }

    private func row(_ metric: MacMetric, isShown: Bool) -> some View {
        HStack(spacing: 10) {
            Text(OrbitVitalKind(rawValue: metric.rawValue)?.title ?? metric.title)
                .foregroundStyle(isShown ? .primary : .secondary)
            Spacer()
            Button {
                withAnimation(OrbitMotion.standard) {
                    if isShown { shown.removeAll { $0 == metric } } else { shown.append(metric) }
                }
            } label: {
                Image(systemName: isShown ? "minus.circle" : "plus.circle")
                    .font(.body)
                    .foregroundStyle(isShown ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(isShown ? "Hide" : "Show")
            .accessibilityLabel(isShown ? "Hide \(metric.title)" : "Show \(metric.title)")
        }
        .padding(.vertical, 2)
    }
}
