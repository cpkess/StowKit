import Foundation
import SwiftData

/// Construct off-main. Page text is not carried in the eagerly loaded library snapshots.
/// This is an interim database-backed substring search, not Milestone 4's full-text index.
@ModelActor actor TextSearchService {
    typealias Page = ArchiveSchemaV2.PageTextRecord

    func matches(terms: [String]) throws -> [String: Set<UUID>] {
        let context = ModelContext(modelContainer)
        var result: [String: Set<UUID>] = [:]
        for term in terms {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<Page>(predicate: #Predicate { $0.searchText.contains(term) })
            descriptor.propertiesToFetch = [\.documentID]
            result[term] = Set(try context.fetch(descriptor).map(\.documentID))
        }
        return result
    }
    func pages(for id: UUID) throws -> [ExtractedTextPage] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Page>(predicate: #Predicate { $0.documentID == id }, sortBy: [SortDescriptor(\.pageIndex)])
        return try context.fetch(descriptor).map {
            ExtractedTextPage(index: $0.pageIndex, text: $0.text, method: ExtractionMethod(rawValue: $0.method) ?? .ocr)
        }
    }
}
