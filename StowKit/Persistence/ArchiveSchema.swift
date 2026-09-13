import Foundation
import SwiftData

// This is the first disk schema. Future releases must add a new version and a migration.
enum ArchiveSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [DocumentRecord.self, CollectionRecord.self, ArchiveRecord.self] }

    @Model final class DocumentRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var contentHash: String
        var archiveID: UUID
        var title: String
        var originalFilename: String
        var correspondent: String
        var documentDate: Date
        var importedAt: Date
        var modifiedAt: Date
        var summary: String
        var collectionNames: [String]
        var tags: String
        var entities: String
        var favorite: Bool
        var needsReview: Bool
        var trashedAt: Date?
        var contentType: String
        var fileSize: Int64
        var relativePath: String

        init(_ document: HouseholdDocument) {
            id = document.id
            contentHash = document.contentHash
            archiveID = document.archiveID
            title = document.title
            originalFilename = document.originalFilename
            correspondent = document.correspondent
            documentDate = document.documentDate
            importedAt = document.importedAt
            modifiedAt = document.modifiedAt
            summary = document.summary
            collectionNames = document.collections.sorted()
            tags = document.tags
            entities = document.entities
            favorite = document.favorite
            needsReview = document.needsReview
            trashedAt = document.trashedAt
            contentType = document.contentType
            fileSize = document.fileSize
            relativePath = document.relativePath
        }
        func updateMetadata(from document: HouseholdDocument) {
            title = document.title
            correspondent = document.correspondent
            documentDate = document.documentDate
            modifiedAt = document.modifiedAt
            summary = document.summary
            collectionNames = document.collections.sorted()
            tags = document.tags
            entities = document.entities
            favorite = document.favorite
            needsReview = document.needsReview
            trashedAt = document.trashedAt
        }
        var document: HouseholdDocument {
            HouseholdDocument(id: id, archiveID: archiveID, title: title, originalFilename: originalFilename,
                correspondent: correspondent, documentDate: documentDate, importedAt: importedAt,
                modifiedAt: modifiedAt, summary: summary, collections: Set(collectionNames), tags: tags,
                entities: entities, favorite: favorite, needsReview: needsReview, trashedAt: trashedAt,
                contentType: contentType, contentHash: contentHash, fileSize: fileSize, relativePath: relativePath)
        }
    }

    @Model final class CollectionRecord {
        @Attribute(.unique) var name: String
        var symbol: String
        init(_ collection: LibraryCollection) { name = collection.name; symbol = collection.symbol }
    }

    @Model final class ArchiveRecord {
        @Attribute(.unique) var key: String
        var id: UUID
        init() { key = "local-household"; id = UUID() }
    }
}

enum ArchiveMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ArchiveSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
