import SwiftUI
import UIKit

/// Haptic feedback, in one place. Every call respects the stored "orbit.haptics" switch, so
/// the whole app can be silenced at once.
enum OrbitHaptics {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "orbit.haptics") as? Bool ?? true
    }
    static func tap() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func press() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    static func selection() {
        guard isEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func success() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func warning() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    static func error() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

extension Color {
    /// A color from a six-digit hex string such as "0A84FF"; Orbit Blue's neighbor when invalid.
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let rgb = hex.count == 6 ? value : 0x00B4FF
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, opacity: 1)
    }
}
