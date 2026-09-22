import Foundation
import SwiftData

/// Construct off-main. All index I/O, backfill, and page-text reads run on this model actor.
@ModelActor actor TextSearchService {
    typealias Page = ArchiveSchemaV2.PageTextRecord
    typealias Record = ArchiveSchemaV9.DocumentRecord
    typealias Change = ArchiveSchemaV3.SearchChangeRecord
    typealias Job = ArchiveSchemaV2.ProcessingJobRecord
    private var index: FullTextIndex?
    private var indexURL: URL?
    private var archiveID: UUID?

    func configure(root: URL, archiveID: UUID) throws {
        indexURL = root.appendingPathComponent("Search/Search.sqlite")
        self.archiveID = archiveID
        try openIndex()
    }
    private func openIndex() throws {
        guard let indexURL, let archiveID else { throw ArchiveError.missingRecord }
        do { index = try FullTextIndex(url: indexURL, archiveID: archiveID) }
        catch let error as FullTextIndex.Failure where error.code == 11 || error.code == 26 {
            // Only the disposable search cache is removed, never the authoritative archive.
            for suffix in ["", "-wal", "-shm"] {
                let url = URL(fileURLWithPath: indexURL.path + suffix)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            index = try FullTextIndex(url: indexURL, archiveID: archiveID)
        }
    }
    func rebuild() throws {
        if index == nil { try openIndex() }
        try index?.reset()
        try synchronize()
    }
    /// No suspension inside synchronization: commits and acknowledgements are serialized.
    /// Other contexts may append newer receipts; only receipts read by this pass are deleted.
    func synchronize() throws {
        if index == nil { try openIndex() }
        guard let index else { throw ArchiveError.missingRecord }
        if try !index.isBuilt {
            var offset = 0
            while true {
                try Task.checkCancellation()
                let context = ModelContext(modelContainer)
                var descriptor = FetchDescriptor<Record>(sortBy: [SortDescriptor(\.importedAt), SortDescriptor(\.id)])
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = 64
                let documents = try context.fetch(descriptor).map(\.document)
                if documents.isEmpty { break }
                try export(documents, context: context, index: index)
                offset += documents.count
            }
            // Edits/imports during backfill are replayed below. An interrupted build restarts safely.
            try index.finishBuild()
        }
        while true {
            try Task.checkCancellation()
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false
            var descriptor = FetchDescriptor<Change>(sortBy: [SortDescriptor(\.createdAt)])
            descriptor.fetchLimit = 256
            let changes = try context.fetch(descriptor)
            if changes.isEmpty { break }
            let ids = Array(Set(changes.map(\.documentID)))
            let documents = try context.fetch(FetchDescriptor<Record>(predicate: #Predicate { ids.contains($0.id) })).map(\.document)
            try export(documents, context: context, index: index, removing: ids)
            // A crash before this save merely causes an idempotent replay.
            for change in changes { context.delete(change) }
            try context.save()
        }
    }
    private func export(_ documents: [HouseholdDocument], context: ModelContext, index: FullTextIndex, removing: [UUID] = []) throws {
        let ids = documents.map(\.id)
        let pages = try context.fetch(FetchDescriptor<Page>(predicate: #Predicate { ids.contains($0.documentID) }, sortBy: [SortDescriptor(\.pageIndex)]))
        let grouped = Dictionary(grouping: pages, by: \.documentID)
        let failed = "failed"
        let failures = Set(try context.fetch(FetchDescriptor<Job>(predicate: #Predicate { ids.contains($0.documentID) && $0.state == failed })).map(\.documentID))
        try index.transaction {
            for id in removing { try index.remove(id.uuidString) }
            for document in documents {
                try index.replace(document, body: grouped[document.id, default: []].map(\.text).joined(separator: "\n\n"), failed: failures.contains(document.id))
            }
        }
    }
    func search(_ query: String, destination: LibraryDestination?, filter: LibraryFilter = LibraryFilter(), newestFirst: Bool, offset: Int = 0, limit: Int = 50) throws -> SearchPage {
        try synchronize()
        guard let index else { throw ArchiveError.missingRecord }
        let result = try index.search(query, destination: destination, filter: filter, newestFirst: newestFirst, offset: offset, limit: limit)
        let ids = result.rows.compactMap { UUID(uuidString: $0[0]) }
        let context = ModelContext(modelContainer)
        let documents = try context.fetch(FetchDescriptor<Record>(predicate: #Predicate { ids.contains($0.id) }))
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id.uuidString, $0.document) })
        return SearchPage(hits: result.rows.compactMap { row in
            byID[row[0]].map { SearchHit(document: $0, snippet: row[1]) }
        }, total: result.total, statistics: try index.statistics())
    }

    func facets() throws -> LibraryFacets {
        try synchronize()
        guard let index else { throw ArchiveError.missingRecord }
        return try index.facets()
    }
    /// Browsing remains available if the disposable index cannot be written.
    func browse(destination: LibraryDestination?, newestFirst: Bool, limit: Int = 50) throws -> SearchPage {
        let context = ModelContext(modelContainer)
        let failed = "failed"
        let failedIDs = try context.fetch(FetchDescriptor<Job>(predicate: #Predicate { $0.state == failed })).map(\.documentID)
        let predicate: Predicate<Record>
        switch destination {
        case .trash: predicate = #Predicate { $0.trashedAt != nil }
        case .favorites: predicate = #Predicate { $0.trashedAt == nil && $0.favorite }
        case .inbox: predicate = #Predicate { $0.trashedAt == nil && ($0.needsReview || failedIDs.contains($0.id)) }
        case .collection: predicate = #Predicate { $0.trashedAt == nil }
        default: predicate = #Predicate { $0.trashedAt == nil }
        }
        var descriptor = FetchDescriptor<Record>(predicate: predicate, sortBy: newestFirst ? [SortDescriptor(\.importedAt, order: .reverse), SortDescriptor(\.id)] : [SortDescriptor(\.title), SortDescriptor(\.id)])
        if case .collection(let name) = destination {
            // collectionNames is a frozen transformable array. SwiftData's SQL translation
            // of contains on it can crash; filter bounded batches only in this error fallback.
            var offset = 0, count = 0
            var hits: [SearchHit] = []
            descriptor.fetchLimit = 256
            while true {
                try Task.checkCancellation()
                descriptor.fetchOffset = offset
                let batch = try ModelContext(modelContainer).fetch(descriptor).map(\.document)
                if batch.isEmpty { break }
                for document in batch where document.collections.contains(name) {
                    count += 1
                    if hits.count < limit { hits.append(SearchHit(document: document, snippet: "")) }
                }
                offset += batch.count
            }
            return SearchPage(hits: hits, total: count, statistics: LibraryStatistics())
        }
        let count = try context.fetchCount(descriptor)
        descriptor.fetchLimit = limit
        let hits = try context.fetch(descriptor).map { SearchHit(document: $0.document, snippet: "") }
        return SearchPage(hits: hits, total: count, statistics: LibraryStatistics())
    }

    /// Migration backfill is bounded and runs once. Normal launches only inspect interrupted jobs.
    func recoverProcessingQueue() throws {
        typealias Marker = ArchiveSchemaV3.MaintenanceRecord
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let key = "processing-backfill-v3"
        if try context.fetch(FetchDescriptor<Marker>(predicate: #Predicate { $0.key == key })).isEmpty {
            var offset = 0
            while true {
                let batch = ModelContext(modelContainer)
                batch.autosaveEnabled = false
                var descriptor = FetchDescriptor<Record>(sortBy: [SortDescriptor(\.importedAt), SortDescriptor(\.id)])
                descriptor.fetchOffset = offset; descriptor.fetchLimit = 256
                let documents = try batch.fetch(descriptor)
                if documents.isEmpty { break }
                let ids = documents.map(\.id)
                let known = Set(try batch.fetch(FetchDescriptor<Job>(predicate: #Predicate { ids.contains($0.documentID) })).map(\.documentID))
                for document in documents where !known.contains(document.id) {
                    batch.insert(Job(documentID: document.id, paused: document.trashedAt != nil))
                }
                try batch.save()
                offset += documents.count
            }
            context.insert(Marker(key)); try context.save()
        }
        let extracting = "extractingText", saving = "savingText"
        let jobs = try context.fetch(FetchDescriptor<Job>(predicate: #Predicate { $0.state == extracting || $0.state == saving }))
        for job in jobs {
            let id = job.documentID
            let document = try context.fetch(FetchDescriptor<Record>(predicate: #Predicate { $0.id == id })).first
            job.state = document?.trashedAt == nil ? "queued" : "paused"
            job.updatedAt = Date()
        }
        try context.save()
    }


    func pages(for id: UUID) throws -> [ExtractedTextPage] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Page>(predicate: #Predicate { $0.documentID == id }, sortBy: [SortDescriptor(\.pageIndex)])
        return try context.fetch(descriptor).map {
            ExtractedTextPage(index: $0.pageIndex, text: $0.text, method: ExtractionMethod(rawValue: $0.method) ?? .ocr)
        }
    }
}
