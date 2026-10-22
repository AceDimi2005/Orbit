import SwiftUI

/// First run: what Orbit does, then the two steps that connect a PC.
struct WelcomeView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var step: Step = .intro
    @State private var markStatus: OrbitMark.Status = .working
    @State private var showsDiscovery = false
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir

    private enum Step { case intro, setup }

    private var isPaired: Bool { vm.metrics.isOnline && !vm.isDemoMode && vm.isConfigured }

    var body: some View {
        NavigationStack {
            ZStack {
                switch step {
                case .intro: intro.transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                case .setup: setup.transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(OrbitMotion.standard, value: step)
            .background(OrbitPalette.canvas)
            .toolbar {
                if vm.hasCompletedOnboarding {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { vm.showOnboarding = false }
                            .tint(.primary)
                    }
                }
            }
        }
        .tint(theme.orbitTint)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsDiscovery) {
            PCDiscoveryView(vm: vm) { showsDiscovery = false }
        }
        .task {
            // The satellite finds its place: Orbit's mark settles as the welcome appears.
            try? await Task.sleep(for: .seconds(1.4))
            markStatus = .online
        }
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    OrbitMark(status: markStatus, size: 84)
                        .padding(.top, 36)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your PC, at your fingertips.")
                            .font(.largeTitle.weight(.bold))
                        Text("Orbit connects your iPhone, iPad, Mac, Apple TV and Apple Watch to your Windows PC.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 26) {
                        feature("gauge.with.needle", "See how it's doing", "Temperatures, load and frame rate as they happen.")
                        feature("power", "Power it from anywhere", "Wake it up, put it to sleep, lock it or sign in.")
                        feature("gamecontroller", "Play on any screen", "Stream your games and desktop, or start them on the PC.")
                        feature("folder", "Reach your files", "Send photos to the PC and bring documents back.")
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            Button {
                OrbitHaptics.tap()
                step = .setup
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .orbitGlassButton(prominent: true)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: symbol)
                .font(.title2.weight(.regular))
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(isPaired ? "You're connected." : "Connect your PC")
                            .font(.largeTitle.weight(.bold))
                        Text(isPaired ? "Orbit is talking to \(vm.selectedPCName)." : "Two steps, about a minute.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 36)

                    if isPaired {
                        HStack(spacing: 16) {
                            OrbitMark(status: .online, size: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vm.selectedPCName).font(.headline)
                                Text(OrbitTakeaway(vm.metrics).headline)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .orbitSurface()
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                    } else {
                        stepView(1, "Install Orbit Companion on the PC",
                                 "It runs quietly in the Windows system tray and starts with your PC.") {
                            ShareLink(item: URL(string: "https://github.com/AceDimi2005/Orbit/raw/main/Orbit-Windows-Agent.zip")!,
                                      subject: Text("Orbit Companion for Windows"),
                                      message: Text("Orbit Companion for Windows: unzip it and run install_orbit.bat.")) {
                                Label("Send the Download to Your PC", systemImage: "square.and.arrow.up")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        stepView(2, "Pair with the code on your PC",
                                 "Keep the PC on the same network. Orbit finds it and asks for the code it shows.") {
                            EmptyView()
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .animation(OrbitMotion.standard, value: isPaired)
            }
            VStack(spacing: 12) {
                Button {
                    OrbitHaptics.press()
                    if isPaired { finish() } else { showsDiscovery = true }
                } label: {
                    Text(isPaired ? "Start Using Orbit" : "Find My PC")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .orbitGlassButton(prominent: true)
                if !isPaired {
                    HStack {
                        Button("Try the Demo") {
                            vm.setDemoMode(true)
                            finish()
                        }
                        Spacer()
                        Button("Set Up Later") { finish() }
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 6)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private func stepView<Accessory: View>(_ number: Int, _ title: String, _ text: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .frame(width: 32, height: 32)
                .background(OrbitPalette.well, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                accessory()
                    .padding(.top, 4)
            }
        }
    }

    private func finish() {
        vm.hasCompletedOnboarding = true
        vm.showOnboarding = false
    }
}
