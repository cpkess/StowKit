import XCTest
import SwiftData
import FoundationModels
@testable import StowKit

@MainActor final class IntelligenceTests: XCTestCase {
    private var root: URL!
    private var repository: ArchiveRepository!
    private var reader: TextSearchService!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitIntelligenceTests-\(UUID())")
        repository = try ArchiveRepository(root: root)
        let container = repository.container
        reader = await Task.detached { TextSearchService(modelContainer: container) }.value
        try await reader.configure(root: root, archiveID: repository.archiveID)
    }
    override func tearDown() async throws {
        reader = nil; repository = nil
        try? FileManager.default.removeItem(at: root)
    }
    private func seed(_ text: String = "Insurance policy. Policy number ABC123. Coverage period 2026.") throws -> HouseholdDocument {
        let id = UUID(), date = Date()
        let document = HouseholdDocument(id: id, archiveID: repository.archiveID, title: "scan", originalFilename: "scan.pdf", documentDate: date, importedAt: date, modifiedAt: date, contentType: "com.adobe.pdf", contentHash: id.uuidString, fileSize: 100, relativePath: "synthetic")
        try repository.insert(document)
        _ = try repository.setPageCount(id, count: 1)
        _ = try repository.savePage(id, index: 0, result: .init(text: text, method: .embedded))
        _ = try repository.setProcessingState(id, .complete)
        return document
    }
    private func run(provider: any DocumentIntelligenceProvider = RuleBasedProvider()) async {
        let worker = DocumentIntelligenceProcessor(repository: repository, reader: reader, provider: provider)
        worker.start(); await worker.waitUntilIdle()
    }
    func testHighConfidenceFilesAndIndexesWithoutChangingIdentity() async throws {
        let document = try seed()
        await run()
        let updated = try XCTUnwrap(repository.document(document.id))
        XCTAssertEqual(updated.title, "Insurance Policy")
        XCTAssertEqual(updated.collections, ["Insurance"])
        XCTAssertFalse(updated.needsReview)
        XCTAssertEqual(updated.contentHash, document.contentHash)
        XCTAssertEqual(updated.relativePath, document.relativePath)
        XCTAssertEqual(updated.documentDate, document.documentDate)
        let hits = try await reader.search("insurance", destination: .collection("Insurance"), newestFirst: true)
        XCTAssertEqual(hits.total, 1)
        XCTAssertEqual(try repository.analysis(document.id)?.snapshot.result?.confidence, 0.92)
    }
    func testMediumConfidenceFilesButLowConfidenceStaysInInbox() async throws {
        let medium = try seed("A limited warranty for this household product.")
        let low = try seed("Unclassified miscellaneous personal notes.")
        await run()
        XCTAssertFalse(try XCTUnwrap(repository.document(medium.id)).needsReview)
        XCTAssertTrue(try XCTUnwrap(repository.document(low.id)).needsReview)
        XCTAssertEqual(try repository.document(low.id)?.title, "scan")
    }
    func testReanalysisReturnsUncertainDocumentToReview() async throws {
        let document = try seed()
        await run()
        XCTAssertFalse(try XCTUnwrap(repository.document(document.id)).needsReview)
        _ = try repository.retryProcessing(document.id, restart: true)
        _ = try repository.setPageCount(document.id, count: 1)
        _ = try repository.savePage(document.id, index: 0, result: .init(text: "Unknown miscellaneous document", method: .ocr))
        _ = try repository.setProcessingState(document.id, .complete)
        await run()
        XCTAssertTrue(try XCTUnwrap(repository.document(document.id)).needsReview)
    }
    func testAcceptingUnchangedSuggestionsProtectsReviewAndMetadata() async throws {
        let document = try seed("A limited warranty for a fictional household product.")
        await run()
        XCTAssertFalse(try XCTUnwrap(repository.analysis(document.id)).snapshot.reviewProtected)
        let before = try XCTUnwrap(repository.document(document.id))
        try repository.acceptAnalysis(document.id)
        XCTAssertTrue(try XCTUnwrap(repository.analysis(document.id)).snapshot.reviewProtected)
        XCTAssertTrue(try XCTUnwrap(repository.analysis(document.id)).protectedFields.contains("title"))
        _ = try repository.retryProcessing(document.id, restart: true)
        _ = try repository.setPageCount(document.id, count: 1)
        _ = try repository.savePage(document.id, index: 0, result: .init(text: "Unclassified text", method: .ocr))
        _ = try repository.setProcessingState(document.id, .complete)
        await run()
        XCTAssertFalse(try XCTUnwrap(repository.document(document.id)).needsReview)
        XCTAssertEqual(try repository.document(document.id)?.title, before.title)
    }
    func testManualEditsSurvivePendingAnalysisIncludingClearedFields() async throws {
        var document = try seed()
        document.title = "My chosen title"; document.summary = "Temporary"
        try repository.update(document)
        document.summary = ""; document.collections = ["Home"]; document.tags = "private"; document.needsReview = false
        try repository.update(document)
        await run()
        let updated = try XCTUnwrap(repository.document(document.id))
        XCTAssertEqual(updated.title, document.title)
        XCTAssertEqual(updated.summary, "")
        XCTAssertEqual(updated.collections, ["Home"])
        XCTAssertEqual(updated.tags, "private")
        XCTAssertFalse(updated.needsReview)
    }
    func testValidationRejectsInventedCollectionEvidenceAndIssuer() async throws {
        let document = try seed()
        let input = try await reader.analysisInput(document, collections: ["Insurance"])
        let invalid = DocumentUnderstanding(title: "Example", collection: "Invented", correspondent: "Made up Company", evidence: "not in source", confidence: .infinity)
        let validated = UnderstandingPolicy.validated(invalid, input: input)
        XCTAssertEqual(validated.confidence, 0)
        XCTAssertTrue(validated.collection.isEmpty)
        XCTAssertTrue(validated.correspondent.isEmpty)
        let merged = UnderstandingPolicy.merge(validated, into: document, protected: [])
        XCTAssertEqual(merged, document)
    }
    func testLongInputIsBoundedAndRequiresReview() async throws {
        let document = try seed("Insurance policy. Policy number ABC123. " + String(repeating: "Long text. ", count: 2000))
        let input = try await reader.analysisInput(document, collections: ["Insurance"])
        XCTAssertLessThanOrEqual(input.text.utf8.count, 4002)
        XCTAssertTrue(input.truncated)
        await run()
        XCTAssertTrue(try XCTUnwrap(repository.document(document.id)).needsReview)
        XCTAssertLessThan(try XCTUnwrap(repository.analysis(document.id)?.snapshot.result?.confidence), 0.65)
    }
    func testInterruptedAnalysisRecoversAndExplicitApplyPersists() async throws {
        var document = try seed()
        document.title = "Keep my title"
        try repository.update(document)
        let job = try XCTUnwrap(repository.analysis(document.id))
        job.state = "analyzing"; try repository.save()
        // Use a fresh repository after background recovery to avoid stale context snapshots.
        try await reader.recoverAnalysisQueue()
        repository = try ArchiveRepository(root: root)
        await run()
        XCTAssertEqual(try repository.document(document.id)?.title, "Keep my title")
        try repository.acceptAnalysis(document.id)
        XCTAssertEqual(try repository.document(document.id)?.title, "Insurance Policy")
        let reopened = try ArchiveRepository(root: root)
        XCTAssertEqual(try reopened.document(document.id)?.title, "Insurance Policy")
    }
    func testStaleRevisionCannotApplyAfterTextReset() async throws {
        let document = try seed()
        let gate = GatedUnderstandingProvider()
        let worker = DocumentIntelligenceProcessor(repository: repository, reader: reader, provider: gate)
        worker.start()
        await gate.waitForStart()
        _ = try repository.retryProcessing(document.id, restart: true)
        await gate.release()
        await worker.waitUntilIdle()
        XCTAssertEqual(try repository.document(document.id)?.title, "scan")
        XCTAssertEqual(try repository.analysis(document.id)?.state, "waitingText")
        XCTAssertNil(try repository.analysis(document.id)?.snapshot.result)
    }
    func testTrashDuringAnalysisPreventsApplicationAndRestoreRequeues() async throws {
        var document = try seed()
        let gate = GatedUnderstandingProvider()
        let worker = DocumentIntelligenceProcessor(repository: repository, reader: reader, provider: gate)
        worker.start(); await gate.waitForStart()
        document.trashedAt = Date(); try repository.update(document)
        await gate.release(); await worker.waitUntilIdle()
        XCTAssertEqual(try repository.document(document.id)?.title, "scan")
        XCTAssertEqual(try repository.analysis(document.id)?.state, "paused")
        document.trashedAt = nil; try repository.update(document)
        await run()
        XCTAssertEqual(try repository.analysis(document.id)?.state, "complete")
    }
    func testManualEditDuringAnalysisWins() async throws {
        var document = try seed()
        let gate = GatedUnderstandingProvider()
        let worker = DocumentIntelligenceProcessor(repository: repository, reader: reader, provider: gate)
        worker.start(); await gate.waitForStart()
        document.title = "Edited while model was running"
        try repository.update(document)
        await gate.release(); await worker.waitUntilIdle()
        XCTAssertEqual(try repository.document(document.id)?.title, document.title)
        XCTAssertEqual(try repository.document(document.id)?.collections, ["Insurance"])
    }
    func testCancellationRequeuesAnalysisWithoutApplyingMetadata() async throws {
        let document = try seed()
        let provider = SleepingUnderstandingProvider()
        let worker = DocumentIntelligenceProcessor(repository: repository, reader: reader, provider: provider)
        worker.start()
        while !(await provider.started) { await Task.yield() }
        await worker.stop()
        XCTAssertEqual(try repository.analysis(document.id)?.state, "queued")
        XCTAssertEqual(try repository.document(document.id)?.title, "scan")
    }
    func testAnalysisFailureDoesNotBlockNextDocumentOrOCRText() async throws {
        let first = try seed(), second = try seed()
        await run(provider: FailingOnceProvider())
        let states = try [first, second].map { try XCTUnwrap(repository.analysis($0.id)?.state) }
        XCTAssertEqual(states.filter { $0 == "failed" }.count, 1)
        XCTAssertEqual(states.filter { $0 == "complete" }.count, 1)
        let hits = try await reader.search("ABC123", destination: .recent, newestFirst: true)
        XCTAssertEqual(hits.total, 2)
    }
    func testV3MigrationProtectsExistingMetadata() async throws {
        let legacy = root.appendingPathComponent("Legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let document = try seed()
        try seedV3(root: legacy, document: document)
        let migrated = try ArchiveRepository(root: legacy)
        let container = migrated.container
        let service = await Task.detached { TextSearchService(modelContainer: container) }.value
        try await service.recoverAnalysisQueue()
        let worker = DocumentIntelligenceProcessor(repository: migrated, reader: service, provider: RuleBasedProvider())
        worker.start(); await worker.waitUntilIdle()
        XCTAssertEqual(try migrated.document(document.id)?.title, "scan")
        XCTAssertTrue(try XCTUnwrap(migrated.document(document.id)).needsReview)
        XCTAssertNotNil(try migrated.analysis(document.id)?.snapshot.result)
    }
    func testOnDeviceProviderAvailabilityAndFallback() async throws {
        let document = try seed()
        let input = try await reader.analysisInput(document, collections: ["Insurance"])
        if #available(macOS 26.0, *) {
            print("STOWKIT_MODEL_AVAILABILITY: \(SystemLanguageModel.default.availability)")
            if SystemLanguageModel.default.availability == .available {
                let result = try await AppleFoundationModelProvider().understand(input)
                XCTAssertEqual(result.provider, "Apple on-device model")
                XCTAssertFalse(result.title.isEmpty)
                return
            }
        }
        let result = try await LocalIntelligenceProvider().understand(input)
        XCTAssertEqual(result.provider, "Local rules")
        XCTAssertEqual(result.collection, "Insurance")
    }
    func testAutomaticMetadataRefreshCleansFilenameTitlesOnceWithoutProtectingThem() throws {
        let imported = Date(timeIntervalSince1970: 1_790_000_000)
        func insert(_ filename: String, title: String) throws -> HouseholdDocument {
            let id = UUID()
            let document = HouseholdDocument(id: id, archiveID: repository.archiveID, title: title, originalFilename: filename,
                documentDate: imported, importedAt: imported, modifiedAt: imported, contentType: "com.adobe.pdf",
                contentHash: id.uuidString, fileSize: 100, relativePath: "synthetic")
            try repository.insert(document)
            return document
        }
        let raw = try insert("Water_Bill_2026-03-15T08_00_00Z.pdf", title: "Water_Bill_2026-03-15T08_00_00Z")
        let owned = try insert("Scan_2026-04-01.pdf", title: "Scan_2026-04-01")
        var edited = try XCTUnwrap(repository.document(owned.id))
        edited.title = "Scan_2026-04-01"; edited.summary = "touched"   // a manual edit that leaves the title raw
        try repository.update(edited)
        var retitled = try XCTUnwrap(repository.document(owned.id)); retitled.title = "Kept by hand"
        try repository.update(retitled)

        try repository.refreshAutomaticMetadataOnce()
        let cleaned = try XCTUnwrap(repository.document(raw.id))
        XCTAssertEqual(cleaned.title, "Water Bill")
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: cleaned.documentDate),
                       DateComponents(year: 2026, month: 3, day: 15))
        XCTAssertFalse(try XCTUnwrap(repository.analysis(raw.id)).protectedFields.contains("title"),
                       "an automatic cleanup must not lock the title against better suggestions")
        XCTAssertEqual(try repository.document(owned.id)?.title, "Kept by hand", "a hand-edited title is never replaced")

        let late = try insert("Late_2026-05-01.pdf", title: "Late_2026-05-01")
        try repository.refreshAutomaticMetadataOnce()
        XCTAssertEqual(try repository.document(late.id)?.title, "Late_2026-05-01", "the pass runs once per archive")
    }
    func testAutomaticMetadataRefreshRequeuesRuleBasedAnalyses() async throws {
        let document = try seed()
        await run(provider: RuleBasedProvider())
        XCTAssertEqual(try repository.analysis(document.id)?.snapshot.result?.provider, "Local rules")
        try repository.refreshAutomaticMetadataOnce()
        XCTAssertEqual(try repository.analysis(document.id)?.state, "queued",
                       "documents the model never read get another chance now that refusals are retried")
    }
    func testLabeledModelAnswerParsesAndIgnoresNoise() {
        let fields = ModelFields.parseLabeled("""
        Here is the result:
        - TITLE: Prior Authorization Request
        TYPE: Patient authorization form
        collection: Medical
        CORRESPONDENT: Example Health Pharmacy
        TAGS: pharmacy, authorization,  , prescription
        SUMMARY: A request for prior authorization of a prescription.
        EVIDENCE: Patient authorization form
        NOTE: ignored
        """)
        XCTAssertEqual(fields.title, "Prior Authorization Request")
        XCTAssertEqual(fields.documentType, "Patient authorization form")
        XCTAssertEqual(fields.collection, "Medical", "labels are case-insensitive")
        XCTAssertEqual(fields.correspondent, "Example Health Pharmacy")
        XCTAssertEqual(fields.tags, ["pharmacy", "authorization", "prescription"])
        XCTAssertEqual(fields.evidence, "Patient authorization form")
        XCTAssertEqual(ModelFields.parseLabeled("no labels at all"), ModelFields())
        // Observed live on macOS 27: every field on one line, separated by " / ".
        let oneLine = ModelFields.parseLabeled("TITLE: Prior Authorization Request / TYPE: Medical / COLLECTION: Medical / CORRESPONDENT: Example Health Pharmacy / TAGS: Authorization, Pharmacy / SUMMARY: A request. / EVIDENCE: Patient authorization form")
        XCTAssertEqual(oneLine.title, "Prior Authorization Request")
        XCTAssertEqual(oneLine.collection, "Medical")
        XCTAssertEqual(oneLine.tags, ["Authorization", "Pharmacy"])
        XCTAssertEqual(oneLine.evidence, "Patient authorization form")
    }
    /// Live, on this Mac: Apple's default guardrails refuse medical text, which used to drop
    /// every medical record to the rule-based fallback. Skips where the model is unavailable.
    func testOnDeviceModelReadsMedicalDocumentsInsteadOfFallingBack() async throws {
        guard #available(macOS 26.0, *), SystemLanguageModel.default.availability == .available else {
            throw XCTSkip("Apple's on-device model is not available on this Mac")
        }
        let document = try seed()
        let text = "Example Health Pharmacy. Patient authorization form. Prior authorization request for a weight management medication. Member ID FAKE-123. Prescriber signature required."
        let input = UnderstandingInput(document: document, text: text, collections: ["Medical", "Insurance", "Receipts"], truncated: false)
        let result = try await AppleFoundationModelProvider().understand(input)
        XCTAssertEqual(result.provider, "Apple on-device model")
        XCTAssertFalse(result.title.isEmpty)
        let fallback = try await LocalIntelligenceProvider().understand(input)
        XCTAssertEqual(fallback.provider, "Apple on-device model", "the medical record must not fall back to rules")
    }
    private func seedV3(root: URL, document: HouseholdDocument) throws {
        let schema = Schema(versionedSchema: ArchiveSchemaV3.self)
        let config = ModelConfiguration("StowKit", schema: schema, url: root.appendingPathComponent("Library.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let archive = ArchiveSchemaV1.ArchiveRecord(); archive.id = document.archiveID
        context.insert(archive); context.insert(ArchiveSchemaV1.DocumentRecord(document))
        let job = ArchiveSchemaV2.ProcessingJobRecord(documentID: document.id); job.state = "complete"
        context.insert(job)
        context.insert(ArchiveSchemaV2.PageTextRecord(documentID: document.id, pageIndex: 0, page: .init(text: "Insurance policy. Policy number ABC123.", method: .embedded)))
        try context.save()
    }
    // Patterns measured on the owner's documents, where an exact match rejected 3 of 4 collections.
    func testEvidenceSurvivesReflowedSpacingAndPunctuation() {
        let text = "PROPERTY TAX RECEIPT\nTreasurer's Office —\nParcel 12-345, June 2025"
        XCTAssertTrue(UnderstandingPolicy.evidenceSupported("Property tax receipt Treasurer's office", by: text), "line break and case")
        XCTAssertTrue(UnderstandingPolicy.evidenceSupported("parcel 12 345 june 2025", by: text), "punctuation")
    }
    func testEvidenceJoinedFromSeparateLinesPassesWhenEveryWordIsPresent() {
        let text = "Kitchen fixtures\nProposal prepared by STARK Construction\nReplace ceiling fan in hallway"
        XCTAssertTrue(UnderstandingPolicy.evidenceSupported("STARK Construction replace kitchen ceiling fan", by: text))
    }
    func testEvidenceWithAnInventedWordOrTooShortStillFails() {
        let text = "Kitchen fixtures proposal prepared by STARK Construction"
        XCTAssertFalse(UnderstandingPolicy.evidenceSupported("STARK Construction roofing proposal", by: text), "roofing isn't in the document")
        XCTAssertFalse(UnderstandingPolicy.evidenceSupported("proposal kitchen", by: text), "two words out of order are too weak")
        XCTAssertTrue(UnderstandingPolicy.evidenceSupported("fixtures proposal", by: text), "two words in order are a real quote")
        XCTAssertFalse(UnderstandingPolicy.evidenceSupported("abc", by: "abc"), "too short to support anything")
        XCTAssertFalse(UnderstandingPolicy.evidenceSupported("", by: text))
    }
    func testReflowedEvidenceKeepsTheCollectionThroughValidation() {
        let date = Date()
        let document = HouseholdDocument(id: UUID(), archiveID: UUID(), title: "scan", originalFilename: "scan.pdf", documentDate: date,
            importedAt: date, modifiedAt: date, contentType: "com.adobe.pdf", contentHash: String(repeating: "a", count: 64), fileSize: 1,
            relativePath: "Originals/aa/scan.pdf")
        let input = UnderstandingInput(document: document, text: "PROPERTY TAX RECEIPT\nTreasurer's Office\nParcel 12-345",
                                       collections: ["Taxes", "Home"], truncated: false)
        let result = UnderstandingPolicy.validated(DocumentUnderstanding(collection: "Taxes", evidence: "Property tax receipt, Treasurer's office", confidence: 0.7), input: input)
        XCTAssertEqual(result.collection, "Taxes")
        XCTAssertEqual(result.confidence, 0.7)
    }
}

private actor GatedUnderstandingProvider: DocumentIntelligenceProvider {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func understand(_ input: UnderstandingInput) async throws -> DocumentUnderstanding {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return try await RuleBasedProvider().understand(input)
    }
    func waitForStart() async {
        while !started { await Task.yield() }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private actor FailingOnceProvider: DocumentIntelligenceProvider {
    private var failed = false
    func understand(_ input: UnderstandingInput) async throws -> DocumentUnderstanding {
        if !failed { failed = true; throw IntelligenceError.unavailable }
        return try await RuleBasedProvider().understand(input)
    }
}

private actor SleepingUnderstandingProvider: DocumentIntelligenceProvider {
    private(set) var started = false
    func understand(_ input: UnderstandingInput) async throws -> DocumentUnderstanding {
        started = true
        try await Task.sleep(for: .seconds(30))
        return try await RuleBasedProvider().understand(input)
    }

}
