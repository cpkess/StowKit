import Foundation
import SwiftData

enum ArchiveSchemaV7: VersionedSchema {
    static var versionIdentifier = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] {
        ArchiveSchemaV6.models + [Collection.self, Membership.self, CloudState.self, CloudBinding.self, OriginalState.self, TextDownload.self, TextUpload.self]
    }
    @Model final class Collection {
        @Attribute(.unique) var id: UUID
        var name: String
        var symbol: String
        var localName: String
        init(id: UUID, name: String, symbol: String, localName: String) {
            self.id = id; self.name = name; self.symbol = symbol; self.localName = localName
        }
    }
    @Model final class Membership {
        @Attribute(.unique) var key: String
        var documentID: UUID
        var collectionID: UUID
        var active: Bool
        init(documentID: UUID, collectionID: UUID, active: Bool) {
            key = "\(documentID):\(collectionID)"; self.documentID = documentID
            self.collectionID = collectionID; self.active = active
        }
    }
    @Model final class CloudState {
        @Attribute(.unique) var key: String
        var systemFields: Data
        var wireMetadata: Data
        init(key: String, systemFields: Data, wireMetadata: Data) {
            self.key = key; self.systemFields = systemFields; self.wireMetadata = wireMetadata
        }
    }
    @Model final class CloudBinding {
        @Attribute(.unique) var key: String
        var payload: Data
        var enabled: Bool
        init(payload: Data) { key = "binding"; self.payload = payload; enabled = true }
    }
    @Model final class TextDownload {
        @Attribute(.unique) var hash: String
        var payload: Data
        init(hash: String, payload: Data) { self.hash = hash; self.payload = payload }
    }
    @Model final class TextUpload {
        @Attribute(.unique) var documentID: UUID
        var operationID: UUID
        init(documentID: UUID) { self.documentID = documentID; operationID = UUID() }
    }
    @Model final class OriginalState {
        @Attribute(.unique) var documentID: UUID
        var cloudVerified: Bool
        var pinned: Bool
        var remote: Bool
        var textRevision: String?
        init(documentID: UUID, remote: Bool) {
            self.documentID = documentID; self.remote = remote; cloudVerified = false; pinned = false
        }
    }
}

// V7 was exercised locally before macOS 27 exposed the inherited `hash` name collision.
// Keep its model frozen and migrate the payload into a safely named queue column.
enum ArchiveSchemaV8: VersionedSchema {
    static var versionIdentifier = Schema.Version(8, 0, 0)
    static var models: [any PersistentModel.Type] {
        ArchiveSchemaV7.models.filter { $0 != ArchiveSchemaV7.TextDownload.self } + [TextDownload.self]
    }
    @Model final class TextDownload {
        @Attribute(.unique, originalName: "hash") var sourceHash: String
        var payload: Data
        init(hash: String, payload: Data) { sourceHash = hash; self.payload = payload }
    }
}
