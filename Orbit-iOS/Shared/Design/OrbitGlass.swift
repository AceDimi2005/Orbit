import SwiftUI

/// Liquid Glass belongs to the control layer: buttons, bars and anything that floats over
/// content. These wrappers use the system glass on OS 26 and a material before it.
extension View {
    /// Glass behind a floating control.
    @ViewBuilder
    func orbitGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            self.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    /// Capsule-shaped glass, the default for floating buttons.
    func orbitGlass(tint: Color? = nil, interactive: Bool = false) -> some View {
        orbitGlass(in: Capsule(), tint: tint, interactive: interactive)
    }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// Buttons that live on glass: the system glass styles on OS 26, bordered styles before.
struct OrbitGlassButtonStyleModifier: ViewModifier {
    var prominent: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

extension View {
    func orbitGlassButton(prominent: Bool = false) -> some View {
        modifier(OrbitGlassButtonStyleModifier(prominent: prominent))
    }
}

/// Groups glass shapes so they blend and morph into each other on OS 26.
struct OrbitGlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}
