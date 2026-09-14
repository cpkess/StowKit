import XCTest
import SwiftData
@testable import StowKit

@MainActor final class SyncTests: XCTestCase {
    private var root: URL!
    private var repository: ArchiveRepository!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitSyncTests-\(UUID())")
        repository = try ArchiveRepository(root: root)
    }
    override func tearDown() async throws {
        repository = nil
        try? FileManager.default.removeItem(at: root)
    }
    private func document() -> HouseholdDocument {
        let id = UUID(), date = Date()
        return HouseholdDocument(id: id, archiveID: repository.archiveID, title: "scan", originalFilename: "scan.pdf",
            documentDate: date, importedAt: date, modifiedAt: date, contentType: "com.adobe.pdf",
            contentHash: id.uuidString, fileSize: 4, relativePath: "Originals/\(id.uuidString.prefix(2))/\(id).pdf")
    }
    private func pendingDocument(_ id: UUID) throws -> SyncOperation {
        try XCTUnwrap(repository.pendingSyncOperations().first { $0.metadata.recordKey == "document:\(id)" })
    }
    func testImportEditAndRestartKeepLatestSnapshotWithoutLocalPaths() throws {
        var doc = document()
        try repository.insert(doc)
        let first = try pendingDocument(doc.id)
        for i in 0..<20 { doc.title = "Edited \(i)"; try repository.update(doc) }
        let latest = try pendingDocument(doc.id)
        XCTAssertNotEqual(first.id, latest.id)
        XCTAssertEqual(latest.metadata.fields["title"]?.value, .text("Edited 19"))
        XCTAssertEqual(latest.metadata.fields["title"]?.manual, true)
        XCTAssertEqual(try repository.pendingSyncOperations().count, 1)
        let json = String(decoding: try JSONEncoder().encode(latest), as: UTF8.self)
        XCTAssertFalse(json.contains("relativePath")); XCTAssertFalse(json.contains("Originals/"))
        repository = nil; repository = try ArchiveRepository(root: root)
        XCTAssertEqual(try pendingDocument(doc.id), latest)
        XCTAssertEqual(try repository.document(doc.id)?.title, "Edited 19")
    }
    func testOldAcknowledgmentCannotClearNewEdit() throws {
        var doc = document(); try repository.insert(doc)
        let first = try pendingDocument(doc.id)
        doc.summary = "New edit"; try repository.update(doc)
        let second = try pendingDocument(doc.id)
        try repository.acknowledgeSyncOperations([first.id])
        XCTAssertEqual(try pendingDocument(doc.id).id, second.id)
        try repository.acknowledgeSyncOperations([second.id])
        XCTAssertTrue(try repository.pendingSyncOperations().isEmpty)
        repository = nil; repository = try ArchiveRepository(root: root)
        XCTAssertTrue(try repository.pendingSyncOperations().isEmpty)
        doc.favorite = true; try repository.update(doc)
        XCTAssertEqual(try pendingDocument(doc.id).metadata.fields["summary"], second.metadata.fields["summary"])
    }
    func testUnchangedUpdateDoesNotCreateAnotherOperation() throws {
        let doc = document(); try repository.insert(doc)
        let first = try pendingDocument(doc.id)
        try repository.update(doc)
        XCTAssertEqual(try pendingDocument(doc.id), first)
    }
    func testCollectionIdentityAndRemovedMembershipSurviveRestart() throws {
        _ = try repository.addCollection("Household")
        var doc = document(); doc.collections = ["Household"]; try repository.insert(doc)
        let id = try repository.collectionIdentity("Household")
        let edge = "membership:\(id)"
        XCTAssertEqual(try pendingDocument(doc.id).metadata.fields[edge]?.value, .flag(true))
        doc.collections = []; try repository.update(doc)
        repository = nil; repository = try ArchiveRepository(root: root)
        XCTAssertEqual(try repository.collectionIdentity("Household"), id)
        XCTAssertEqual(try pendingDocument(doc.id).metadata.fields[edge]?.value, .flag(false))
        XCTAssertEqual(try pendingDocument(doc.id).metadata.fields[edge]?.manual, true)
    }
    func testJournalFailureRollsBackDocumentProtectionsAndSearchReceipt() throws {
        var doc = document(); try repository.insert(doc)
        let row = try XCTUnwrap(repository.syncRecord("document:\(doc.id)"))
        row.payload = Data("broken".utf8); try repository.save()
        let receipts = try repository.context.fetchCount(FetchDescriptor<ArchiveSchemaV3.SearchChangeRecord>())
        doc.title = "Must roll back"
        XCTAssertThrowsError(try repository.update(doc))
        XCTAssertEqual(try repository.document(doc.id)?.title, "scan")
        XCTAssertFalse(try XCTUnwrap(repository.analysis(doc.id)).protectedFields.contains("title"))
        XCTAssertEqual(try repository.context.fetchCount(FetchDescriptor<ArchiveSchemaV3.SearchChangeRecord>()), receipts)
        repository = nil; repository = try ArchiveRepository(root: root)
        XCTAssertEqual(try repository.document(doc.id)?.title, "scan")
    }
    func testAnalysisAndExplicitAcceptanceAreJournaled() throws {
        let doc = document(); try repository.insert(doc)
        let analysis = try XCTUnwrap(repository.analysis(doc.id)); analysis.state = "analyzing"
        let result = DocumentUnderstanding(title: "Policy", collection: "Insurance", confidence: 0.92)
        try repository.finishAnalysis(doc.id, revision: analysis.revision, result: result)
        let automatic = try pendingDocument(doc.id)
        XCTAssertEqual(automatic.metadata.fields["title"]?.value, .text("Policy"))
        XCTAssertEqual(automatic.metadata.fields["title"]?.manual, false)
        try repository.acceptAnalysis(doc.id)
        let accepted = try pendingDocument(doc.id)
        XCTAssertNotEqual(accepted.id, automatic.id)
        XCTAssertEqual(accepted.metadata.fields["title"]?.manual, true)
        XCTAssertEqual(accepted.metadata.fields["review"]?.manual, true)
    }
    func testFakeTransportRetriesLostAcknowledgmentWithoutDuplicateApplication() async throws {
        let doc = document(); try repository.insert(doc)
        let fake = FakeMetadataTransport()
        await fake.loseNextAcknowledgment()
        let driver = LocalSyncDriver(repository: repository, transport: fake)
        do { try await driver.sendBatch(); XCTFail("Expected lost acknowledgment") } catch {}
        XCTAssertEqual(try repository.pendingSyncOperations().count, 1)
        repository = nil; repository = try ArchiveRepository(root: root)
        try await LocalSyncDriver(repository: repository, transport: fake).sendBatch()
        XCTAssertTrue(try repository.pendingSyncOperations().isEmpty)
        let count = await fake.appliedCount
        XCTAssertEqual(count, 1)
    }
    func testBoundedBatchAndPartialAcknowledgment() async throws {
        for _ in 0..<5 { try repository.insert(document()) }
        let fake = FakeMetadataTransport(acceptLimit: 1)
        try await LocalSyncDriver(repository: repository, transport: fake).sendBatch(limit: 2)
        XCTAssertEqual(try repository.pendingSyncOperations().count, 4)
        let sent = await fake.lastBatchSize
        XCTAssertEqual(sent, 2)
    }
    func testManualProtectionAndIndependentFieldMerge() {
        let title = field("Original", manual: true), summary = field("Original summary")
        let manual = field("Chosen title", manual: true), automatic = field("AI title")
        let changedSummary = field("Updated summary")
        let merge = SyncMergePolicy.merge(base: ["title": title, "summary": summary],
            local: ["title": manual, "summary": summary], server: ["title": automatic, "summary": changedSummary])
        XCTAssertEqual(merge.fields["title"], manual)
        XCTAssertEqual(merge.fields["summary"], changedSummary)
        XCTAssertTrue(merge.conflicts.isEmpty)
        let unchangedProtected = SyncMergePolicy.merge(base: ["title": title], local: ["title": title], server: ["title": automatic])
        XCTAssertEqual(unchangedProtected.fields["title"], title)
    }
    func testSameFieldManualConflictPreservesBothIncludingEmptyValue() {
        let base = field("Old", manual: true), local = field("", manual: true), server = field("Other", manual: true)
        let merge = SyncMergePolicy.merge(base: ["title": base], local: ["title": local], server: ["title": server])
        XCTAssertEqual(merge.fields["title"], server)
        XCTAssertEqual(merge.conflicts, [SyncConflict(field: "title", local: local, server: server)])
    }
    func testAutomaticMergeConvergesAndExplicitLaterRestoreWins() {
        let a = field("A"), b = field("B")
        XCTAssertEqual(SyncMergePolicy.merge(base: [:], local: ["title": a], server: ["title": b]).fields,
                       SyncMergePolicy.merge(base: [:], local: ["title": b], server: ["title": a]).fields)
        let active = SyncField(value: .null, manual: true, operationID: UUID())
        let trash = SyncField(value: .date(Date()), manual: true, operationID: UUID())
        let restore = SyncField(value: .null, manual: true, operationID: UUID())
        XCTAssertEqual(SyncMergePolicy.merge(base: ["trashedAt": active], local: ["trashedAt": restore], server: ["trashedAt": trash]).fields["trashedAt"], trash)
        XCTAssertEqual(SyncMergePolicy.merge(base: ["trashedAt": trash], local: ["trashedAt": restore], server: ["trashedAt": trash]).fields["trashedAt"], restore)
        let add = SyncField(value: .flag(true), manual: true, operationID: UUID())
        let remove = SyncField(value: .flag(false), manual: true, operationID: UUID())
        XCTAssertEqual(SyncMergePolicy.merge(base: [:], local: ["membership:x": add], server: ["membership:x": remove]).fields["membership:x"], remove)
    }
    func testV4MigrationPreservesArchiveAndDoesNotEnqueueHistoricalUploads() throws {
        let legacy = root.appendingPathComponent("V4")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        var doc = document(); doc.title = "Protected"; doc.summary = ""; doc.trashedAt = Date()
        try seedV4(doc, at: legacy)
        let migrated = try ArchiveRepository(root: legacy)
        XCTAssertEqual(migrated.archiveID, doc.archiveID)
        XCTAssertEqual(try migrated.document(doc.id), doc)
        XCTAssertEqual(try migrated.analysis(doc.id)?.protectedFields, ["title", "summary"])
        XCTAssertEqual(try migrated.processingJob(doc.id)?.completedPages, 1)
        XCTAssertEqual(try migrated.context.fetchCount(FetchDescriptor<ArchiveSchemaV2.PageTextRecord>()), 1)
        XCTAssertEqual(try migrated.context.fetchCount(FetchDescriptor<ArchiveSchemaV3.SearchChangeRecord>()), 1)
        XCTAssertTrue(try migrated.pendingSyncOperations().isEmpty)
        doc.favorite = true; try migrated.update(doc)
        XCTAssertEqual(try migrated.pendingSyncOperations().count, 1)
    }
    func testOriginalResolutionRejectsMissingAndWrongSizeWithoutRemovingBytes() async throws {
        let doc = document(), storage = DocumentStorageManager(root: root)
        let url = try storage.originalURL(for: doc.relativePath)
        do { _ = try await storage.localOriginal(for: doc); XCTFail("Missing file") } catch {}
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: url)
        do { _ = try await storage.localOriginal(for: doc); XCTFail("Wrong size") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), Data("bad".utf8))
        try Data("good".utf8).write(to: url)
        let resolved = try await storage.localOriginal(for: doc)
        XCTAssertEqual(resolved, url)
    }
    private func field(_ text: String, manual: Bool = false) -> SyncField {
        SyncField(value: .text(text), manual: manual, operationID: UUID())
    }
    private func seedV4(_ doc: HouseholdDocument, at root: URL) throws {
        let schema = Schema(versionedSchema: ArchiveSchemaV4.self)
        let config = ModelConfiguration("StowKit", schema: schema, url: root.appendingPathComponent("Library.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let archive = ArchiveSchemaV1.ArchiveRecord(); archive.id = doc.archiveID
        context.insert(archive); context.insert(ArchiveSchemaV1.DocumentRecord(doc))
        let job = ArchiveSchemaV2.ProcessingJobRecord(documentID: doc.id, paused: true); job.completedPages = 1
        context.insert(job)
        context.insert(ArchiveSchemaV2.PageTextRecord(documentID: doc.id, pageIndex: 0, page: .init(text: "Saved text", method: .embedded)))
        context.insert(ArchiveSchemaV4.AnalysisRecord(doc.id, protected: ["title", "summary"]))
        context.insert(ArchiveSchemaV3.SearchChangeRecord(doc.id))
        try context.save()
    }
}

private actor FakeMetadataTransport: MetadataSyncTransport {
    enum Failure: Error { case lostAcknowledgment }
    private var seen: Set<UUID> = []
    private var loseAck = false
    let acceptLimit: Int
    var lastBatchSize = 0
    var appliedCount: Int { seen.count }
    init(acceptLimit: Int = 256) { self.acceptLimit = acceptLimit }
    func loseNextAcknowledgment() { loseAck = true }
    func send(_ operations: [SyncOperation]) async throws -> Set<UUID> {
        lastBatchSize = operations.count
        let accepted = Set(operations.prefix(acceptLimit).map(\.id))
        seen.formUnion(accepted)
        if loseAck { loseAck = false; throw Failure.lostAcknowledgment }
        return accepted
    }
}
