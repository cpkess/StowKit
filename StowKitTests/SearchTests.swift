import XCTest
import SwiftData
@testable import StowKit

@MainActor final class SearchTests: XCTestCase {
    private var root: URL!
    private var repository: ArchiveRepository!
    private var service: TextSearchService!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitSearchTests-\(UUID())")
        repository = try ArchiveRepository(root: root)
        service = await makeService()
        try await service.configure(root: root, archiveID: repository.archiveID)
    }
    override func tearDown() async throws {
        service = nil; repository = nil
        try? FileManager.default.removeItem(at: root)
    }
    private func makeService() async -> TextSearchService {
        let container = repository.container
        return await Task.detached { TextSearchService(modelContainer: container) }.value
    }
    private func document(_ title: String, number: Int = 0) -> HouseholdDocument {
        let id = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000 + Double(number))
        return HouseholdDocument(id: id, archiveID: repository.archiveID, title: title, originalFilename: "fixture.pdf",
            documentDate: date, importedAt: date, modifiedAt: date, contentType: "com.adobe.pdf",
            contentHash: id.uuidString, fileSize: 1234, relativePath: "Originals/\(id.uuidString.prefix(2))/\(id).pdf")
    }
    private func add(_ document: HouseholdDocument, pages: [String] = []) throws {
        try repository.insert(document)
        if !pages.isEmpty {
            _ = try repository.setPageCount(document.id, count: pages.count)
            for (index, text) in pages.enumerated() { _ = try repository.savePage(document.id, index: index, result: .init(text: text, method: .embedded)) }
            _ = try repository.setProcessingState(document.id, .complete)
        }
    }
    private func search(_ query: String, scope: LibraryDestination = .recent, offset: Int = 0, limit: Int = 50) async throws -> SearchPage {
        try await service.search(query, destination: scope, newestFirst: true, offset: offset, limit: limit)
    }
    func testRankingPrefixAccentPhraseAndSnippet() async throws {
        let title = document("Café refrigerator warranty")
        let body = document("Appliance records", number: 1)
        try add(title, pages: ["Parts are covered."])
        try add(body, pages: ["Your café refrigerator warranty includes repairs."])
        let ranked = try await search("cafe refrig")
        XCTAssertEqual(ranked.hits.map(\.document.id), [title.id, body.id])
        XCTAssertTrue(ranked.hits[0].snippet.contains("\u{E000}"))
        let phrase = try await search("\"refrigerator warranty\"")
        XCTAssertEqual(phrase.total, 2)
        let reversed = try await search("\"warranty refrigerator\"")
        XCTAssertEqual(reversed.total, 0)
    }
    func testTermsCanMatchDifferentFieldsAndPages() async throws {
        var record = document("Home insurance")
        record.correspondent = "Acme"
        record.tags = "2026 renewal"
        record.entities = "Navigator"
        record.collections = ["Vehicles"]
        try add(record, pages: ["Collision protection", "Deductible details"])
        let result = try await search("acme navigat collision deduct renewal vehicles")
        XCTAssertEqual(result.hits.first?.document.id, record.id)
    }
    func testLiteralOperatorsPunctuationAndQuotesCannotBroadenSearch() async throws {
        try add(document("Home policy"), pages: ["renewal"])
        for query in ["!!!", "\"", "home OR missing", "home' UNION SELECT", "*", "NEAR(home renewal)"] {
            let result = try await search(query)
            XCTAssertEqual(result.total, 0, query)
        }
        let quote = try await search("\"home policy")
        XCTAssertEqual(quote.total, 1)
    }
    func testMetadataAndScopesUpdateIncrementally() async throws {
        var record = document("Old title")
        record.needsReview = false
        try add(record)
        _ = try await search("")
        record.title = "New title"
        record.favorite = true
        record.collections = ["Appliances"]
        try repository.update(record)
        let old = try await search("old")
        XCTAssertEqual(old.total, 0)
        let updated = try await search("new", scope: .favorites)
        XCTAssertEqual(updated.hits.first?.document, record)
        let collection = try await search("new", scope: .collection("Appliances"))
        XCTAssertEqual(collection.total, 1)
        _ = try repository.setProcessingState(record.id, .failed, error: "test")
        let inbox = try await search("new", scope: .inbox)
        XCTAssertEqual(inbox.total, 1)
        record.trashedAt = Date()
        try repository.update(record)
        let active = try await search("new")
        let trash = try await search("new", scope: .trash)
        XCTAssertEqual(active.total, 0)
        XCTAssertEqual(trash.total, 1)
        XCTAssertEqual(trash.statistics.trash, 1)
        record.trashedAt = nil
        try repository.update(record)
        let restored = try await search("new")
        XCTAssertEqual(restored.total, 1)
    }
    func testResetExtractionRemovesStaleText() async throws {
        let record = document("Scan")
        try add(record, pages: ["obsoleteword"])
        let before = try await search("obsoleteword")
        XCTAssertEqual(before.total, 1)
        _ = try repository.retryProcessing(record.id, restart: true)
        let after = try await search("obsoleteword")
        XCTAssertEqual(after.total, 0)
    }
    func testJournalSurvivesReopenAndRebuildIsIdempotent() async throws {
        var record = document("First")
        try add(record, pages: ["insurance renewal"])
        _ = try await search("")
        record.title = "Latest"
        try repository.update(record)
        let context = ModelContext(repository.container)
        XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<ArchiveSchemaV3.SearchChangeRecord>()), 0)
        service = nil
        service = await makeService()
        try await service.configure(root: root, archiveID: repository.archiveID)
        let replay = try await search("latest renewal")
        XCTAssertEqual(replay.total, 1)
        let fresh = ModelContext(repository.container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<ArchiveSchemaV3.SearchChangeRecord>()), 0)
        try await service.rebuild()
        try await service.rebuild()
        let rebuilt = try await search("latest renewal")
        XCTAssertEqual(rebuilt.total, 1)
    }
    func testMissingAndCorruptCacheRebuildFromSource() async throws {
        let record = document("Preserved")
        try add(record, pages: ["important words"])
        _ = try await search("")
        service = nil
        let cache = root.appendingPathComponent("Search")
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("Not a SQLite database".utf8).write(to: cache.appendingPathComponent("Search.sqlite"))
        service = await makeService()
        try await service.configure(root: root, archiveID: repository.archiveID)
        let recovered = try await search("important")
        XCTAssertEqual(recovered.hits.first?.document.id, record.id)
        XCTAssertEqual(try repository.documents().count, 1)
    }
    func testPaginationAndStoreLoadsOnlyFirstFifty() async throws {
        for number in 0..<123 { try add(document("Record \(number)", number: number)) }
        let first = try await search("", limit: 50)
        let second = try await search("", offset: 50, limit: 50)
        let last = try await search("", offset: 100, limit: 50)
        XCTAssertEqual(first.total, 123)
        XCTAssertEqual(first.hits.count, 50)
        XCTAssertEqual(last.hits.count, 23)
        XCTAssertEqual(Set((first.hits + second.hits + last.hits).map(\.document.id)).count, 123)
        let store = LibraryStore(root: root, processingEnabled: false)
        await store.start()
        XCTAssertEqual(store.documents.count, 50)
        XCTAssertEqual(store.statistics.documents, 123)
        store.loadMore()
        await store.waitForSearch()
        XCTAssertEqual(store.documents.count, 100)
        store.search = "record 122"
        store.search = "record 121"
        await store.waitForSearch()
        XCTAssertEqual(store.documents.map(\.title), ["Record 121"])
        store.showDocument(last.hits.last!.document.id)
        await store.waitForSearch()
        XCTAssertEqual(store.selectedDocument?.id, last.hits.last!.document.id)
    }
    func testV2MigrationIndexesExistingMetadataAndPageText() async throws {
        let legacyRoot = root.appendingPathComponent("Legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let record = document("Legacy policy")
        try seedV2(root: legacyRoot, document: record)
        let migrated = try ArchiveRepository(root: legacyRoot)
        let container = migrated.container
        let reader = await Task.detached { TextSearchService(modelContainer: container) }.value
        try await reader.configure(root: legacyRoot, archiveID: migrated.archiveID)
        try await reader.recoverProcessingQueue()
        let result = try await reader.search("legacy preserved", destination: .recent, newestFirst: true)
        XCTAssertEqual(result.hits.first?.document, record)
        XCTAssertEqual(try migrated.processingJob(record.id)?.snapshot.state, .complete)
    }
    func testIndexWriteFailureKeepsBrowsingAndCanBeRebuilt() async throws {
        let record = document("Readable without an index")
        try add(record)
        service = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent("Search"))
        try Data("Obstruction".utf8).write(to: root.appendingPathComponent("Search"))
        let store = LibraryStore(root: root, processingEnabled: false)
        await store.start()
        XCTAssertTrue(store.isReady)
        XCTAssertNil(store.startupError)
        XCTAssertNotNil(store.textSearchError)
        XCTAssertEqual(store.documents.first?.id, record.id)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Search"))
        store.rebuildSearchIndex()
        await store.waitForSearch()
        XCTAssertFalse(store.isRebuildingIndex)
        XCTAssertNil(store.textSearchError)
        store.search = "readable"
        await store.waitForSearch()
        XCTAssertEqual(store.documents.first?.id, record.id)
    }
    func testFallbackBrowseHonorsCollectionAndTrash() async throws {
        var record = document("Policy")
        record.collections = ["Home"]
        try add(record)
        let home = try await service.browse(destination: .collection("Home"), newestFirst: true)
        let other = try await service.browse(destination: .collection("Vehicles"), newestFirst: true)
        XCTAssertEqual(home.total, 1)
        XCTAssertEqual(other.total, 0)
        record.trashedAt = Date()
        try repository.update(record)
        let active = try await service.browse(destination: .recent, newestFirst: true)
        let trash = try await service.browse(destination: .trash, newestFirst: true)
        XCTAssertEqual(active.total, 0)
        XCTAssertEqual(trash.total, 1)
    }
    func testMultipleReceiptsAndCommittedIndexReplayKeepLatestEdit() async throws {
        var record = document("Before")
        try add(record)
        _ = try await search("")
        // Simulate an index commit whose SwiftData receipt acknowledgement was interrupted.
        record.title = "Committed"
        try repository.update(record)
        let index = try FullTextIndex(url: root.appendingPathComponent("Search/Search.sqlite"), archiveID: repository.archiveID)
        try index.transaction { try index.replace(record, body: "", failed: false) }
        record.title = "Newest"
        try repository.update(record)
        let latest = try await search("newest")
        let stale = try await search("committed")
        XCTAssertEqual(latest.total, 1)
        XCTAssertEqual(stale.total, 0)
        XCTAssertEqual(try ModelContext(repository.container).fetchCount(FetchDescriptor<ArchiveSchemaV3.SearchChangeRecord>()), 0)
    }
    private func seedV2(root: URL, document: HouseholdDocument) throws {
        let schema = Schema(versionedSchema: ArchiveSchemaV2.self)
        let configuration = ModelConfiguration("StowKit", schema: schema, url: root.appendingPathComponent("Library.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let archive = ArchiveSchemaV1.ArchiveRecord(); archive.id = document.archiveID
        context.insert(archive)
        context.insert(ArchiveSchemaV1.DocumentRecord(document))
        let job = ArchiveSchemaV2.ProcessingJobRecord(documentID: document.id)
        job.state = "complete"; job.pageCount = 1; job.completedPages = 1
        context.insert(job)
        context.insert(ArchiveSchemaV2.PageTextRecord(documentID: document.id, pageIndex: 0, page: .init(text: "Preserved extracted words", method: .ocr)))
        try context.save()
    }
}
