import SwiftUI

// Building blocks for the iPhone's secondary screens, in the PC tab's language: a black
// canvas, solid surfaces, Title Case section headers, plain rows separated by hairlines.

/// A scrolling page on the canvas with the PC tab's margins and reading width.
struct OrbitPage<Content: View>: View {
    var spacing: CGFloat = OrbitMetrics.sectionSpacing
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content()
            }
            .padding(.horizontal, OrbitMetrics.gutter)
            .padding(.top, 4)
            .padding(.bottom, 36)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(OrbitPalette.canvas)
    }
}

/// A Title Case header over a solid surface. Rows inside are separated by hairlines.
struct OrbitGroup<Content: View, Trailing: View>: View {
    var title: String?
    var footer: String?
    var trailing: Trailing
    var content: Content

    init(_ title: String? = nil, footer: String? = nil,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                OrbitSectionHeader(title) { trailing }
            }
            OrbitRows { content }
                .orbitSurface(padding: 16, radius: 22)
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

extension OrbitGroup where Trailing == EmptyView {
    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, footer: footer, trailing: { EmptyView() }, content: content)
    }
}

/// Stacks rows with a hairline between neighbours, like the rows of a grouped list.
struct OrbitRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { rows in
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Divider().overlay(OrbitPalette.hairline)
                    }
                    row
                }
            }
        }
    }
}

/// A label and its value, the way "This PC" lists them.
struct OrbitValueRow: View {
    var title: String
    var value: String
    var valueColor: Color = .primary

    init(_ title: String, _ value: String, valueColor: Color = .primary) {
        self.title = title
        self.value = value
        self.valueColor = valueColor
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .font(.subheadline)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// The label of a row that opens something: a title, an optional value, a chevron.
struct OrbitChevronRow: View {
    var title: String
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// What a screen shows when it has nothing to show: a quiet symbol, what happened, what to
/// do next, and the one action that fixes it.
struct OrbitEmptyMessage: View {
    var systemImage: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 16)
    }
}

/// One line of feedback under a control. Problems take the warm status color; everything
/// else stays quiet.
struct OrbitInlineStatus: View {
    enum Kind { case info, success, problem }

    var text: String
    var kind: Kind = .info

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(kind == .problem ? AnyShapeStyle(OrbitPalette.warm) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
        .font(.footnote)
        .textSelection(.enabled)
    }

    private var symbol: String {
        switch kind {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .problem: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .info: return .secondary
        case .success: return OrbitPalette.online
        case .problem: return OrbitPalette.warm
        }
    }
}

/// A feature or a fact: a plain symbol in the accent, a short title and one sentence.
struct OrbitFeatureRow: View {
    var systemImage: String
    var title: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A numbered step, as in the welcome flow.
struct OrbitStepRow<Accessory: View>: View {
    var number: Int
    var title: String
    var text: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .frame(width: 32, height: 32)
                .background(OrbitPalette.well, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }
}

extension OrbitStepRow where Accessory == EmptyView {
    init(number: Int, title: String, text: String) {
        self.init(number: number, title: title, text: text) { EmptyView() }
    }
}

extension View {
    /// Lists and forms on the black canvas.
    func orbitListBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(OrbitPalette.canvas)
    }

    /// The standard close button of a sheet, monochrome like every toolbar item.
    func orbitCloseButton(placement: ToolbarItemPlacement = .topBarTrailing, action: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem(placement: placement) {
                Button(role: .close, action: action)
                    .tint(.primary)
            }
        }
    }
}

/// Number formatting shared by the secondary screens.
enum OrbitScreenFormat {
    /// "6.3 GB" or "690 MB" from megabytes.
    static func megabytes(_ value: Double?) -> String? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        if value >= 1024 { return (value / 1024).formatted(.number.precision(.fractionLength(1))) + " GB" }
        return "\(Int(value.rounded())) MB"
    }

    /// "23%" from a 0…100 value.
    static func percent(_ value: Double?) -> String? {
        OrbitFormat.percent(value).map { "\($0)%" }
    }

    /// One decimal at most, without trailing zeros: "16", "1.5".
    static func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)))
    }
}
