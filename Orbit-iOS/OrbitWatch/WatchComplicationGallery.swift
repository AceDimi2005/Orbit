#if DEBUG
import SwiftUI
import WidgetKit

/// DEBUG only (`-OrbitWatchGallery status|cpu|gpu|fps|control`, usually with a fixture):
/// draws one complication in each family it supports, in full color and on a stand-in for a
/// tinted face, at about the size a 46 mm face gives it. Curved corner labels are drawn by the
/// face itself, so the gallery cannot show them.
struct WatchComplicationGallery: View {
    @ObservedObject var vm: OrbitWatchViewModel
    var widget: String

    private let faceTint = Color(red: 1, green: 0.62, blue: 0.2)

    private var entry: WatchComplicationEntry {
        WatchComplicationEntry(date: .now, pcName: vm.pcName,
                               isPaired: vm.hasDirectCredentials || !vm.savedPCs.isEmpty,
                               isOnline: vm.isOnline, isLocked: vm.sessionLocked, telemetry: vm.telemetry,
                               updatedAt: vm.lastTelemetryAt, tintHex: vm.tintHex)
    }

    private var families: [WidgetFamily] {
        widget == "control" ? [.accessoryCircular, .accessoryCorner]
            : [.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    cell(.accessoryCircular, tinted: false)
                    cell(.accessoryCircular, tinted: true)
                    cell(.accessoryCorner, tinted: false)
                    cell(.accessoryCorner, tinted: true)
                }
                if families.contains(.accessoryRectangular) {
                    cell(.accessoryRectangular, tinted: false)
                    cell(.accessoryRectangular, tinted: true)
                }
                if families.contains(.accessoryInline) {
                    cell(.accessoryInline, tinted: false)
                    cell(.accessoryInline, tinted: true)
                }
            }
            .padding(.horizontal, 4)
        }
        .watchDebugScrollAnchor()
        .tint(vm.tint)
    }

    private func cell(_ family: WidgetFamily, tinted: Bool) -> some View {
        complication(family)
            .frame(width: size(family).width, height: size(family).height)
            .environment(\.widgetRenderingMode, tinted ? .accented : .fullColor)
            .environment(\.complicationPreviewTint, tinted ? faceTint : nil)
            .overlay {
                RoundedRectangle(cornerRadius: family == .accessoryRectangular ? 8 : 4)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            }
    }

    @ViewBuilder
    private func complication(_ family: WidgetFamily) -> some View {
        switch widget {
        case "cpu": WatchTemperatureComplication(entry: entry, family: family, component: .processor)
        case "gpu": WatchTemperatureComplication(entry: entry, family: family, component: .graphics)
        case "fps": WatchFrameRateComplication(entry: entry, family: family)
        case "control": WatchControlComplication(entry: entry, family: family)
        default: WatchStatusComplication(entry: entry, family: family)
        }
    }

    private func size(_ family: WidgetFamily) -> CGSize {
        switch family {
        case .accessoryCircular: return CGSize(width: 50, height: 50)
        case .accessoryCorner: return CGSize(width: 32, height: 32)
        case .accessoryRectangular: return CGSize(width: 180, height: 58)
        default: return CGSize(width: 180, height: 20)
        }
    }
}
#endif
