import Foundation
import SwiftData

extension TextSearchService {
    func analysisInput(_ document: HouseholdDocument, collections: [String]) throws -> UnderstandingInput {
        let context = ModelContext(modelContainer)
        let id = document.id
        var descriptor = FetchDescriptor<Page>(predicate: #Predicate { $0.documentID == id }, sortBy: [SortDescriptor(\.pageIndex)])
        let count = try context.fetchCount(descriptor)
        descriptor.fetchLimit = 8
        let pages = try context.fetch(descriptor)
        var bytes: [UInt8] = []
        var truncated = count > pages.count
        for page in pages {
            let remaining = max(0, 4_000 - bytes.count)
            if page.text.utf8.count + 1 > remaining { truncated = true }
            bytes.append(contentsOf: (page.text + "\n").utf8.prefix(remaining))
        }
        return UnderstandingInput(document: document, text: String(decoding: bytes, as: UTF8.self), collections: collections, truncated: truncated)
    }
    func recoverAnalysisQueue() throws {
        typealias Analysis = ArchiveSchemaV4.AnalysisRecord
        typealias Marker = ArchiveSchemaV3.MaintenanceRecord
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let key = "analysis-backfill-v4"
        if try context.fetch(FetchDescriptor<Marker>(predicate: #Predicate { $0.key == key })).isEmpty {
            var offset = 0
            while true {
                let batch = ModelContext(modelContainer)
                batch.autosaveEnabled = false
                var descriptor = FetchDescriptor<Record>(sortBy: [SortDescriptor(\.importedAt), SortDescriptor(\.id)])
                descriptor.fetchOffset = offset; descriptor.fetchLimit = 128
                let records = try batch.fetch(descriptor)
                if records.isEmpty { break }
                let ids = records.map(\.id)
                let known = Set(try batch.fetch(FetchDescriptor<Analysis>(predicate: #Predicate { ids.contains($0.documentID) })).map(\.documentID))
                let complete = "complete"
                let ready = Set(try batch.fetch(FetchDescriptor<Job>(predicate: #Predicate { ids.contains($0.documentID) && $0.state == complete })).map(\.documentID))
                for record in records where !known.contains(record.id) {
                    batch.insert(Analysis(record.id, state: record.trashedAt != nil ? "paused" : (ready.contains(record.id) ? "queued" : "waitingText"), protected: UnderstandingPolicy.fields))
                }
                try batch.save(); offset += records.count
            }
            context.insert(Marker(key)); try context.save()
        }
        let active = "analyzing"
        for job in try context.fetch(FetchDescriptor<Analysis>(predicate: #Predicate { $0.state == active })) {
            job.state = "queued"; job.revision += 1
        }
        try context.save()
    }
}
