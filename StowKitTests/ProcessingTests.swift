import XCTest
import SwiftData
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import StowKit

@MainActor final class ProcessingTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("Archive") }
    private var storage: DocumentStorageManager!
    private var repository: ArchiveRepository!
    private var importer: DocumentImporter!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitProcessingTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storage = DocumentStorageManager(root: root)
        try await storage.prepare()
        repository = try ArchiveRepository(root: root)
        importer = DocumentImporter(repository: repository, storage: storage)
    }
    override func tearDown() async throws {
        importer = nil; repository = nil; storage = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testV1MigrationPreservesArchiveAndBackfillsJobs() async throws {
        let oldRoot = directory.appendingPathComponent("V1Archive")
        let oldStorage = DocumentStorageManager(root: oldRoot)
        try await oldStorage.prepare()
        let receipt = try await oldStorage.stage(makePDF("Legacy.pdf"))
        try await oldStorage.promote(receipt)
        var document = receipt.document(archiveID: UUID())
        document.title = "Existing household record"
        document.favorite = true
        document.tags = "keep-this"
        document.collections = ["Home", "Custom"]
        try seedV1(root: oldRoot, document: document)
        try await oldStorage.finish(receipt)
        let migrated = try ArchiveRepository(root: oldRoot)
        XCTAssertEqual(try migrated.documents(), [document])
        XCTAssertEqual(migrated.archiveID, document.archiveID)
        XCTAssertTrue(try migrated.collections().contains { $0.name == "Custom" })
        let migratedContainer = migrated.container
        let migrationService = await Task.detached { TextSearchService(modelContainer: migratedContainer) }.value
        try await migrationService.recoverProcessingQueue()
        XCTAssertEqual(try migrated.processingJob(document.id)?.snapshot.state, .queued)
        XCTAssertEqual(try migrated.processingSnapshots().count, 1)
        let hash = try await oldStorage.hash(oldStorage.originalURL(for: document.relativePath))
        XCTAssertEqual(hash, document.contentHash)
    }

    func testImportAtomicallyCreatesOneQueuedJobIncludingDuplicates() async throws {
        let source = try makePDF("Queued.pdf")
        let document = try await importer.importFile(source).document
        XCTAssertEqual(try repository.processingJob(document.id)?.snapshot.state, .queued)
        _ = try await importer.importFile(source)
        XCTAssertEqual(try repository.processingSnapshots().count, 1)
    }

    func testEmbeddedPDFTextExtractionPreservesOriginal() async throws {
        let source = try makePDF("Digital.pdf")
        let bytes = try Data(contentsOf: source)
        let document = try await importer.importFile(source).document
        let service = OCRService()
        let input = try extractionInput(document)
        let count = try await service.pageCount(for: input)
        let page = try await service.extractPage(for: input, index: 0)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(page.method, .embedded)
        XCTAssertTrue(page.text.contains("HOUSEHOLD INSURANCE"))
        XCTAssertEqual(try Data(contentsOf: input.url), bytes)
    }

    func testVisionReadsImageAndScannedPDF() async throws {
        let sources = [try makeImage("Scan.png"), try makePDF("Scan.pdf", scannedOnly: true)]
        let service = OCRService()
        for source in sources {
            let document = try await importer.importFile(source).document
            let input = try extractionInput(document)
            _ = try await service.pageCount(for: input)
            let page = try await service.extractPage(for: input, index: 0)
            XCTAssertEqual(page.method, .ocr)
            XCTAssertTrue(page.text.uppercased().contains("STOWKIT"), page.text)
            XCTAssertTrue(page.text.uppercased().contains("WATER BILL"), page.text)
        }
    }

    func testMixedPDFPersistsPerPageMethodsAndSearchableText() async throws {
        let document = try await importer.importFile(makePDF("Mixed.pdf", mixed: true)).document
        let processor = DocumentProcessor(repository: repository, storage: storage)
        processor.start()
        await processor.waitUntilIdle()
        let snapshot = try XCTUnwrap(repository.processingJob(document.id)?.snapshot)
        XCTAssertEqual(snapshot.state, .complete)
        XCTAssertEqual(snapshot.completedPages, 2)
        XCTAssertEqual(snapshot.ocrPages, 1)
        let service = await reader()
        let pages = try await service.pages(for: document.id)
        XCTAssertEqual(pages.map(\.method), [.embedded, .ocr])
        try await service.configure(root: root, archiveID: repository.archiveID)
        let hits = try await service.search("water", destination: .recent, newestFirst: true)
        XCTAssertEqual(hits.hits.map(\.document.id), [document.id])
        XCTAssertFalse(document.searchableText.lowercased().contains("water"))
    }

    func testFailureKeepsPartialTextAndRetryResumesAtFailedPage() async throws {
        let document = try await importer.importFile(makePDF("Retry.pdf")).document
        let extractor = ScriptedExtractor(failOnceAt: 1)
        let processor = DocumentProcessor(repository: repository, storage: storage, extractor: extractor)
        processor.start()
        await processor.waitUntilIdle()
        let failed = try XCTUnwrap(repository.processingJob(document.id)?.snapshot)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.completedPages, 1)
        XCTAssertNotNil(failed.error)
        XCTAssertEqual(failed.failedStage, ProcessingState.extractingText.label)
        let service = await reader()
        let partial = try await service.pages(for: document.id)
        XCTAssertEqual(partial.count, 1)
        _ = try repository.retryProcessing(document.id)
        processor.start()
        await processor.waitUntilIdle()
        XCTAssertEqual(try repository.processingJob(document.id)?.snapshot.state, .complete)
        let calls = await extractor.calls
        XCTAssertEqual(calls, [0: 1, 1: 2, 2: 1])
        let pages = try await service.pages(for: document.id)
        XCTAssertEqual(pages.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try storage.originalURL(for: document.relativePath).path))
    }

    func testInterruptedProcessingResumesCommittedCheckpointAfterReopen() async throws {
        let document = try await importer.importFile(makePDF("Resume.pdf")).document
        _ = try repository.setProcessingState(document.id, .extractingText)
        _ = try repository.setPageCount(document.id, count: 3)
        _ = try repository.savePage(document.id, index: 0, result: .init(text: "Already saved", method: .embedded))
        _ = try repository.setProcessingState(document.id, .savingText)
        let reopened = try ArchiveRepository(root: root)
        let recoveryContainer = reopened.container
        let recoveryService = await Task.detached { TextSearchService(modelContainer: recoveryContainer) }.value
        try await recoveryService.recoverProcessingQueue()
        let extractor = ScriptedExtractor()
        let processor = DocumentProcessor(repository: reopened, storage: storage, extractor: extractor)
        processor.start()
        await processor.waitUntilIdle()
        let calls = await extractor.calls
        XCTAssertEqual(calls, [1: 1, 2: 1])
        XCTAssertEqual(try reopened.processingJob(document.id)?.snapshot.state, .complete)
        let freshContainer = reopened.container
        let service = await Task.detached { TextSearchService(modelContainer: freshContainer) }.value
        let pages = try await service.pages(for: document.id)
        XCTAssertEqual(pages.first?.text, "Already saved")
    }

    func testCancellationLeavesJobQueuedWithoutSkippingPage() async throws {
        let document = try await importer.importFile(makePDF("Cancel.pdf")).document
        let extractor = ScriptedExtractor(delay: true)
        let processor = DocumentProcessor(repository: repository, storage: storage, extractor: extractor)
        processor.start()
        let deadline = Date().addingTimeInterval(5)
        while await extractor.calls.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await processor.stop()
        let snapshot = try XCTUnwrap(repository.processingJob(document.id)?.snapshot)
        XCTAssertEqual(snapshot.state, .queued)
        XCTAssertEqual(snapshot.completedPages, 0)
        XCTAssertNil(snapshot.error)
    }

    func testTrashPausesAndRestoreContinuesProcessing() async throws {
        var document = try await importer.importFile(makePDF("Trash.pdf")).document
        let extractor = ScriptedExtractor()
        var pausedOnce = false
        let processor = DocumentProcessor(repository: repository, storage: storage, extractor: extractor, onUpdate: { snapshot in
            if snapshot.completedPages == 1 && !pausedOnce {
                pausedOnce = true
                document.trashedAt = Date()
                do { try self.repository.update(document) } catch { XCTFail(error.localizedDescription) }
            }
        })
        processor.start()
        await processor.waitUntilIdle()
        XCTAssertEqual(try repository.processingJob(document.id)?.snapshot.state, .paused)
        let before = await extractor.calls
        XCTAssertEqual(before, [0: 1])
        document.trashedAt = nil
        try repository.update(document)
        processor.start()
        await processor.waitUntilIdle()
        XCTAssertEqual(try repository.processingJob(document.id)?.snapshot.state, .complete)
        let after = await extractor.calls
        XCTAssertEqual(after, [0: 1, 1: 1, 2: 1])
    }

    func testLockedPDFFailsWithoutBlockingNextDocument() async throws {
        let locked = try await importer.importFile(makePDF("Locked.pdf", password: "testing-only")).document
        let good = try await importer.importFile(makePDF("Good.pdf")).document
        let processor = DocumentProcessor(repository: repository, storage: storage)
        processor.start()
        await processor.waitUntilIdle()
        XCTAssertEqual(try repository.processingJob(locked.id)?.snapshot.state, .failed)
        XCTAssertTrue(try XCTUnwrap(repository.processingJob(locked.id)?.snapshot.error).contains("password"))
        XCTAssertEqual(try repository.processingJob(good.id)?.snapshot.state, .complete)
        XCTAssertEqual(try repository.documents().count, 2)
    }

    func testBlankImageCompletesWithNoTextAndMissingOriginalFails() async throws {
        let blank = try await importer.importFile(makeImage("Blank.png", blank: true)).document
        let missing = try await importer.importFile(makePDF("Missing.pdf")).document
        try FileManager.default.removeItem(at: storage.originalURL(for: missing.relativePath))
        let processor = DocumentProcessor(repository: repository, storage: storage)
        processor.start()
        await processor.waitUntilIdle()
        XCTAssertEqual(try repository.processingJob(blank.id)?.snapshot.state, .complete)
        XCTAssertEqual(try repository.processingJob(blank.id)?.snapshot.characterCount, 0)
        XCTAssertEqual(try repository.processingJob(missing.id)?.snapshot.state, .failed)
    }

    func testSearchCombinesMetadataAndTextAcrossPagesAndRefreshesAfterRestart() async throws {
        var document = try await importer.importFile(makePDF("Household.pdf")).document
        document.title = "Household"
        try repository.update(document)
        let extractor = ScriptedExtractor()
        let processor = DocumentProcessor(repository: repository, storage: storage, extractor: extractor)
        processor.start()
        await processor.waitUntilIdle()
        let store = LibraryStore(root: root, processingEnabled: false)
        await store.start()
        store.search = "household café renewal"
        let deadline = Date().addingTimeInterval(5)
        while store.isSearchingText && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.visibleDocuments.map(\.id), [document.id])
        let service = await reader()
        let before = try await service.pages(for: document.id)
        XCTAssertEqual(before.count, 3)
        _ = try repository.retryProcessing(document.id, restart: true)
        let cleared = try await service.pages(for: document.id)
        XCTAssertTrue(cleared.isEmpty)
        processor.start()
        await processor.waitUntilIdle()
        let after = try await service.pages(for: document.id)
        XCTAssertEqual(after.count, 3)
        store.moveToTrash(document.id)
        await store.waitForSearch()
        XCTAssertTrue(store.visibleDocuments.isEmpty)
    }

    func testMovingToTrashDuringFailingRequestKeepsJobResumable() async throws {
        var document = try await importer.importFile(makePDF("Trash During OCR.pdf")).document
        let extractor = GatedFailingExtractor()
        let processor = DocumentProcessor(repository: repository, storage: storage, extractor: extractor)
        processor.start()
        let deadline = Date().addingTimeInterval(5)
        while !(await extractor.started) && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        document.trashedAt = Date()
        try repository.update(document)
        await extractor.unblock()
        await processor.waitUntilIdle()
        XCTAssertEqual(try repository.processingJob(document.id)?.snapshot.state, .paused)
        document.trashedAt = nil
        try repository.update(document)
        XCTAssertEqual(try repository.processingJob(document.id)?.snapshot.state, .queued)
    }

    private func reader() async -> TextSearchService {
        let container = repository.container
        return await Task.detached { TextSearchService(modelContainer: container) }.value
    }
    private func extractionInput(_ document: HouseholdDocument) throws -> ExtractionInput {
        ExtractionInput(documentID: document.id, url: try storage.originalURL(for: document.relativePath), isImage: document.isImage)
    }
    private func seedV1(root: URL, document: HouseholdDocument) throws {
        let schema = Schema(versionedSchema: ArchiveSchemaV1.self)
        let config = ModelConfiguration("StowKit", schema: schema, url: root.appendingPathComponent("Library.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let archive = ArchiveSchemaV1.ArchiveRecord()
        archive.id = document.archiveID
        context.insert(archive)
        context.insert(ArchiveSchemaV1.DocumentRecord(document))
        context.insert(ArchiveSchemaV1.CollectionRecord(.init(name: "Custom", symbol: "folder")))
        try context.save()
    }
    private func makePDF(_ name: String, mixed: Bool = false, scannedOnly: Bool = false, password: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let options: CFDictionary? = password.map { [kCGPDFContextUserPassword: $0, kCGPDFContextOwnerPassword: "owner-testing-only"] as CFDictionary }
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, options))
        for page in 0..<(mixed ? 2 : 1) {
            context.beginPDFPage(nil)
            if scannedOnly || page == 1 {
                context.draw(try scanImage(blank: false), in: box)
            } else {
                drawText(context, "HOUSEHOLD INSURANCE POLICY", y: 690, size: 24)
                drawText(context, "Coverage includes the home, personal property, and liability.", y: 630, size: 15)
                drawText(context, "Keep this document with your household records for reference.", y: 600, size: 15)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
    private func makeImage(_ name: String, blank: Bool = false) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try scanImage(blank: blank), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    private func scanImage(blank: Bool) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
        if !blank {
            drawText(context, "STOWKIT WATER BILL", y: 1400, size: 60)
            drawText(context, "BALANCE DUE 124.80", y: 1200, size: 48)
            drawText(context, "Fictional document for local OCR testing", y: 1050, size: 36)
        }
        return try XCTUnwrap(context.makeImage())
    }
    private func drawText(_ context: CGContext, _ text: String, y: CGFloat, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 54, y: y)
        CTLineDraw(line, context)
    }
}

private actor ScriptedExtractor: DocumentTextExtractor {
    private var failOnceAt: Int?
    private let delay: Bool
    private(set) var calls: [Int: Int] = [:]
    init(failOnceAt: Int? = nil, delay: Bool = false) { self.failOnceAt = failOnceAt; self.delay = delay }
    func pageCount(for input: ExtractionInput) -> Int { 3 }
    func extractPage(for input: ExtractionInput, index: Int) async throws -> ExtractedPage {
        calls[index, default: 0] += 1
        if delay { try await Task.sleep(for: .seconds(10)) }
        if failOnceAt == index { failOnceAt = nil; throw ProcessingError.unreadablePage }
        return ExtractedPage(text: ["Café policy", "renewal deadline", "last page"][index], method: .embedded)
    }
}

private actor GatedFailingExtractor: DocumentTextExtractor {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pageCount(for input: ExtractionInput) -> Int { 1 }
    func extractPage(for input: ExtractionInput, index: Int) async throws -> ExtractedPage {
        started = true
        await withCheckedContinuation { continuation = $0 }
        throw ProcessingError.unreadablePage
    }
    func unblock() { continuation?.resume(); continuation = nil }
}
