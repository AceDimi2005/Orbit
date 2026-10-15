import Foundation

@main
struct DashboardConfigurationTests {
    static func main() throws {
        let defaults = DashboardConfiguration.balanced
        precondition(defaults.orderedVisibleMetrics.count == 6)
        var custom = DashboardConfiguration.gaming
        custom.columnCount = 1
        custom.showsGame = false
        custom.showsVolume = false
        custom.showsQuickControls = false
        custom.setVisible(.cpuLoad, false)
        custom.setVisible(.network, true)
        custom.metricOrder.swapAt(0, 1)
        let data = try JSONEncoder().encode(custom)
        let restored = try JSONDecoder().decode(DashboardConfiguration.self, from: data)
        precondition(restored == custom, "Save/load must preserve order, visibility and layout")
        precondition(!restored.orderedVisibleMetrics.contains(.cpuLoad) && restored.orderedVisibleMetrics.contains(.network))
        precondition(restored.activityFocus == .gaming && !restored.showsVolume)

        let future = Data(#"{"metricOrder":["vram","futureMetric","vram","cpuPower"],"visibleMetrics":["futureMetric","cpuPower","cpuPower"],"columnCount":9,"activityFocus":"futureFocus"}"#.utf8)
        let migrated = try JSONDecoder().decode(DashboardConfiguration.self, from: future)
        precondition(migrated.metricOrder.prefix(2) == [.vram, .cpuPower])
        precondition(Set(migrated.metricOrder).count == DashboardMetric.allCases.count)
        precondition(migrated.visibleMetrics == [.cpuPower] && migrated.columnCount == 2 && migrated.activityFocus == .overview)
        let empty = try JSONDecoder().decode(DashboardConfiguration.self, from: Data(#"{"visibleMetrics":[]}"#.utf8))
        precondition(empty.orderedVisibleMetrics.isEmpty, "Hiding every card is an intentional choice")
        let legacy = try JSONDecoder().decode(DashboardConfiguration.self, from: Data("{}".utf8))
        precondition(legacy == defaults)
        precondition(DashboardConfiguration.allMetrics.orderedVisibleMetrics.count == 17)
        print("PASS: dashboard presets, order/visibility/layout round trip, unknown metric migration, empty selection, legacy defaults")
    }
}
