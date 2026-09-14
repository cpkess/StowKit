import XCTest
import SwiftData
@testable import StowKit

@MainActor final class SyncRecoveryTests: XCTestCase {
    private var root: URL!
    private var repository: ArchiveRepository!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitSyncRecovery-\(UUID())")
        repository = try ArchiveRepository(root: root)
    }
    override func tearDown() async throws {
        repository = nil; try? FileManager.default.removeItem(at: root)
    }
    private func seed(hash: String = UUID().uuidString, legacy: Bool = false) throws -> HouseholdDocument {
        let id = UUID(), date = Date()
        let document = HouseholdDocument(id: id, archiveID: repository.archiveID, title: "Original", originalFilename: "test.pdf",
            documentDate: date, importedAt: date, modifiedAt: date, contentType: "com.adobe.pdf", contentHash: hash,
            fileSize: 4, relativePath: "Originals/\(id.uuidString.prefix(2))/\(id).pdf")
        if legacy { repository.context.insert(ArchiveSchemaV1.DocumentRecord(document)); try repository.save() }
        else { try repository.insert(document) }
        return document
    }
    private func snapshot(_ id: UUID) throws -> SyncMetadata {
        let row = try XCTUnwrap(repository.syncRecord("document:\(id)"))
        return try JSONDecoder().decode(SyncMetadata.self, from: row.payload)
    }
    private func remote(_ metadata: SyncMetadata, field: String, value: SyncValue, manual: Bool = true) -> SyncMetadata {
        var copy = metadata
        copy.fields[field] = SyncField(value: value, manual: manual, operationID: UUID())
        return copy
    }
    private func apply(_ records: [SyncMetadata], to token: String) throws {
        try repository.applyIncomingPage(.init(previousToken: repository.incomingSyncToken(), nextToken: token, records: records))
    }
    private func restart() throws { repository = nil; repository = try ArchiveRepository(root: root) }

    func testBackfillResumesAndPreservesNewerEdits() throws {
        let first = try seed(hash: "a", legacy: true), second = try seed(hash: "b", legacy: true)
        let third = try seed(hash: "c", legacy: true)
        // Collection pages advance first, without scanning documents.
        for _ in 0..<7 { _ = try repository.backfillSyncBatch(limit: 2) }
        XCTAssertNil(try repository.syncRecord("document:\(first.id)"))
        XCTAssertFalse(try repository.backfillSyncBatch(limit: 2))
        XCTAssertEqual(try snapshot(first.id).fields["title"]?.manual, true)
        let operation = try XCTUnwrap(repository.syncRecord("document:\(first.id)")).operationID
        try restart()
        var edit = second; edit.title = "Edited during backfill"; try repository.update(edit)
        let editOperation = try XCTUnwrap(repository.syncRecord("document:\(second.id)")).operationID
        XCTAssertTrue(try repository.backfillSyncBatch(limit: 2))
        XCTAssertNotNil(try repository.syncRecord("document:\(third.id)"))
        XCTAssertEqual(try repository.syncRecord("document:\(first.id)")?.operationID, operation)
        XCTAssertEqual(try repository.syncRecord("document:\(second.id)")?.operationID, editOperation)
        XCTAssertEqual(try snapshot(second.id).fields["title"]?.value, .text("Edited during backfill"))
        XCTAssertTrue(try repository.backfillSyncBatch(limit: 1))
    }
    func testBackfillFailureDoesNotAdvanceCheckpoint() throws {
        let first = try seed(hash: "a", legacy: true)
        var bad = try seed(hash: "b", legacy: true); bad.collections = ["Broken"]
        let id = bad.id
        let row = try XCTUnwrap(repository.context.fetch(FetchDescriptor<ArchiveSchemaV1.DocumentRecord>(predicate: #Predicate { $0.id == id })).first)
        row.updateMetadata(from: bad)
        try repository.journalCollection(.init(name: "Broken", symbol: "folder"))
        let key = "collection:\(try repository.collectionIdentity("Broken"))"
        let journal = try XCTUnwrap(repository.syncRecord(key)); journal.payload = Data("bad".utf8); try repository.save()
        _ = try repository.backfillSyncBatch() // default collections, then document phase
        XCTAssertThrowsError(try repository.backfillSyncBatch())
        XCTAssertNil(try repository.syncRecord("document:\(first.id)"))
        repository.context.delete(try XCTUnwrap(repository.syncRecord(key))); try repository.save()
        XCTAssertTrue(try repository.backfillSyncBatch())
        XCTAssertNotNil(try repository.syncRecord("document:\(first.id)"))
        XCTAssertNotNil(try repository.syncRecord("document:\(bad.id)"))
    }
    func testIncomingMergesIndependentEditsAndUpdatesSearchAndBaseline() async throws {
        var doc = try seed()
        let base = try snapshot(doc.id); try apply([base], to: "1")
        doc.title = "Local chosen title"; try repository.update(doc)
        let incoming = remote(base, field: "summary", value: .text("Remote summary"))
        try apply([incoming], to: "2")
        XCTAssertEqual(try repository.document(doc.id)?.title, "Local chosen title")
        XCTAssertEqual(try repository.document(doc.id)?.summary, "Remote summary")
        let baseline = try XCTUnwrap(repository.serverBaseline(base.recordKey))
        XCTAssertEqual(try JSONDecoder().decode(SyncMetadata.self, from: baseline.payload), incoming)
        XCTAssertEqual(try repository.pendingSyncOperations().count, 1)
        let container = repository.container
        let search = await Task.detached { TextSearchService(modelContainer: container) }.value
        try await search.configure(root: root, archiveID: repository.archiveID)
        let hits = try await search.search("remote summary", destination: .recent, newestFirst: true)
        XCTAssertEqual(hits.total, 1)
        try restart()
        XCTAssertEqual(try repository.incomingSyncToken(), "2")
        XCTAssertEqual(try repository.document(doc.id)?.summary, "Remote summary")
    }
    func testConflictSurvivesRestartBlocksOutgoingAndResolves() throws {
        var doc = try seed(); let base = try snapshot(doc.id); try apply([base], to: "1")
        doc.title = "Local choice"; try repository.update(doc)
        let incoming = remote(base, field: "title", value: .text("Remote choice"))
        try apply([incoming], to: "2")
        try restart()
        let conflict = try XCTUnwrap(repository.syncConflicts().first)
        XCTAssertEqual(conflict.conflict.local.value, .text("Local choice"))
        XCTAssertEqual(try repository.document(doc.id)?.title, "Remote choice")
        XCTAssertTrue(try repository.pendingSyncOperations().isEmpty)
        try repository.resolveSyncConflict(conflict.id, choosing: .local)
        XCTAssertEqual(try repository.document(doc.id)?.title, "Local choice")
        XCTAssertEqual(try repository.pendingSyncOperations().count, 1)
        XCTAssertTrue(try repository.syncConflicts().isEmpty)
        try restart()
        XCTAssertEqual(try repository.syncConflicts(includeHistory: true).first?.status, "resolved")
        XCTAssertThrowsError(try repository.resolveSyncConflict(conflict.id, choosing: .server))
    }
    func testNewManualEditSupersedesConflictWithoutDiscardingHistory() throws {
        var doc = try seed(); let base = try snapshot(doc.id); try apply([base], to: "1")
        doc.title = "Local"; try repository.update(doc)
        try apply([remote(base, field: "title", value: .text("Remote"))], to: "2")
        let conflict = try XCTUnwrap(repository.syncConflicts().first)
        doc = try XCTUnwrap(repository.document(doc.id)); doc.title = "Third decision"; try repository.update(doc)
        XCTAssertThrowsError(try repository.resolveSyncConflict(conflict.id, choosing: .local))
        XCTAssertEqual(try repository.document(doc.id)?.title, "Third decision")
        XCTAssertEqual(try repository.syncConflicts(includeHistory: true).first?.status, "superseded")
        XCTAssertEqual(try repository.pendingSyncOperations().count, 1)
    }
    func testInvalidPageRollsBackEarlierRecordsBaselineAndCursor() throws {
        let a = try seed(), b = try seed()
        let first = try snapshot(a.id), second = try snapshot(b.id)
        let receipts = try repository.context.fetchCount(FetchDescriptor<ArchiveSchemaV3.SearchChangeRecord>())
        let valid = remote(first, field: "title", value: .text("Remote title"))
        let invalid = remote(second, field: "contentHash", value: .text("Wrong identity"))
        XCTAssertThrowsError(try apply([valid, invalid], to: "1"))
        XCTAssertEqual(try repository.document(a.id)?.title, "Original")
        XCTAssertNil(try repository.serverBaseline(first.recordKey))
        XCTAssertEqual(try repository.incomingSyncToken(), "")
        XCTAssertEqual(try repository.context.fetchCount(FetchDescriptor<ArchiveSchemaV3.SearchChangeRecord>()), receipts)
        try restart()
        XCTAssertEqual(try repository.incomingSyncToken(), "")
        XCTAssertEqual(try snapshot(a.id), first)
    }
    func testReplayedAndOutOfOrderPagesCannotRegressState() throws {
        let doc = try seed(), key = "document:unused"
        let base = try snapshot(doc.id)
        let page = IncomingMetadataPage(previousToken: "", nextToken: "1", records: [base])
        try repository.applyIncomingPage(page)
        XCTAssertThrowsError(try repository.applyIncomingPage(page))
        XCTAssertThrowsError(try repository.applyIncomingPage(.init(previousToken: "older", nextToken: "2", records: [])))
        XCTAssertEqual(try repository.incomingSyncToken(), "1")
        XCTAssertNil(try repository.serverBaseline(key))
    }
    func testUnsupportedVersionArchiveAndCollectionRejectPage() throws {
        let doc = try seed(); let base = try snapshot(doc.id)
        var version = base; version.formatVersion = 9
        XCTAssertThrowsError(try apply([version], to: "1"))
        let other = SyncMetadata(archiveID: UUID(), recordKey: base.recordKey, fields: base.fields)
        XCTAssertThrowsError(try apply([other], to: "1"))
        let unknown = remote(base, field: "membership:\(UUID())", value: .flag(true))
        XCTAssertThrowsError(try apply([unknown], to: "1"))
        XCTAssertEqual(try repository.incomingSyncToken(), "")
    }
    func testRepeatedRemoteRecordKeepsOpenConflictAndLocalAlternative() throws {
        var doc = try seed(); let base = try snapshot(doc.id); try apply([base], to: "1")
        doc.summary = "Local"; try repository.update(doc)
        let incoming = remote(base, field: "summary", value: .text("Remote"))
        try apply([incoming], to: "2")
        let conflict = try XCTUnwrap(repository.syncConflicts().first)
        try apply([incoming], to: "3")
        XCTAssertEqual(try repository.syncConflicts().count, 1)
        XCTAssertEqual(try repository.syncConflicts().first?.id, conflict.id)
        try repository.resolveSyncConflict(conflict.id, choosing: .server)
        XCTAssertEqual(try repository.document(doc.id)?.summary, "Remote")
    }
    func testLaterRemoteEditRetainsUnresolvedLocalAlternative() throws {
        var doc = try seed(); let base = try snapshot(doc.id); try apply([base], to: "1")
        doc.title = "Local alternative"; try repository.update(doc)
        let first = remote(base, field: "title", value: .text("First remote"))
        try apply([first], to: "2")
        let old = try XCTUnwrap(repository.syncConflicts().first)
        try apply([remote(first, field: "title", value: .text("Second remote"))], to: "3")
        let current = try XCTUnwrap(repository.syncConflicts().first)
        XCTAssertNotEqual(current.id, old.id)
        XCTAssertEqual(current.conflict.local.value, .text("Local alternative"))
        XCTAssertEqual(current.conflict.server.value, .text("Second remote"))
        XCTAssertTrue(try repository.pendingSyncOperations().isEmpty)
        XCTAssertThrowsError(try repository.resolveSyncConflict(old.id, choosing: .local))
        try repository.resolveSyncConflict(current.id, choosing: .local)
        XCTAssertEqual(try repository.document(doc.id)?.title, "Local alternative")
    }
    func testV5MigrationKeepsPendingOperationIdentity() throws {
        let doc = try seed(), metadata = try snapshot(doc.id)
        let legacy = root.appendingPathComponent("V5")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let operationID = UUID()
        try seedV5(doc, metadata: metadata, operationID: operationID, at: legacy)
        let migrated = try ArchiveRepository(root: legacy)
        XCTAssertEqual(try migrated.pendingSyncOperations().first?.id, operationID)
        XCTAssertEqual(try migrated.pendingSyncOperations().first?.metadata, metadata)
        XCTAssertEqual(try migrated.document(doc.id), doc)
        XCTAssertEqual(try migrated.incomingSyncToken(), "")
        XCTAssertTrue(try migrated.syncConflicts().isEmpty)
    }
    private func seedV5(_ document: HouseholdDocument, metadata: SyncMetadata, operationID: UUID, at root: URL) throws {
        let schema = Schema(versionedSchema: ArchiveSchemaV5.self)
        let config = ModelConfiguration("StowKit", schema: schema, url: root.appendingPathComponent("Library.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let archive = ArchiveSchemaV1.ArchiveRecord(); archive.id = document.archiveID
        context.insert(archive); context.insert(ArchiveSchemaV1.DocumentRecord(document))
        context.insert(ArchiveSchemaV5.SyncRecord(key: metadata.recordKey, operationID: operationID, payload: try JSONEncoder().encode(metadata)))
        try context.save()
    }
    func testReceiverRetriesFromPersistedCursor() async throws {
        let doc = try seed(); let base = try snapshot(doc.id)
        let fake = FakeIncomingTransport(page: .init(previousToken: "", nextToken: "first", records: [remote(base, field: "title", value: .text("Received"))]))
        let receiver = LocalSyncReceiver(repository: repository, transport: fake)
        do { try await receiver.receivePage(); XCTFail("Expected first fetch failure") } catch {}
        XCTAssertEqual(try repository.incomingSyncToken(), "")
        try restart()
        try await LocalSyncReceiver(repository: repository, transport: fake).receivePage()
        XCTAssertEqual(try repository.incomingSyncToken(), "first")
        XCTAssertEqual(try repository.document(doc.id)?.title, "Received")
        let tokens = await fake.tokens
        XCTAssertEqual(tokens, ["", ""])
    }
}

private actor FakeIncomingTransport: IncomingMetadataTransport {
    enum Failure: Error { case offline }
    let page: IncomingMetadataPage
    var tokens: [String] = []
    init(page: IncomingMetadataPage) { self.page = page }
    func fetch(after token: String) async throws -> IncomingMetadataPage? {
        tokens.append(token)
        if tokens.count == 1 { throw Failure.offline }
        return page
    }
}
