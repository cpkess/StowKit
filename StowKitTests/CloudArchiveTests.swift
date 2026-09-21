import XCTest
import SwiftData
import CryptoKit
import CloudKit
import SQLite3
@testable import StowKit

@MainActor final class CloudArchiveTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitCloudTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    private func archive(_ name: String, joining id: UUID? = nil) throws -> ArchiveRepository {
        try ArchiveRepository(root: root.appendingPathComponent(name), joiningArchiveID: id)
    }
    private func seed(_ repository: ArchiveRepository, name: String, file: String = "scan.pdf", text: String? = nil, unique: String = "") throws -> HouseholdDocument {
        let bytes = Data(("Fictional original bytes for sync integration" + unique).utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let id = UUID(), date = Date()
        let document = HouseholdDocument(id: id, archiveID: repository.archiveID, title: file, originalFilename: file,
            documentDate: date, importedAt: date, modifiedAt: date, contentType: "com.adobe.pdf", contentHash: hash,
            fileSize: Int64(bytes.count), relativePath: "Originals/\(id.uuidString.prefix(2))/\(id).pdf")
        let storage = DocumentStorageManager(root: root.appendingPathComponent(name))
        let url = try storage.originalURL(for: document.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        try repository.insert(document)
        if let text {
            _ = try repository.setPageCount(id, count: 1)
            _ = try repository.savePage(id, index: 0, result: .init(text: text, method: .embedded))
            _ = try repository.setProcessingState(id, .complete)
        }
        return document
    }
    private func coordinator(_ repository: ArchiveRepository, name: String, server: FakeArchiveCloud) async throws -> (CloudSyncCoordinator, DocumentStorageManager, TextSearchService) {
        let storage = DocumentStorageManager(root: root.appendingPathComponent(name))
        await storage.setCloudTransport(server)
        let container = repository.container
        let reader = await Task.detached { TextSearchService(modelContainer: container) }.value
        try await reader.configure(root: storage.root, archiveID: repository.archiveID)
        return (CloudSyncCoordinator(repository: repository, storage: storage, reader: reader, transport: server,
            onStatus: { status, error in if error { XCTFail(status) } }, onUpdate: {}), storage, reader)
    }
    private func sync(_ coordinator: CloudSyncCoordinator) async { coordinator.schedule(); await coordinator.waitUntilIdle() }

    func testSecondDeviceReceivesSearchableMetadataWithoutOriginalDownload() async throws {
        let a = try archive("A"), doc = try seed(a, name: "A", text: "Insurance umbrella coverage fictional zebra")
        let b = try archive("B", joining: a.archiveID), server = FakeArchiveCloud()
        let (ca, _, _) = try await coordinator(a, name: "A", server: server)
        await sync(ca)
        let before = await server.originalDownloads
        let (cb, storage, reader) = try await coordinator(b, name: "B", server: server)
        await sync(cb)
        let received = try XCTUnwrap(b.matching(hash: doc.contentHash))
        XCTAssertEqual(received.contentHash, doc.contentHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try storage.originalURL(for: received.relativePath).path))
        _ = try? await ThumbnailService(storage: storage).thumbnail(for: received)
        let afterMetadata = await server.originalDownloads
        XCTAssertEqual(afterMetadata, before)
        let hits = try await reader.search("fictional zebra", destination: .recent, newestFirst: true)
        XCTAssertEqual(hits.total, 1)
        let local = try await storage.localOriginal(for: received)
        XCTAssertEqual(try Data(contentsOf: local), Data("Fictional original bytes for sync integration".utf8))
        XCTAssertEqual(try b.collections().count, 12)
    }
    func testSecondMacProcessesADocumentThatArrivedUnprocessed() async throws {
        let a = try archive("A"), doc = try seed(a, name: "A", text: "Fictional patient authorization form")
        let b = try archive("B", joining: a.archiveID), server = FakeArchiveCloud()
        let (ca, _, _) = try await coordinator(a, name: "A", server: server); await sync(ca)
        let (cb, _, _) = try await coordinator(b, name: "B", server: server); await sync(cb)
        let received = try XCTUnwrap(b.matching(hash: doc.contentHash))
        XCTAssertEqual(try b.analysis(received.id)?.state, "remote")
        XCTAssertEqual(try b.queueUnprocessedRemoteAnalyses(), 0, "The Mac that added it gets a grace period")
        XCTAssertEqual(try b.queueUnprocessedRemoteAnalyses(now: Date().addingTimeInterval(601)), 1)
        XCTAssertEqual(try b.analysis(received.id)?.state, "queued")
    }
    func testSecondMacLeavesAnUnderstoodDocumentAlone() async throws {
        let a = try archive("A"), doc = try seed(a, name: "A", text: "Fictional patient authorization form")
        var understood = try XCTUnwrap(a.document(doc.id)); understood.summary = "A fictional authorization form."
        try a.update(understood)
        let b = try archive("B", joining: a.archiveID), server = FakeArchiveCloud()
        let (ca, _, _) = try await coordinator(a, name: "A", server: server); await sync(ca)
        let (cb, _, _) = try await coordinator(b, name: "B", server: server); await sync(cb)
        let received = try XCTUnwrap(b.matching(hash: doc.contentHash))
        XCTAssertEqual(received.summary, "A fictional authorization form.")
        XCTAssertEqual(try b.queueUnprocessedRemoteAnalyses(now: Date().addingTimeInterval(601)), 0)
        XCTAssertEqual(try b.analysis(received.id)?.state, "remote")
    }
    func testRemoteMetadataEditDoesNotFetchOriginal() async throws {
        let a = try archive("A"), doc = try seed(a, name: "A")
        let b = try archive("B", joining: a.archiveID), server = FakeArchiveCloud()
        let (ca, _, _) = try await coordinator(a, name: "A", server: server); await sync(ca)
        let (cb, _, _) = try await coordinator(b, name: "B", server: server); await sync(cb)
        let before = await server.originalDownloads
        var received = try XCTUnwrap(b.matching(hash: doc.contentHash)); received.summary = "Edited on second Mac"
        try b.update(received); await sync(cb); await sync(ca)
        XCTAssertEqual(try a.document(doc.id)?.summary, "Edited on second Mac")
        let after = await server.originalDownloads
        XCTAssertEqual(after, before)
    }
    func testConcurrentDuplicateImportsShareOneCloudDocumentAndPreserveLocalIDs() async throws {
        let a = try archive("A"), b = try archive("B", joining: a.archiveID), server = FakeArchiveCloud()
        let da = try seed(a, name: "A", file: "receipt.pdf"), db = try seed(b, name: "B", file: "renamed.pdf")
        let (ca, _, _) = try await coordinator(a, name: "A", server: server)
        let (cb, _, _) = try await coordinator(b, name: "B", server: server)
        await sync(ca); await sync(cb); await sync(ca)
        XCTAssertEqual(try a.documents().count, 1); XCTAssertEqual(try b.documents().count, 1)
        XCTAssertEqual(try b.matching(hash: da.contentHash)?.id, db.id)
        XCTAssertEqual(try a.matching(hash: db.contentHash)?.id, da.id)
        let count = await server.documentCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try b.document(db.id)?.originalFilename, "renamed.pdf")
    }
    func testConditionalSaveConflictPreservesBothManualValues() async throws {
        let a = try archive("A"), doc = try seed(a, name: "A"), server = FakeArchiveCloud()
        let (ca, _, _) = try await coordinator(a, name: "A", server: server); await sync(ca)
        var edited = try XCTUnwrap(a.document(doc.id)); edited.title = "Local manual"
        try a.update(edited)
        let local = try XCTUnwrap(a.pendingSyncOperations().first(where: { $0.metadata.recordKey.hasPrefix("document:") }))
        let request = try a.cloudRequest(local)
        var remote = request.operation.metadata
        remote.fields["title"] = SyncField(value: .text("Other manual"), manual: true, operationID: UUID())
        _ = try await server.save(.init(operation: .init(id: UUID(), metadata: remote), systemFields: request.systemFields))
        let result = try await server.save(request)
        XCTAssertNotNil(result.conflict)
        try a.acceptCloudSave(result, sent: local)
        let conflict = try XCTUnwrap(a.syncConflicts().first)
        XCTAssertEqual(conflict.conflict.local.value, .text("Local manual"))
        XCTAssertEqual(conflict.conflict.server.value, .text("Other manual"))
        XCTAssertTrue(try a.pendingSyncOperations().isEmpty)
    }
    func testTextSyncDrainsMultipleBatchesPastBlockedExtraction() async throws {
        let a = try archive("A"), server = FakeArchiveCloud()
        // An incomplete first extraction must not block later completed text uploads.
        let blocked = try seed(a, name: "A", unique: "blocked")
        try a.queueTextUpload(blocked.id)
        for index in 0..<20 { _ = try seed(a, name: "A", text: "Batch text \(index)", unique: String(index)) }
        let (ca, _, _) = try await coordinator(a, name: "A", server: server)
        await sync(ca)
        XCTAssertEqual(try a.pendingTextUploads().map { $0.0 }, [blocked.id])
        let b = try archive("B", joining: a.archiveID)
        let (cb, _, reader) = try await coordinator(b, name: "B", server: server)
        await sync(cb)
        XCTAssertTrue(try b.pendingTextDownloads().isEmpty)
        let hits = try await reader.search("Batch text", destination: .recent, newestFirst: true)
        XCTAssertEqual(hits.total, 20)
    }
    func testReadOnlyParticipantReceivesWithoutWriting() async throws {
        let a = try archive("A"), doc = try seed(a, name: "A", text: "Shared read only text"), server = FakeArchiveCloud()
        let (ca, _, _) = try await coordinator(a, name: "A", server: server); await sync(ca)
        let writesBefore = await server.writes
        await server.setWritable(false)
        let b = try archive("B", joining: a.archiveID)
        let (cb, _, _) = try await coordinator(b, name: "B", server: server); await sync(cb)
        XCTAssertNotNil(try b.matching(hash: doc.contentHash))
        let writesAfter = await server.writes
        XCTAssertEqual(writesBefore, writesAfter)
    }
    func testCorruptOriginalIsNeverInstalled() async throws {
        let a = try archive("A"), doc = try seed(a, name: "A"), server = FakeArchiveCloud()
        let (ca, _, _) = try await coordinator(a, name: "A", server: server); await sync(ca)
        let b = try archive("B", joining: a.archiveID)
        let (cb, storage, _) = try await coordinator(b, name: "B", server: server); await sync(cb)
        let remote = try XCTUnwrap(b.matching(hash: doc.contentHash))
        await server.corruptOriginal(doc.contentHash)
        do { _ = try await storage.localOriginal(for: remote); XCTFail("Corrupt download was accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: try storage.originalURL(for: remote.relativePath).path))
    }
    func testExpiredTokenRefetchPreservesPendingManualEdit() async throws {
        let a = try archive("A"), doc = try seed(a, name: "A"), server = FakeArchiveCloud()
        let (ca, _, _) = try await coordinator(a, name: "A", server: server); await sync(ca)
        var edited = doc; edited.title = "Manual edit survives expired cursor"
        try a.update(edited)
        await server.expireNextToken()
        await sync(ca)
        XCTAssertEqual(try a.document(doc.id)?.title, edited.title)
        XCTAssertTrue(try a.pendingSyncOperations().isEmpty)
    }
    func testUnrelatedCloudAcknowledgmentCannotClearPendingEdit() throws {
        let a = try archive("A"); _ = try seed(a, name: "A")
        let operation = try XCTUnwrap(a.pendingSyncOperations().first)
        let wire = try a.cloudRequest(operation).operation.metadata
        let unrelated = CloudSaveResult(operationID: UUID(), saved: .init(metadata: wire, systemFields: Data()), conflict: nil)
        XCTAssertThrowsError(try a.acceptCloudSave(unrelated, sent: operation))
        XCTAssertTrue(try a.pendingSyncOperations().contains(where: { $0.id == operation.id }))
    }
    func testV7TextQueueMigratesPayloadWithoutUsingReservedHashProperty() throws {
        let legacy = root.appendingPathComponent("Legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let heads = [CloudTextHead(originalHash: String(repeating: "a", count: 64), blobHash: String(repeating: "b", count: 64), size: 10),
                     CloudTextHead(originalHash: String(repeating: "c", count: 64), blobHash: String(repeating: "d", count: 64), size: 12)]
        try seedV7Queue(heads, at: legacy)
        let migrated = try ArchiveRepository(root: legacy)
        XCTAssertEqual(Set(try migrated.pendingTextDownloads().map(\.originalHash)), Set(heads.map(\.originalHash)))
    }
    private func seedV7Queue(_ heads: [CloudTextHead], at root: URL) throws {
        try autoreleasepool { try seedEmptyV7(at: root) }
        // Model a preexisting disk queue without invoking the macOS 27 `hash` accessor bug.
        // This raw fixture writer is restricted to this test's disposable SQLite store.
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("Library.store").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5000)
        for (index, head) in heads.enumerated() {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO ZTEXTDOWNLOAD (Z_PK,Z_ENT,Z_OPT,ZHASH,ZPAYLOAD) VALUES (?,(SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME='TextDownload'),1,?,?)", -1, &statement, nil), SQLITE_OK)
            sqlite3_bind_int(statement, 1, Int32(index + 1))
            _ = head.originalHash.withCString { sqlite3_bind_text(statement, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            let payload = try JSONEncoder().encode(head)
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        XCTAssertEqual(sqlite3_exec(database, "UPDATE Z_PRIMARYKEY SET Z_MAX=100 WHERE Z_NAME='TextDownload'", nil, nil, nil), SQLITE_OK)
    }
    private func seedEmptyV7(at root: URL) throws {
        let schema = Schema(versionedSchema: ArchiveSchemaV7.self)
        let configuration = ModelConfiguration("StowKit", schema: schema, url: root.appendingPathComponent("Library.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container); context.insert(ArchiveSchemaV1.ArchiveRecord()); try context.save()
    }
    func testPartialCloudKitErrorIsUnwrappedPerRecord() throws {
        let id = CKRecord.ID(recordName: "test")
        let conflict = CKError(.serverRecordChanged)
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: conflict]])
        XCTAssertEqual((CloudRecordOperations.recordError(partial, id: id) as? CKError)?.code, .serverRecordChanged)
    }
    func testBindingRejectsDifferentAccountAndArchive() throws {
        let repository = try archive("A")
        let binding = CloudArchiveBinding(containerID: "iCloud.test", environment: "Development", accountID: "first",
            archiveID: repository.archiveID, zoneName: "test", ownerName: "owner", shared: false)
        try repository.bindCloud(binding)
        let other = CloudArchiveBinding(containerID: "iCloud.test", environment: "Development", accountID: "second",
            archiveID: repository.archiveID, zoneName: "test", ownerName: "owner", shared: false)
        XCTAssertThrowsError(try repository.bindCloud(other))
        XCTAssertEqual(try repository.cloudBinding()?.0, binding)
    }
    /// Build an archive whose single document satisfies every eviction invariant, so each test
    /// below can break exactly one and assert the specific refusal.
    private func evictable(_ name: String = "A", shared: Bool = false)
        async throws -> (ArchiveRepository, DocumentStorageManager, HouseholdDocument, FakeArchiveCloud) {
        let repository = try archive(name)
        let document = try seed(repository, name: name, text: "Fictional evictable water bill")
        let server = FakeArchiveCloud()
        let storage = DocumentStorageManager(root: root.appendingPathComponent(name))
        await storage.setCloudTransport(server)
        try repository.bindCloud(CloudArchiveBinding(containerID: "iCloud.test", environment: "Development",
            accountID: "account", archiveID: repository.archiveID, zoneName: "zone",
            ownerName: "owner", shared: shared))
        try repository.markOriginalVerified(document.id)
        let original = try storage.originalURL(for: document.relativePath)
        try await server.uploadOriginal(document, url: original)
        let thumbnail = storage.thumbnailURL(for: document.id)
        try FileManager.default.createDirectory(at: thumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fictional thumbnail".utf8).write(to: thumbnail)
        return (repository, storage, document, server)
    }
    private func assertRefusal(_ expected: EvictionRefusal?, _ body: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTAssertNil(expected, "expected refusal \(String(describing: expected))", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? EvictionRefusal, expected, file: file, line: line)
        }
    }

    func testEvictionRemovesTheLocalCopyAndTheOriginalComesBackByteIdentical() async throws {
        let (repository, storage, document, server) = try await evictable()
        let original = try storage.originalURL(for: document.relativePath)
        let before = try Data(contentsOf: original)

        let startingLocation = await storage.originalLocation(for: document)
        XCTAssertEqual(startingLocation, .availableOffline)
        let reclaimed = try await storage.evictOriginal(document, facts: repository.evictionFacts(document.id))
        XCTAssertGreaterThan(reclaimed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let evictedLocation = await storage.originalLocation(for: document)
        XCTAssertEqual(evictedLocation, .optimized)

        // Everything that makes the document usable without its original survives.
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.thumbnailURL(for: document.id).path))
        XCTAssertGreaterThan(try XCTUnwrap(repository.processingJob(document.id)?.snapshot.characterCount), 0)
        XCTAssertEqual(try repository.document(document.id)?.relativePath, document.relativePath)
        XCTAssertEqual(try repository.processingJob(document.id)?.snapshot.state, .complete)

        let restored = try await storage.localOriginal(for: document)
        XCTAssertEqual(try Data(contentsOf: restored), before)
        let downloads = await server.originalDownloads
        XCTAssertEqual(downloads, 1)
        let restoredLocation = await storage.originalLocation(for: document)
        XCTAssertEqual(restoredLocation, .availableOffline)
    }

    func testEvictionRefusesPinnedUnverifiedAndUnfinishedDocuments() async throws {
        let (repository, storage, document, _) = try await evictable()

        try repository.setOriginalPinned(document.id, true)
        var facts = try repository.evictionFacts(document.id)
        XCTAssertTrue(facts.pinned)
        await assertRefusal(.pinned) { try await storage.evictOriginal(document, facts: facts) }
        try repository.setOriginalPinned(document.id, false)

        // Neither uploaded-and-verified nor downloaded: this Mac may hold the only copy.
        facts = try repository.evictionFacts(document.id)
        facts.cloudVerified = false; facts.remote = false
        XCTAssertFalse(facts.hasVerifiedCloudCopy)
        await assertRefusal(.noVerifiedCloudCopy) { try await storage.evictOriginal(document, facts: facts) }

        // A download counts on its own: promoting one already validated the bytes.
        facts.remote = true
        XCTAssertTrue(facts.hasVerifiedCloudCopy)
        await assertRefusal(nil) { try await storage.evictOriginal(document, facts: facts) }

        // A fresh archive: the case above evicted this one's original, and a later refusal must
        // come from the invariant under test rather than from the missing file.
        let (pendingRepo, pendingStorage, pendingDoc, _) = try await evictable("Unfinished")
        var pending = try pendingRepo.evictionFacts(pendingDoc.id)
        XCTAssertFalse(pending.processingOutstanding, "the fixture completes extraction")
        pending.processingOutstanding = true
        await assertRefusal(.processingOutstanding) { try await pendingStorage.evictOriginal(pendingDoc, facts: pending) }
    }

    func testEvictionRefusesWithoutSyncAThumbnailOrALocalFile() async throws {
        let (repository, storage, document, _) = try await evictable()
        let facts = try repository.evictionFacts(document.id)

        await storage.setCloudTransport(nil)
        await assertRefusal(.syncUnavailable) { try await storage.evictOriginal(document, facts: facts) }

        let (sharedRepo, sharedStorage, sharedDoc, _) = try await evictable("Shared", shared: true)
        let sharedFacts = try sharedRepo.evictionFacts(sharedDoc.id)
        XCTAssertTrue(sharedFacts.sharedArchive)
        await assertRefusal(.sharedArchive) { try await sharedStorage.evictOriginal(sharedDoc, facts: sharedFacts) }

        let (thumbRepo, thumbStorage, thumbDoc, _) = try await evictable("NoThumb")
        try FileManager.default.removeItem(at: thumbStorage.thumbnailURL(for: thumbDoc.id))
        let thumbFacts = try thumbRepo.evictionFacts(thumbDoc.id)
        await assertRefusal(.noThumbnail) { try await thumbStorage.evictOriginal(thumbDoc, facts: thumbFacts) }

        // Evicting twice is refused rather than silently succeeding.
        let (againRepo, againStorage, againDoc, _) = try await evictable("Again")
        let againFacts = try againRepo.evictionFacts(againDoc.id)
        try await againStorage.evictOriginal(againDoc, facts: againFacts)
        await assertRefusal(.notDownloaded) { try await againStorage.evictOriginal(againDoc, facts: againFacts) }
    }

    func testEvictionFrontsReclaimedBytesInMeasuredUsage() async throws {
        let (repository, storage, document, _) = try await evictable()
        let before = try await storage.usage()
        let reclaimed = try await storage.evictOriginal(document, facts: repository.evictionFacts(document.id))
        let after = try await storage.usage()
        XCTAssertEqual(after.originalFiles, before.originalFiles - 1)
        XCTAssertEqual(after.originals, before.originals - reclaimed)
        XCTAssertGreaterThan(after.derived, 0, "text, thumbnail, and database remain")
    }

    // MARK: Permanent deletion

    private func trash(_ repository: ArchiveRepository, _ id: UUID) throws {
        var document = try XCTUnwrap(repository.document(id)); document.trashedAt = Date()
        try repository.update(document)
    }
    private func cloudKey(_ repository: ArchiveRepository, _ document: HouseholdDocument) -> String {
        "document:\(CloudDocumentIdentity.id(archive: repository.archiveID, hash: document.contentHash))"
    }

    func testPermanentDeleteOnlyAcceptsDocumentsInTrash() throws {
        let a = try archive("A"), doc = try seed(a, name: "A")
        XCTAssertThrowsError(try a.permanentlyDelete([doc.id])) { XCTAssertEqual($0 as? ArchiveRepository.DeletionError, .notInTrash) }
        XCTAssertNotNil(try a.document(doc.id), "a refused deletion changes nothing")
        XCTAssertTrue(try a.pendingFilePurges().isEmpty)
    }

    func testPermanentDeleteRemovesDocumentHereInICloudAndOnOtherMacs() async throws {
        let a = try archive("A"), doc = try seed(a, name: "A", text: "Fictional deletable water bill")
        let b = try archive("B", joining: a.archiveID), server = FakeArchiveCloud()
        let (ca, storageA, readerA) = try await coordinator(a, name: "A", server: server); await sync(ca)
        let (cb, storageB, _) = try await coordinator(b, name: "B", server: server); await sync(cb)
        let received = try XCTUnwrap(b.matching(hash: doc.contentHash))
        _ = try await storageB.localOriginal(for: received)   // B has downloaded it too
        let originalA = try storageA.originalURL(for: doc.relativePath)
        let originalB = try storageB.originalURL(for: received.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalB.path))

        try trash(a, doc.id)
        try a.permanentlyDelete([doc.id])
        XCTAssertNil(try a.document(doc.id))
        XCTAssertEqual(try a.pendingFilePurges().map(\.id), [doc.id], "file removal is queued durably")
        await sync(ca)

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalA.path))
        XCTAssertTrue(try a.pendingFilePurges().isEmpty)
        let hits = try await readerA.search("deletable", destination: .trash, newestFirst: true)
        XCTAssertEqual(hits.total, 0, "gone from search")
        let serverRecord = await server.metadata(cloudKey(a, doc))
        let tombstone = try XCTUnwrap(serverRecord)
        XCTAssertTrue(tombstone.isTombstone)
        XCTAssertEqual(Set(tombstone.fields.keys), ["id", "contentHash", "deleted"], "no title, text, or name left in iCloud")
        let originalInCloud = await server.hasOriginal(doc.contentHash)
        XCTAssertFalse(originalInCloud, "the file's content is deleted from iCloud")
        XCTAssertTrue(try a.pendingCloudPurges().isEmpty)

        await sync(cb)
        XCTAssertNil(try b.matching(hash: doc.contentHash), "the other Mac removes its copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalB.path))
    }

    func testStaleEditOnAnotherMacCannotResurrectADeletedDocument() async throws {
        let a = try archive("A"), doc = try seed(a, name: "A")
        let b = try archive("B", joining: a.archiveID), server = FakeArchiveCloud()
        let (ca, _, _) = try await coordinator(a, name: "A", server: server); await sync(ca)
        let (cb, _, _) = try await coordinator(b, name: "B", server: server); await sync(cb)
        var stale = try XCTUnwrap(b.matching(hash: doc.contentHash)); stale.summary = "Edited offline before the deletion"
        try b.update(stale)   // pending on B, not yet sent

        try trash(a, doc.id); try a.permanentlyDelete([doc.id]); await sync(ca)
        await sync(cb)
        XCTAssertNil(try b.matching(hash: doc.contentHash))
        let afterStaleEdit = await server.metadata(cloudKey(a, doc))
        XCTAssertTrue(try XCTUnwrap(afterStaleEdit).isTombstone, "the edit did not recreate it")
        XCTAssertTrue(try b.pendingSyncOperations().filter { $0.metadata.recordKey.hasPrefix("document:") }.isEmpty)
    }

    func testConcurrentEditLosesToAPermanentDeletion() async throws {
        let a = try archive("A"), doc = try seed(a, name: "A")
        let b = try archive("B", joining: a.archiveID), server = FakeArchiveCloud()
        let (ca, _, _) = try await coordinator(a, name: "A", server: server); await sync(ca)
        let (cb, _, _) = try await coordinator(b, name: "B", server: server); await sync(cb)
        try trash(a, doc.id); try a.permanentlyDelete([doc.id])   // A's tombstone is pending...
        var edited = try XCTUnwrap(b.matching(hash: doc.contentHash)); edited.summary = "Saved first"
        try b.update(edited); await sync(cb)                       // ...while B's edit reaches iCloud first

        await sync(ca); await sync(ca)   // conflict, then resend with the newer change tag
        let afterRace = await server.metadata(cloudKey(a, doc))
        XCTAssertTrue(try XCTUnwrap(afterRace).isTombstone, "delete wins")
        XCTAssertNil(try a.matching(hash: doc.contentHash), "the conflict did not recreate it on the deleting Mac")
        await sync(cb)
        XCTAssertNil(try b.matching(hash: doc.contentHash))
    }

    func testPermanentDeleteWorksWithoutICloud() async throws {
        let a = try archive("A"), doc = try seed(a, name: "A")
        let storage = DocumentStorageManager(root: root.appendingPathComponent("A"))
        let original = try storage.originalURL(for: doc.relativePath)
        try trash(a, doc.id); try a.permanentlyDelete([doc.id])
        for item in try a.pendingFilePurges() {
            try await storage.purgeFiles(relativePath: item.relativePath, documentID: item.id)
            try a.completeFilePurge(item.id)
        }
        XCTAssertNil(try a.document(doc.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(try a.pendingFilePurges().isEmpty)
    }

    func testBadRemoteIdentityRollsBackNewDocumentAndToken() throws {
        let a = try archive("A"), doc = try seed(a, name: "A"), b = try archive("B", joining: a.archiveID)
        let operation = try XCTUnwrap(a.pendingSyncOperations().first)
        var wire = try a.cloudRequest(operation).operation.metadata
        wire.fields["id"]?.value = .text(UUID().uuidString)
        XCTAssertThrowsError(try b.applyCloudPage(.init(records: [.init(metadata: wire, systemFields: Data())], token: "1", moreComing: false), after: ""))
        XCTAssertNil(try b.matching(hash: doc.contentHash)); XCTAssertEqual(try b.incomingSyncToken(), "")
    }
}

private actor FakeArchiveCloud: ArchiveCloudTransport {
    private var rows: [String: CloudRecordSnapshot] = [:]
    private var originals: [String: Data] = [:]
    private var text: [String: [CloudTextPage]] = [:]
    private var events: [(CloudRecordSnapshot?, CloudTextHead?)] = []
    var originalDownloads = 0
    var writes = 0
    private var writable = true
    private var expireToken = false
    func setWritable(_ value: Bool) { writable = value }
    func expireNextToken() { expireToken = true }
    func corruptOriginal(_ hash: String) { originals[hash] = Data("corrupt".utf8) }
    var documentCount: Int { rows.keys.filter { $0.hasPrefix("document:") }.count }
    func verifyAccount() async throws {}
    func canWrite() async throws -> Bool { writable }
    func fetchChanges(after token: String) async throws -> CloudChangePage {
        if expireToken { expireToken = false; throw CKError(.changeTokenExpired) }
        let offset = Int(token) ?? 0, end = min(offset + 64, events.count)
        let slice = events[offset..<end]
        var latest: [String: CloudRecordSnapshot] = [:]
        var heads: [String: CloudTextHead] = [:]
        for (record, head) in slice {
            if let record { latest[record.metadata.recordKey] = record }
            if let head { heads[head.originalHash] = head }
        }
        // Empty initial feeds still have a stable nonempty opaque marker.
        return CloudChangePage(records: Array(latest.values), token: String(end), moreComing: end < events.count, textHeads: Array(heads.values))
    }
    func save(_ request: CloudSaveRequest) async throws -> CloudSaveResult {
        guard writable else { throw CKError(.permissionFailure) }; writes += 1
        let operation = request.operation, current = rows[request.operation.metadata.recordKey]
        if current?.systemFields != request.systemFields {
            return CloudSaveResult(operationID: operation.id, saved: nil, conflict: current)
        }
        let snapshot = CloudRecordSnapshot(metadata: operation.metadata, systemFields: Data(UUID().uuidString.utf8))
        rows[operation.metadata.recordKey] = snapshot; events.append((snapshot, nil))
        return CloudSaveResult(operationID: operation.id, saved: snapshot, conflict: nil)
    }
    func uploadOriginal(_ document: HouseholdDocument, url: URL) async throws { originals[document.contentHash] = try Data(contentsOf: url) }
    func downloadOriginal(_ document: HouseholdDocument, to url: URL) async throws {
        guard let data = originals[document.contentHash] else { throw CloudArchiveError.missingResult }
        originalDownloads += 1
        try data.write(to: url, options: .atomic)
    }
    func uploadText(_ document: HouseholdDocument, pages: [CloudTextPage]) async throws {
        let data = try JSONEncoder().encode(pages)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        text[hash] = pages
        let head = CloudTextHead(originalHash: document.contentHash, blobHash: hash, size: Int64(data.count))
        events.append((nil, head))
    }
    func downloadText(_ head: CloudTextHead) async throws -> [CloudTextPage] {
        guard let pages = text[head.blobHash] else { throw CloudArchiveError.missingResult }; return pages
    }
    private(set) var deletedContent: [String] = []
    func deleteContent(hash: String, keepText: Bool) async throws {
        originals[hash] = nil
        deletedContent.append(hash)
    }
    func hasOriginal(_ hash: String) -> Bool { originals[hash] != nil }
    /// The latest server snapshot for a record, to check what iCloud actually holds.
    func metadata(_ key: String) -> SyncMetadata? { rows[key]?.metadata }
}
