import XCTest
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import StowKit

@MainActor final class ArchiveTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("Archive") }
    private var storage: DocumentStorageManager!
    private var repository: ArchiveRepository!
    private var importer: DocumentImporter!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitTests-\(UUID())")
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

    func testPDFImportPreservesBytesAndSurvivesReopening() async throws {
        let source = try pdf("Property Tax.pdf")
        let before = try Data(contentsOf: source)
        let result = try await importer.importFile(source)
        let original = try storage.originalURL(for: result.document.relativePath)
        XCTAssertFalse(result.isDuplicate)
        XCTAssertEqual(try Data(contentsOf: original), before)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(result.document.contentHash, SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(result.document.fileSize, Int64(before.count))
        XCTAssertEqual(result.document.contentType, UTType.pdf.identifier)
        XCTAssertTrue(result.document.needsReview)
        let reopened = try ArchiveRepository(root: root)
        XCTAssertEqual(try reopened.documents(), [result.document])
        XCTAssertEqual(reopened.archiveID, repository.archiveID)
        let pending = try await storage.pendingReceipts()
        XCTAssertTrue(pending.receipts.isEmpty)
        XCTAssertTrue(pending.errors.isEmpty)
    }

    func testMetadataCollectionsTrashAndRestorePersist() async throws {
        var document = try await importer.importFile(pdf("Warranty.pdf")).document
        _ = try repository.addCollection("Appliances")
        document.title = "Refrigerator Warranty"
        document.correspondent = "LG"
        document.summary = "Parts and labor"
        document.collections = ["Home", "Appliances"]
        document.tags = "kitchen, warranty"
        document.entities = "Refrigerator"
        document.favorite = true
        document.needsReview = false
        document.trashedAt = Date()
        try repository.update(document)
        var reopened: ArchiveRepository? = try ArchiveRepository(root: root)
        XCTAssertEqual(try reopened?.documents().first, document)
        XCTAssertTrue(try XCTUnwrap(reopened).collections().contains { $0.name == "Appliances" })
        XCTAssertThrowsError(try repository.addCollection(" appliances "))
        document.trashedAt = nil
        try repository.update(document)
        reopened = try ArchiveRepository(root: root)
        XCTAssertNil(try XCTUnwrap(reopened?.documents().first).trashedAt)
        XCTAssertEqual(try Data(contentsOf: storage.originalURL(for: document.relativePath)), try Data(contentsOf: directory.appendingPathComponent("Warranty.pdf")))
    }

    func testRenamedDuplicateAndTrashedDuplicateDoNotCreateCopies() async throws {
        let source = try pdf("Original.pdf")
        let renamed = directory.appendingPathComponent("Different Name.pdf")
        try FileManager.default.copyItem(at: source, to: renamed)
        var first = try await importer.importFile(source).document
        first.title = "Edited title"
        first.trashedAt = Date()
        try repository.update(first)
        let duplicate = try await importer.importFile(renamed)
        XCTAssertTrue(duplicate.isDuplicate)
        XCTAssertEqual(duplicate.document, first)
        XCTAssertEqual(try repository.documents().count, 1)
        let originals = FileManager.default.enumerator(at: root.appendingPathComponent("Originals"), includingPropertiesForKeys: nil)!.allObjects as! [URL]
        XCTAssertEqual(originals.filter { $0.pathExtension == "pdf" }.count, 1)
        let pending = try await storage.pendingReceipts()
        XCTAssertTrue(pending.receipts.isEmpty)
    }

    func testDifferentBytesWithSameNameAreSeparateDocuments() async throws {
        let source = try pdf("Statement.pdf", width: 612)
        _ = try await importer.importFile(source)
        _ = try pdf("Statement.pdf", width: 500)
        let second = try await importer.importFile(source)
        XCTAssertFalse(second.isDuplicate)
        XCTAssertEqual(try repository.documents().count, 2)
    }

    func testSupportedImageFormatsAndThumbnails() async throws {
        let thumbnails = ThumbnailService(storage: storage)
        for type in [UTType.jpeg, .png, .heic] {
            let source = try image(type)
            let before = try Data(contentsOf: source)
            let document = try await importer.importFile(source).document
            XCTAssertTrue(document.isImage)
            XCTAssertEqual(try Data(contentsOf: storage.originalURL(for: document.relativePath)), before)
            let data = try await thumbnails.thumbnail(for: document)
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let rendered = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            XCTAssertLessThanOrEqual(max(rendered.width, rendered.height), 160)
            let preview = try await thumbnails.imagePreview(for: document)
            XCTAssertFalse(preview.isEmpty)
        }
        XCTAssertEqual(try repository.documents().count, 3)
    }

    func testPDFThumbnailAndOpenCopyProtectOriginal() async throws {
        let document = try await importer.importFile(pdf("Policy.pdf")).document
        let thumbnails = ThumbnailService(storage: storage)
        let thumbnail = try await thumbnails.thumbnail(for: document)
        XCTAssertNotNil(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let original = try storage.originalURL(for: document.relativePath)
        let before = try Data(contentsOf: original)
        let copy = try await storage.prepareOpenCopy(document)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        XCTAssertNotEqual(copy, original)
        try Data("Edited in another app".utf8).write(to: copy)
        XCTAssertEqual(try Data(contentsOf: original), before)
    }

    func testRejectsUnsupportedEmptyAndMismatchedFiles() async throws {
        for name in ["notes.txt", "empty.pdf", "fake.png", "fake.pdf"] {
            let source = directory.appendingPathComponent(name)
            try Data(name == "empty.pdf" ? [] : Array("not a document".utf8)).write(to: source)
            do { _ = try await importer.importFile(source); XCTFail("Should reject \(name)") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        XCTAssertTrue(try repository.documents().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Staging").path).isEmpty)
    }

    func testRecoveryAfterStagingAndAfterPromotion() async throws {
        let staged = try await storage.stage(pdf("Staged.pdf", width: 400))
        let promoted = try await storage.stage(pdf("Promoted.pdf", width: 500))
        try await storage.promote(promoted)
        let recovered = try await importer.recover()
        XCTAssertEqual(recovered, 2)
        XCTAssertEqual(Set(try repository.documents().map(\.id)), [staged.id, promoted.id])
        for receipt in [staged, promoted] {
            let actual = try await storage.hash(storage.originalURL(for: receipt.relativePath))
            XCTAssertEqual(actual, receipt.contentHash)
        }
        let replay = try await importer.recover()
        XCTAssertEqual(replay, 0)
    }

    func testRecoveryAfterMetadataCommitIsIdempotent() async throws {
        let receipt = try await storage.stage(pdf("Committed.pdf"))
        try await storage.promote(receipt)
        try repository.insert(receipt.document(archiveID: repository.archiveID))
        let count = try await importer.recover()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try repository.documents().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try storage.originalURL(for: receipt.relativePath).path))
    }

    func testCorruptRecoveryDoesNotBlockValidImport() async throws {
        let corrupt = root.appendingPathComponent("Staging/\(UUID())")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("invalid JSON".utf8).write(to: corrupt.appendingPathComponent("receipt.json"))
        let valid = try await storage.stage(pdf("Recover Me.pdf"))
        do { _ = try await importer.recover(); XCTFail("Should report the damaged recovery record") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Recovery record")) }
        XCTAssertEqual(try repository.documents().first?.id, valid.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.appendingPathComponent("receipt.json").path))
    }

    func testMissingOriginalDoesNotDiscardDuplicateRecoveryCopy() async throws {
        let source = try pdf("Missing.pdf")
        let first = try await importer.importFile(source).document
        try FileManager.default.removeItem(at: storage.originalURL(for: first.relativePath))
        do { _ = try await importer.importFile(source); XCTFail("Must not claim a safe duplicate when the original is missing") }
        catch { }
        let pending = try await storage.pendingReceipts()
        XCTAssertEqual(pending.receipts.count, 1)
    }

    func testInterruptedPartialCopyIsCleanedWithoutTouchingSource() async throws {
        let source = try pdf("Safe Source.pdf")
        let bytes = try Data(contentsOf: source)
        let partial = root.appendingPathComponent("Staging/\(UUID())")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data(bytes.prefix(20)).write(to: partial.appendingPathComponent("original.pdf"))
        _ = try await importer.recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testLibraryStoreBatchContinuesAfterFailureAndPersistsEdits() async throws {
        let store = LibraryStore(root: root, processingEnabled: false)
        await store.start()
        XCTAssertTrue(store.isReady)
        let bad = directory.appendingPathComponent("bad.txt")
        try Data("unsupported".utf8).write(to: bad)
        let source = try pdf("Batch.pdf")
        store.enqueueImports([bad, source, source])
        let deadline = Date().addingTimeInterval(20)
        while store.isImporting && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        await store.waitForSearch()
        XCTAssertFalse(store.isImporting)
        XCTAssertEqual(store.documents.count, 1)
        XCTAssertEqual(store.importReport?.duplicates, 1)
        XCTAssertEqual(store.importReport?.issues.filter { $0.documentID == nil }.count, 1)
        var document = try XCTUnwrap(store.documents.first)
        document.title = "Saved household record"
        document.tags = "house, 2026"
        store.update(document)
        store.moveToTrash(document.id)
        await store.waitForSearch()
        XCTAssertTrue(store.visibleDocuments.isEmpty)
        store.destination = .trash
        await store.waitForSearch()
        XCTAssertEqual(store.visibleDocuments.count, 1)
        store.restore(document.id)
        store.destination = .recent
        store.search = "house 2026"
        let searchDeadline = Date().addingTimeInterval(5)
        while store.isSearchingText && Date() < searchDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(store.isSearchingText)
        XCTAssertNil(store.textSearchError)
        XCTAssertEqual(store.visibleDocuments.count, 1)
        let reopened = LibraryStore(root: root, processingEnabled: false)
        await reopened.start()
        XCTAssertEqual(reopened.documents.first?.title, "Saved household record")
        XCTAssertNil(reopened.documents.first?.trashedAt)
    }

    func testDroppedFileProvidersImportURLsAndDataRepresentations() async throws {
        let store = LibraryStore(root: root, processingEnabled: false)
        await store.start()
        let first = try pdf("Drop URL.pdf", width: 400)
        let second = try pdf("Drop Data.pdf", width: 500)
        let providers = [
            NSItemProvider(item: first as NSURL, typeIdentifier: UTType.fileURL.identifier),
            NSItemProvider(item: Data(second.absoluteString.utf8) as NSData, typeIdentifier: UTType.fileURL.identifier)
        ]
        XCTAssertTrue(store.acceptDrop(providers))
        let deadline = Date().addingTimeInterval(20)
        while store.documents.count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.documents.count, 2)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.acceptDrop([NSItemProvider(object: "not a file" as NSString)]))
    }

    func testUnsafePathsAreRejected() throws {
        for path in ["../../secret.pdf", "/tmp/secret.pdf", "Originals/AA/not-a-uuid.pdf"] {
            XCTAssertThrowsError(try storage.originalURL(for: path))
        }
    }

    func testConcurrentDuplicateImportsCreateOneRecord() async throws {
        let source = try pdf("Concurrent.pdf")
        async let first = importer.importFile(source)
        async let second = importer.importFile(source)
        let results = try await [first, second]
        XCTAssertEqual(results.filter(\.isDuplicate).count, 1)
        XCTAssertEqual(try repository.documents().count, 1)
        XCTAssertEqual(results[0].document.id, results[1].document.id)
    }

    func testLargePNGPreservesBytesAcrossStreamingChunks() async throws {
        let source = directory.appendingPathComponent("Large.png")
        var state: UInt32 = 42
        var pixels = [UInt8](repeating: 0, count: 1024 * 1024 * 4)
        for index in pixels.indices {
            state = state &* 1664525 &+ 1013904223
            pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1024, height: 1024, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let bytes = try Data(contentsOf: source)
        XCTAssertGreaterThan(bytes.count, 2 * 1_048_576)
        let document = try await importer.importFile(source).document
        XCTAssertEqual(document.fileSize, Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: storage.originalURL(for: document.relativePath)), bytes)
    }

    func testFilenameMetadataCleansTitlesAndReadsYearFirstDates() {
        let calendar = Calendar.current
        func ymd(_ date: Date?) -> DateComponents? { date.map { calendar.dateComponents([.year, .month, .day], from: $0) } }
        let export = FilenameMetadata(filename: "NovoCare_Patient_OBES_Patient_Authorization_FORM_2026-09-17T00_18_36Z.pdf")
        XCTAssertEqual(export.title, "NovoCare Patient OBES Patient Authorization FORM")
        XCTAssertEqual(ymd(export.date), DateComponents(year: 2026, month: 9, day: 17))
        XCTAssertEqual(ymd(FilenameMetadata(filename: "Scan_20260412_101530.png").date), DateComponents(year: 2026, month: 4, day: 12))
        XCTAssertEqual(FilenameMetadata(filename: "Scan_20260412_101530.png").title, "Scan")
        XCTAssertEqual(ymd(FilenameMetadata(filename: "Tax Return 2025_04_15.pdf").date), DateComponents(year: 2025, month: 4, day: 15))
        // Unchanged: ordinary names, invalid dates, ambiguous month-first dates, bare years.
        XCTAssertEqual(FilenameMetadata(filename: "Property Tax.pdf"), FilenameMetadata(filename: "Property Tax.pdf"))
        XCTAssertEqual(FilenameMetadata(filename: "Property Tax.pdf").title, "Property Tax")
        XCTAssertNil(FilenameMetadata(filename: "Property Tax.pdf").date)
        XCTAssertNil(FilenameMetadata(filename: "Invoice 2026-02-30.pdf").date, "February 30th is not a date")
        XCTAssertNil(FilenameMetadata(filename: "Invoice 03-04-2026.pdf").date, "month-first dates are ambiguous")
        XCTAssertNil(FilenameMetadata(filename: "Pre-Approval 2026.pdf").date)
        XCTAssertEqual(FilenameMetadata(filename: "Pre-Approval 2026.pdf").title, "Pre-Approval 2026", "hyphens inside words survive")
        XCTAssertEqual(FilenameMetadata(filename: "2026-09-17.pdf").title, "2026-09-17", "never an empty title")
    }

    func testImportUsesCleanTitleAndFilenameDate() async throws {
        let document = try await importer.importFile(pdf("Water_Bill_2026-03-15.pdf")).document
        XCTAssertEqual(document.title, "Water Bill")
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: document.documentDate),
                       DateComponents(year: 2026, month: 3, day: 15))
        XCTAssertEqual(document.originalFilename, "Water_Bill_2026-03-15.pdf", "the original filename is kept exactly")
        let plain = try await importer.importFile(pdf("Receipt.pdf", width: 600)).document   // distinct bytes, not a duplicate
        XCTAssertEqual(plain.documentDate, plain.importedAt, "with no date in the name, the import date stands in")
    }

    func testUsageMeasuresDiskAndSeparatesOriginalsFromDerivedData() async throws {
        let empty = try await storage.usage()
        XCTAssertEqual(empty.originals, 0)
        XCTAssertEqual(empty.originalFiles, 0)

        let first = try await importer.importFile(pdf("Usage One.pdf")).document
        let second = try await importer.importFile(image(.png)).document
        let usage = try await storage.usage()

        XCTAssertEqual(usage.originalFiles, 2)
        XCTAssertEqual(usage.unreadable, 0)
        // Allocated size is rounded up to whole blocks, so it is at or above the logical size.
        XCTAssertGreaterThanOrEqual(usage.originals, first.fileSize + second.fileSize)
        XCTAssertGreaterThan(usage.database, 0, "the SwiftData store should be counted")
        XCTAssertEqual(usage.total, usage.originals + usage.derived)
        XCTAssertGreaterThan(usage.derived, 0, "the store and its sidecars are derived bytes")

        // The total must agree with an independent walk of the same tree.
        var walked: Int64 = 0
        let walker = try XCTUnwrap(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]))
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey])
            if values.isRegularFile == true { walked += Int64(values.totalFileAllocatedSize ?? 0) }
        }
        XCTAssertEqual(usage.total, walked)

        // Measuring is a report, never a mutation: both originals survive it unchanged.
        for document in [first, second] {
            let original = try storage.originalURL(for: document.relativePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
            XCTAssertEqual(try Data(contentsOf: original).count, Int(document.fileSize))
        }
    }

    func testUsageReportsOtherArchivesAndVerificationDataSeparately() async throws {
        _ = try await importer.importFile(pdf("Usage Nested.pdf")).document
        let before = try await storage.usage()
        // Each nested folder is a whole separate archive with its own Library.store.
        for (folder, size) in [("CloudArchives/account/\(UUID())", 70_000), ("CloudValidation/\(UUID())", 90_000)] {
            let directory = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 1, count: size).write(to: directory.appendingPathComponent("Library.store"))
        }
        let after = try await storage.usage()
        XCTAssertGreaterThanOrEqual(after.otherArchives, 70_000)
        XCTAssertGreaterThanOrEqual(after.verificationData, 90_000)
        XCTAssertEqual(after.other, before.other, "neither folder may land in other")
        XCTAssertEqual(after.database, before.database, "a nested archive's store is not this archive's database")
        XCTAssertEqual(after.derived, before.derived)
        XCTAssertEqual(after.total, after.originals + after.derived + after.otherArchives + after.verificationData + after.other)
    }

    func testUsageCountsTrashedOriginalsThatStillOccupyDisk() async throws {
        var document = try await importer.importFile(pdf("Usage Trash.pdf")).document
        let before = try await storage.usage()
        document.trashedAt = Date()
        try repository.update(document)
        let after = try await storage.usage()
        XCTAssertEqual(after.originalFiles, before.originalFiles)
        XCTAssertEqual(after.originals, before.originals, "trashing frees nothing today")
    }

    private func pdf(_ name: String, width: CGFloat = 612) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: width, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: page == 0 ? 0.2 : 0.7, alpha: 1))
            context.fill(CGRect(x: 54, y: 600, width: width - 108, height: 40))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
    private func image(_ type: UTType) throws -> URL {
        let url = directory.appendingPathComponent("Image.\(type.preferredFilenameExtension!)")
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
