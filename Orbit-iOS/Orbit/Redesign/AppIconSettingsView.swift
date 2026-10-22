import SwiftUI

/// The Home Screen icon. Every variant is the same mark; Graphite comes with Orbit and
/// the other finishes come with Orbit Pro.
struct AppIconSettingsView: View {
    @AppStorage("orbit.appIcon") private var selected: OrbitAppIcon = .classic
    @ObservedObject private var proStore = OrbitProStore.shared
    @State private var showsPro = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LazyVGrid(columns: columns, spacing: 26) {
                    ForEach(OrbitAppIcon.allCases) { tile($0) }
                }
                .padding(.top, 8)
                VStack(alignment: .leading, spacing: 8) {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(OrbitPalette.warm)
                    }
                    Text("Every icon adapts to the Home Screen's dark, tinted and clear looks.")
                    if !proStore.isProUnlocked {
                        Text("Blue, Gold, Red, Green and Light come with Orbit Pro.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, OrbitMetrics.gutter)
            .padding(.bottom, 32)
        }
        .background(OrbitPalette.canvas)
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsPro) { OrbitProPaywallView() }
        .onAppear {
            // The system remembers the icon; trust it over the stored choice.
            selected = OrbitAppIcon.current
        }
    }

    private func tile(_ icon: OrbitAppIcon) -> some View {
        let locked = icon.isPro && !proStore.isProUnlocked
        let isSelected = selected == icon
        return Button {
            if locked {
                showsPro = true
            } else {
                apply(icon)
            }
        } label: {
            VStack(spacing: 10) {
                OrbitAppIconPreview(icon: icon, size: 72)
                    .padding(5)
                    .overlay {
                        RoundedRectangle(cornerRadius: 72 * 0.2237 + 5, style: .continuous)
                            .strokeBorder(.tint, lineWidth: 2.5)
                            .opacity(isSelected ? 1 : 0)
                            .scaleEffect(isSelected ? 1 : 0.94)
                    }
                HStack(spacing: 4) {
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.caption2.weight(.semibold))
                    }
                    Text(icon.title)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                }
                .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .animation(OrbitMotion.standard, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon.title + (locked ? ", Orbit Pro" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func apply(_ icon: OrbitAppIcon) {
        errorMessage = nil
        guard icon != selected else { return }
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = "This device can't change app icons."
            return
        }
        OrbitHaptics.selection()
        UIApplication.shared.setAlternateIconName(icon.iconName) { error in
            Task { @MainActor in
                if let error {
                    errorMessage = error.localizedDescription
                } else {
                    selected = icon
                }
            }
        }
    }
}
