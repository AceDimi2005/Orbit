import SwiftUI

/// Orbit outside the app: widgets, Control Center, Siri, and the read-only access widgets
/// use to reach the PC.
struct WidgetHelpView: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject private var proStore = OrbitProStore.shared
    @State private var pairedPCs: [OrbitWidgetConnection] = []
    @State private var showsPro = false

    private let widgets: [(String, String)] = [
        ("Status", "How your PC is doing, in one sentence."),
        ("Frame Rate", "The game that's running and how smoothly."),
        ("Temperatures", "The processor and the graphics card."),
        ("Power Draw", "The watts each part uses."),
        ("Fans", "Fan speeds and the liquid loop."),
        ("Disk Activity", "How fast the PC reads and writes."),
        ("Network", "What the PC receives and sends."),
        ("Reading", "Any one reading, also on the Lock Screen."),
        ("Power Buttons", "Wake, sleep or shut down the PC.")
    ]

    var body: some View {
        Form {
            Section {
                ForEach(widgets, id: \.0) { name, text in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                        Text(text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Widgets")
            } footer: {
                Text("Touch and hold the Home Screen, tap Edit, then Add Widget, and search for Orbit. Touch and hold a widget to choose its PC and color.")
            }

            Section {
                LabeledContent("Wake PC", value: "Turns it on")
                LabeledContent("Sleep PC", value: "Puts it to sleep")
                LabeledContent("Shut Down PC", value: "Turns it off")
            } header: {
                Text("Control Center")
            } footer: {
                Text("Open Control Center, touch and hold an empty spot, tap Add a Control, and search for Orbit. They also work from the Action button and the Lock Screen.")
            }

            Section {
                phrase("Wake up my PC in Orbit")
                phrase("Put my PC to sleep with Orbit")
                phrase("Restart my PC with Orbit")
                phrase("Shut down my PC with Orbit")
            } header: {
                Text("Siri")
            } footer: {
                Text("The same actions are in the Shortcuts app.")
            }

            if !proStore.isProUnlocked {
                Section {
                    Button("Unlock Orbit Pro") { showsPro = true }
                } footer: {
                    Text("Power buttons in widgets and Control Center, and the Siri power actions, come with Orbit Pro.")
                }
            }

            Section {
                if pairedPCs.isEmpty {
                    Text("No PC can be read by widgets yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(pairedPCs) { pc in
                    LabeledContent(pc.name) {
                        Label("Ready", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task {
                        await vm.prepareWidgetAccess()
                        pairedPCs = OrbitWidgetConnectionStore.connections()
                    }
                } label: {
                    HStack {
                        Text(vm.isLoadingWidgetToken ? "Refreshing…" : "Refresh Widget Access")
                        Spacer()
                        if vm.isLoadingWidgetToken { ProgressView() }
                    }
                }
                .disabled(!vm.metrics.isOnline || vm.isDemoMode || vm.isLoadingWidgetToken)
                if let error = vm.widgetSetupError {
                    OrbitInlineStatus(text: error, kind: .problem)
                }
            } header: {
                Text("Widget Access")
            } footer: {
                Text("Widgets read your PC with their own read-only key. Refresh it if a widget asks you to open Orbit.")
            }
        }
        .orbitListBackground()
        .navigationTitle("Widgets, Controls and Siri")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { pairedPCs = OrbitWidgetConnectionStore.connections() }
        .sheet(isPresented: $showsPro) { OrbitProPaywallView() }
    }

    private func phrase(_ text: String) -> some View {
        Text("“\(text)”")
    }
}
