import SwiftUI

/// Orbit Pro: one purchase that unlocks the extras on every Apple device you use Orbit on.
struct OrbitProPaywallView: View {
    @ObservedObject private var store = OrbitProStore.shared
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @Environment(\.dismiss) private var dismiss
    @State private var showsPrivacy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 10) {
                        OrbitMark(status: .online, size: 64)
                            .padding(.bottom, 10)
                        Text("Orbit Pro")
                            .font(.largeTitle.weight(.bold))
                        Text("One purchase for Orbit on your iPhone, iPad, Mac and Apple TV.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 24) {
                        OrbitFeatureRow(systemImage: "desktopcomputer", title: "Every PC you own",
                                        text: "Save more than one PC and switch between them.")
                        OrbitFeatureRow(systemImage: "chart.xyaxis.line", title: "Sessions",
                                        text: "Frame rate, temperatures and power, recorded while you play.")
                        OrbitFeatureRow(systemImage: "power", title: "Power from anywhere",
                                        text: "Wake, sleep and shut down from widgets, Control Center and Siri.")
                        OrbitFeatureRow(systemImage: "paintpalette", title: "More accent colors",
                                        text: "Pink, Gold, Red, Green, Ice and Rose.")
                        OrbitFeatureRow(systemImage: "app.badge", title: "More app icons",
                                        text: "Blue, Gold, Red, Green and Light.")
                    }

                    if let error = store.errorMessage {
                        OrbitInlineStatus(text: error, kind: .problem)
                    } else if let status = store.statusMessage {
                        OrbitInlineStatus(text: status, kind: store.isProUnlocked ? .success : .info)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(OrbitPalette.canvas)
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 14) {
                    if store.isProUnlocked {
                        Label("Orbit Pro is unlocked. Thank you.", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(OrbitPalette.online)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    } else {
                        Button {
                            OrbitHaptics.press()
                            Task { await store.purchase() }
                        } label: {
                            HStack(spacing: 8) {
                                if store.isPurchasing { ProgressView() }
                                Text(purchaseTitle)
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .orbitGlassButton(prominent: true)
                        .disabled(store.isPurchasing || store.product == nil)
                        Text("A one-time purchase. No subscription.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Restore Purchases") { Task { await store.restorePurchases() } }
                            .disabled(store.isPurchasing)
                        Spacer()
                        Button("Privacy and Terms") { showsPrivacy = true }
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 6)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: 560)
            }
            .orbitCloseButton { dismiss() }
            .sheet(isPresented: $showsPrivacy) { OrbitPrivacyPolicyView() }
            .task { if store.product == nil { await store.loadProducts() } }
        }
        .tint(theme.orbitTint)
        .preferredColorScheme(.dark)
    }

    private var purchaseTitle: String {
        if store.isPurchasing { return "Purchasing…" }
        switch store.productState {
        case .loaded: return "Unlock for \(store.displayPrice ?? "")"
        case .unavailable: return "Orbit Pro isn't available right now"
        case .idle, .loading: return "Loading the price…"
        }
    }
}

/// Shows `content` with Orbit Pro; without it, what the feature does and how to unlock it.
struct OrbitProGate<Content: View>: View {
    let title: String
    let message: String
    @ViewBuilder var content: () -> Content
    @ObservedObject private var store = OrbitProStore.shared
    @State private var showsPaywall = false

    var body: some View {
        if store.isProUnlocked {
            content()
        } else {
            VStack(spacing: 14) {
                Image(systemName: "lock")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2.weight(.bold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showsPaywall = true
                } label: {
                    Text("Unlock Orbit Pro")
                        .font(.headline)
                        .frame(maxWidth: 280)
                        .padding(.vertical, 6)
                }
                .orbitGlassButton(prominent: true)
                .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OrbitPalette.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showsPaywall) { OrbitProPaywallView() }
        }
    }
}

/// How Orbit handles your data, in plain words. The full policy is PRIVACY.md.
struct OrbitPrivacyPolicyView: View {
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            OrbitPage(spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your PC stays yours.")
                        .font(.title2.weight(.bold))
                    Text("Orbit has no accounts, no analytics, no ads and no tracking.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                .padding(.top, 8)

                paragraph("On Your Network",
                          "Orbit talks straight to your PC over your own network, encrypted with TLS and checked against the certificate saved when you paired. Readings, files, clipboard text and commands never go to a server.")
                paragraph("Pairing",
                          "Your PC shows a one-time code. The code proves both sides to each other first; only then does the PC send its access token, encrypted.")
                paragraph("On Your Devices",
                          "Your PCs' addresses, wake details and access tokens stay on this iPhone, in the Keychain and in the space Orbit shares with its widgets, controls and Live Activity. With iCloud on, your saved PCs also reach Orbit on your other Apple devices through your iCloud account.")
                paragraph("Permissions",
                          "Local Network lets Orbit find, read and wake your PC. Orbit sees only the photos and videos you pick to send, and adds to your library only when you save something from the PC.")
                paragraph("Purchases",
                          "Orbit Pro is a one-time purchase handled by Apple. Restore it on any device signed in to the same Apple Account.")

                Link(destination: URL(string: "https://github.com/AceDimi2005/Orbit")!) {
                    Label("Questions and Support on GitHub", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .orbitCloseButton { dismiss() }
        }
        .tint(theme.orbitTint)
        .preferredColorScheme(.dark)
    }

    private func paragraph(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            OrbitSectionHeader(title)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }
}
