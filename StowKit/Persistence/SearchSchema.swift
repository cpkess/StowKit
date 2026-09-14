import Foundation
import SwiftData

/// Additive migration: the previous document and page models remain unchanged.
enum ArchiveSchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] { ArchiveSchemaV2.models + [SearchChangeRecord.self, MaintenanceRecord.self] }

    /// Append-only receipts prevent an index acknowledgement from losing a newer edit.
    @Model final class SearchChangeRecord {
        @Attribute(.unique) var id: UUID
        var documentID: UUID
        var createdAt: Date
        init(_ documentID: UUID) { id = UUID(); self.documentID = documentID; createdAt = Date() }
    }
    @Model final class MaintenanceRecord {
        @Attribute(.unique) var key: String
        init(_ key: String) { self.key = key }
    }
}

extension ArchiveRepository {
    func markSearchChanged(_ id: UUID) { context.insert(ArchiveSchemaV3.SearchChangeRecord(id)) }
}
