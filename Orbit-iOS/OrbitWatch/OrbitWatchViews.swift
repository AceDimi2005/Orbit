import SwiftUI
import WatchKit

/// The pages, top to bottom. The raw values are the view model's `selectedTab`, which the
/// complications' deep links also use.
enum WatchPage: Int {
    case glance = 0, power, control, media
}

/// The watch app: a glance at the PC first, then one page for each thing you do with it.
/// The Digital Crown and vertical swipes move between pages.
struct OrbitWatchRootView: View {
    @ObservedObject var vm: OrbitWatchViewModel

    var body: some View {
        // The accent is applied to each page's content and sheets, not here: toolbar buttons
        // stay in the system's monochrome glass.
        content
            .onChange(of: vm.selectedTab) { _, page in
                if page != WatchPage.control.rawValue { vm.stopMotionCursor() }
            }
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if let family = WatchDebugOptions.gallery {
            WatchComplicationGallery(vm: vm, widget: family)
        } else if let size = WatchDebugOptions.typeSize {
            pages.dynamicTypeSize(size)
        } else {
            pages
        }
        #else
        pages
        #endif
    }

    private var pages: some View {
        NavigationStack {
            TabView(selection: $vm.selectedTab) {
                WatchGlancePage(vm: vm).tag(WatchPage.glance.rawValue)
                WatchPowerPage(vm: vm).tag(WatchPage.power.rawValue)
                WatchControlPage(vm: vm).tag(WatchPage.control.rawValue)
                WatchMediaPage(vm: vm).tag(WatchPage.media.rawValue)
            }
            .tabViewStyle(.verticalPage)
        }
    }
}

extension WatchPCStatus {
    /// The PC's state as the view model knows it, in the order the iPhone checks it.
    @MainActor
    init(vm: OrbitWatchViewModel) {
        if vm.isOnline {
            self = vm.sessionLocked ? .locked : .online
        } else if !vm.hasDirectCredentials && vm.savedPCs.isEmpty {
            self = .setup
        } else if vm.isWakingUp {
            self = .waking
        } else if vm.hasCheckedConnection {
            self = .offline
        } else {
            self = .connecting
        }
    }
}

/// Screen-size decisions for the smallest watches (40 and 41 mm).
enum WatchScreen {
    static var bounds: CGRect { WKInterfaceDevice.current().screenBounds }
    static var isCompact: Bool { bounds.width < 180 }
}

// MARK: - Shared pieces

/// One reading on the wrist: a small label over a big condensed number.
struct WatchReadingView: View {
    var vital: OrbitVital
    var valueSize: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Text(vital.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: vital.unit == "%" ? 1 : 3) {
                Text(vital.value ?? "—")
                    .font(.orbitReading(valueSize))
                    .foregroundStyle(vital.value == nil ? Color.secondary : vital.color)
                    .orbitLiveNumber()
                if let unit = vital.unit, vital.value != nil {
                    Text(unit)
                        .font(.orbitReading(valueSize * 0.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The result of the last action, for a few seconds. Errors are also read out by VoiceOver.
struct WatchFeedbackLine: View {
    @ObservedObject var vm: OrbitWatchViewModel

    var body: some View {
        Group {
            if let feedback = vm.feedback {
                Text(feedback.text)
                    .font(.footnote)
                    .foregroundStyle(feedback.isError ? OrbitPalette.warm : .secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .transition(.opacity)
                    .id(feedback.id)
            }
        }
        .watchAnimation(value: vm.feedback)
        .onChange(of: vm.feedback) { _, feedback in
            if let feedback, feedback.isError {
                AccessibilityNotification.Announcement(feedback.text).post()
            }
        }
    }
}

/// A quiet sentence under a state or a control: what to do next.
struct WatchHint: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    /// `OrbitMotion.standard` for state changes, or none when Reduce Motion is on.
    func watchAnimation<Value: Equatable>(value: Value) -> some View {
        modifier(WatchStateAnimation(value: value))
    }
}

private struct WatchStateAnimation<Value: Equatable>: ViewModifier {
    var value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : OrbitMotion.standard, value: value)
    }
}

extension View {
    /// Watch buttons. The one primary action on a screen gets the accent's prominent glass;
    /// every other button is neutral glass, so the accent keeps meaning "do this".
    @ViewBuilder
    func watchButton(prominent: Bool = false) -> some View {
        if prominent {
            orbitGlassButton(prominent: true)
                .buttonBorderShape(.roundedRectangle)
        } else {
            orbitGlassButton()
                .buttonBorderShape(.roundedRectangle)
                .tint(nil)
        }
    }
}

/// Buttons that sit three across (clicks, playback, volume steps). The glass hugs the label,
/// so a short word still fits under its icon on a 40 mm watch. Prominent ones take the accent.
struct WatchRowButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        WatchRowButtonBody(configuration: configuration, prominent: prominent, tint: tint)
    }
}

private struct WatchRowButtonBody: View {
    var configuration: ButtonStyleConfiguration
    var prominent: Bool
    var tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.vertical, 7)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: 44)
            .orbitGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                        tint: prominent ? tint : nil, interactive: true)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(OrbitMotion.quick, value: configuration.isPressed)
    }
}

