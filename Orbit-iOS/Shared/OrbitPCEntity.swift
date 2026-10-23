import AppIntents
import Foundation

/// A paired PC as Shortcuts, Siri and Spotlight see it. Every Orbit Shortcuts action takes an
/// optional `pc`; leaving it empty means the default PC chosen in Orbit.
///
/// The list comes from `OrbitWidgetConnectionStore.connections()` in the App Group, so the app, the
/// widget extension and Siri all see the same PCs. Compiled into Orbit and OrbitWidgets.
///
/// The telemetry widgets keep their own `OrbitWidgetPC` type (OrbitTelemetryWidgets.swift): saved
/// widget configurations refer to that entity type by name, so it stays as it is and only reuses
/// the lookups below.
struct OrbitPCEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "PC")
    static let defaultQuery = OrbitPCEntityQuery()

    /// The PC profile id (`OrbitWidgetConnection.id`), stable across renames and address changes.
    let id: String

    @Property(title: "Name")
    var name: String

    /// The saved address, shown under the name in pickers.
    var host: String

    init(id: String, name: String, host: String = "") {
        self.id = id
        self.host = host
        self.name = name
    }

    init(_ connection: OrbitWidgetConnection) {
        self.init(id: connection.id, name: connection.name.isEmpty ? "PC" : connection.name, host: connection.host)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: host.isEmpty ? nil : "\(host)",
            image: DisplayRepresentation.Image(systemName: "desktopcomputer")
        )
    }

    /// Saved PCs, the default PC first, then by name.
    static func all() -> [OrbitPCEntity] {
        let defaultID = OrbitWidgetConnectionStore.defaultConnection()?.id
        return OrbitWidgetConnectionStore.connections()
            .sorted { lhs, rhs in
                if (lhs.id == defaultID) != (rhs.id == defaultID) { return lhs.id == defaultID }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map(OrbitPCEntity.init)
    }

    static func defaultPC() -> OrbitPCEntity? {
        OrbitWidgetConnectionStore.defaultConnection().map(OrbitPCEntity.init)
    }
}

struct OrbitPCEntityQuery: EntityStringQuery {
    /// A shortcut that still names a PC removed from Orbit gets a "Removed PC" placeholder instead of
    /// nothing. An empty value would quietly run the action on the default PC, which could be a
    /// different computer; the placeholder makes the action stop with an explanation instead.
    func entities(for identifiers: [OrbitPCEntity.ID]) async throws -> [OrbitPCEntity] {
        let saved = OrbitPCEntity.all()
        return identifiers.map { id in saved.first { $0.id == id } ?? OrbitPCEntity(id: id, name: "Removed PC") }
    }

    func entities(matching string: String) async throws -> [OrbitPCEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = OrbitPCEntity.all()
        guard !query.isEmpty else { return saved }
        return saved.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.host.localizedCaseInsensitiveContains(query) }
    }

    func suggestedEntities() async throws -> [OrbitPCEntity] {
        OrbitPCEntity.all()
    }

    func defaultResult() async -> OrbitPCEntity? {
        OrbitPCEntity.defaultPC()
    }
}
