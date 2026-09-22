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

/// Adds a document's type, amount, due date, and expiry date. Only the document record changes;
/// every other model is carried over from V8.
enum ArchiveSchemaV9: VersionedSchema {
    static var versionIdentifier = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] {
        ArchiveSchemaV8.models.filter { $0 != ArchiveSchemaV1.DocumentRecord.self } + [DocumentRecord.self]
    }

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
        // V9. Defaults let lightweight migration fill existing rows.
        var documentType: String = ""
        var amount: String = ""
        var dueDate: Date?
        var expiresAt: Date?

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
            documentType = document.documentType
            amount = document.amount
            dueDate = document.dueDate
            expiresAt = document.expiresAt
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
            documentType = document.documentType
            amount = document.amount
            dueDate = document.dueDate
            expiresAt = document.expiresAt
        }
        var document: HouseholdDocument {
            HouseholdDocument(id: id, archiveID: archiveID, title: title, originalFilename: originalFilename,
                correspondent: correspondent, documentDate: documentDate, importedAt: importedAt,
                modifiedAt: modifiedAt, summary: summary, collections: Set(collectionNames), tags: tags,
                entities: entities, favorite: favorite, needsReview: needsReview, trashedAt: trashedAt,
                contentType: contentType, contentHash: contentHash, fileSize: fileSize, relativePath: relativePath,
                documentType: documentType, amount: amount, dueDate: dueDate, expiresAt: expiresAt)
        }
    }
}

enum ArchiveMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ArchiveSchemaV1.self, ArchiveSchemaV2.self, ArchiveSchemaV3.self, ArchiveSchemaV4.self, ArchiveSchemaV5.self, ArchiveSchemaV6.self, ArchiveSchemaV7.self, ArchiveSchemaV8.self, ArchiveSchemaV9.self] }
    static var stages: [MigrationStage] { [.lightweight(fromVersion: ArchiveSchemaV1.self, toVersion: ArchiveSchemaV2.self), .lightweight(fromVersion: ArchiveSchemaV2.self, toVersion: ArchiveSchemaV3.self), .lightweight(fromVersion: ArchiveSchemaV3.self, toVersion: ArchiveSchemaV4.self), .lightweight(fromVersion: ArchiveSchemaV4.self, toVersion: ArchiveSchemaV5.self), .lightweight(fromVersion: ArchiveSchemaV5.self, toVersion: ArchiveSchemaV6.self), .lightweight(fromVersion: ArchiveSchemaV6.self, toVersion: ArchiveSchemaV7.self), .lightweight(fromVersion: ArchiveSchemaV7.self, toVersion: ArchiveSchemaV8.self), .lightweight(fromVersion: ArchiveSchemaV8.self, toVersion: ArchiveSchemaV9.self)] }
}