/// A full-width button label: icon and title, or a spinner while the action runs.
struct WatchButtonLabel: View {
    var title: String
    var systemImage: String
    var isWorking = false
    var alignment: Alignment = .center
    /// Red text on neutral glass, as destructive rows read on iPhone; the action still asks first.
    var isDestructive = false

    var body: some View {
        let label = HStack(spacing: 8) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20)
            } else {
                Image(systemName: systemImage)
                    .frame(width: 20)
            }
            Text(title)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            if alignment == .leading { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        if isDestructive {
            label.foregroundStyle(OrbitPalette.critical)
        } else {
            label
        }
    }
}

extension View {
    /// DEBUG: `-OrbitWatchScroll bottom` opens every page scrolled to its end, for screenshots.
    func watchDebugScrollAnchor() -> some View {
        #if DEBUG
        defaultScrollAnchor(WatchDebugOptions.scrollsToBottom ? .bottom : .top)
        #else
        self
        #endif
    }

    /// DEBUG: the same for lists, which scroll to their row marked `.id("end")`.
    func watchDebugScrollToEnd(_ proxy: ScrollViewProxy) -> some View {
        #if DEBUG
        task {
            guard WatchDebugOptions.scrollsToBottom else { return }
            try? await Task.sleep(for: .milliseconds(600))
            proxy.scrollTo("end", anchor: .bottom)
        }
        #else
        self
        #endif
    }
}

#if DEBUG
/// Launch arguments read by views in DEBUG builds; see `applyDebugLaunchOptions`.
enum WatchDebugOptions {
    static var scrollsToBottom: Bool { UserDefaults.standard.string(forKey: "OrbitWatchScroll") == "bottom" }
    /// `-OrbitWatchSheet unlock|pcs|options|games|sleep|shutdown|quit` opens that sheet or dialog.
    static var sheet: String? { UserDefaults.standard.string(forKey: "OrbitWatchSheet") }
    /// `-OrbitWatchCrown 1` starts the page's Digital Crown control (scroll or volume).
    static var crownActive: Bool { UserDefaults.standard.bool(forKey: "OrbitWatchCrown") }
    /// `-OrbitWatchGallery status|cpu|gpu|fps|control` shows the complication gallery.
    static var gallery: String? { UserDefaults.standard.string(forKey: "OrbitWatchGallery") }
    /// `-OrbitWatchTextSize xxxLarge|accessibility2` stands in for a larger Dynamic Type setting.
    static var typeSize: DynamicTypeSize? {
        switch UserDefaults.standard.string(forKey: "OrbitWatchTextSize") {
        case "xLarge": return .xLarge
        case "xxLarge": return .xxLarge
        case "xxxLarge": return .xxxLarge
        case "accessibility1": return .accessibility1
        case "accessibility2": return .accessibility2
        case "accessibility3": return .accessibility3
        default: return nil
        }
    }
}
#endif
