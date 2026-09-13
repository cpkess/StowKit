import Foundation
import SwiftData

// Existing V1 models are unchanged. Adding processing tables is a lightweight migration.
enum ArchiveSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        ArchiveSchemaV1.models + [ProcessingJobRecord.self, PageTextRecord.self]
    }

    @Model final class ProcessingJobRecord {
        @Attribute(.unique) var documentID: UUID
        var state: String
        var completedPages: Int
        var pageCount: Int
        var characterCount: Int
        var ocrPages: Int
        var attempts: Int
        var lastError: String?
        var failedStage: String?
        var createdAt: Date
        var updatedAt: Date
        var extractorVersion: Int

        init(documentID: UUID, paused: Bool = false) {
            self.documentID = documentID
            state = paused ? ProcessingState.paused.rawValue : ProcessingState.queued.rawValue
            completedPages = 0; pageCount = 0; characterCount = 0; ocrPages = 0; attempts = 0
            createdAt = Date(); updatedAt = Date(); extractorVersion = 1
        }
        var snapshot: ProcessingSnapshot {
            ProcessingSnapshot(id: documentID, state: ProcessingState(rawValue: state) ?? .failed,
                completedPages: completedPages, pageCount: pageCount, characterCount: characterCount,
                ocrPages: ocrPages, attempts: attempts, error: lastError, failedStage: failedStage, updatedAt: updatedAt)
        }
    }

    @Model final class PageTextRecord {
        @Attribute(.unique) var key: String
        var documentID: UUID
        var pageIndex: Int
        var text: String
        var searchText: String
        var method: String
        init(documentID: UUID, pageIndex: Int, page: ExtractedPage) {
            key = "\(documentID.uuidString):\(pageIndex)"
            self.documentID = documentID
            self.pageIndex = pageIndex
            text = page.text
            searchText = TextNormalization.searchKey(page.text)
            method = page.method.rawValue
        }
    }
}
