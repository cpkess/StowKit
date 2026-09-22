import XCTest
import CoreGraphics
@testable import StowKit

@MainActor final class PaperlessTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitPaperless-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("export/originals"), withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    /// A fictional export in paperless-ngx's `document_exporter` format.
    private var shared: [[String: Any]] {
        [
            ["model": "documents.correspondent", "pk": 1, "fields": ["name": "Wood County Treasurer"]],
            ["model": "documents.documenttype", "pk": 2, "fields": ["name": "Taxes"]],
            ["model": "documents.tag", "pk": 3, "fields": ["name": "Property", "is_inbox_tag": false]],
            ["model": "documents.tag", "pk": 4, "fields": ["name": "Inbox", "is_inbox_tag": true]],
            ["model": "documents.customfield", "pk": 5, "fields": ["name": "Amount", "data_type": "monetary"]],
            ["model": "documents.customfield", "pk": 6, "fields": ["name": "Due date", "data_type": "date"]]
        ]
    }
    private func documentObjects(file: String = "originals/tax.pdf", inbox: Bool = false) -> [[String: Any]] {
        [
            ["model": "documents.document", "pk": 10, "__exported_file_name__": file,
             "fields": ["title": "Property tax 2025", "correspondent": 1, "document_type": 2, "tags": inbox ? [3, 4] : [3],
                        "created": "2025-06-01", "content": "Wood County Treasurer property tax statement"]],
            ["model": "documents.customfieldinstance", "pk": 20, "fields": ["document": 10, "field": 5, "value_monetary": "USD3972.96"]],
            ["model": "documents.customfieldinstance", "pk": 21, "fields": ["document": 10, "field": 6, "value_date": "2025-07-15"]],
            ["model": "documents.note", "pk": 30, "fields": ["document": 10, "note": "Paid online"]]
        ]
    }
    private func write(_ objects: [[String: Any]], _ name: String = "manifest.json") throws {
        try JSONSerialization.data(withJSONObject: objects).write(to: root.appendingPathComponent("export/\(name)"))
    }
    private func pdf(_ path: String) throws {
        let url = root.appendingPathComponent("export/\(path)")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)), mediaBox: &box, nil))
        context.beginPDFPage(nil); context.fill(CGRect(x: 20, y: 20, width: 80, height: 30)); context.endPDFPage(); context.closePDF()
    }

    func testTheManifestMapsOntoStowKitsFields() throws {
        let documents = PaperlessExport.parse(shared + documentObjects(inbox: true))
        let document = try XCTUnwrap(documents.first)
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(document.title, "Property tax 2025")
        XCTAssertEqual(document.sender, "Wood County Treasurer")
        XCTAssertEqual(document.type, "Taxes")
        XCTAssertEqual(document.tags, ["Property", "Inbox"])
        XCTAssertTrue(document.inbox)
        XCTAssertEqual(document.amount, "USD 3972.96")
        XCTAssertEqual(document.dueDate, DocumentFacts.date("2025-07-15"))
        XCTAssertEqual(document.created, DocumentFacts.date("2025-06-01"))
        XCTAssertEqual(document.notes, ["Paid online"])
        XCTAssertEqual(document.file, "originals/tax.pdf")
    }
    func testSplitManifestsAreReadTogetherAndAFolderWithoutOneIsRefused() throws {
        XCTAssertThrowsError(try PaperlessExport.read(root.appendingPathComponent("export")))
        try write(shared)
        try write(documentObjects(), "originals/tax.pdf-manifest.json")
        XCTAssertEqual(try PaperlessExport.read(root.appendingPathComponent("export")).map(\.title), ["Property tax 2025"])
    }
    func testBothDateStylesParse() {
        XCTAssertEqual(PaperlessExport.date("2024-01-15"), DocumentFacts.date("2024-01-15"))
        XCTAssertNotNil(PaperlessExport.date("2021-03-04T10:20:30Z"))
        XCTAssertNil(PaperlessExport.date("soon"))
    }
    func testAnImportedDocumentKeepsItsPaperlessDetailsAndText() async throws {
        try write(shared + documentObjects())
        try pdf("originals/tax.pdf")
        let archive = root.appendingPathComponent("Archive")
        let storage = DocumentStorageManager(root: archive)
        try await storage.prepare()
        let repository = try ArchiveRepository(root: archive)
        let importer = DocumentImporter(repository: repository, storage: storage)
        let source = try XCTUnwrap(PaperlessExport.read(root.appendingPathComponent("export")).first)
        let result = try await importer.importFile(root.appendingPathComponent("export/originals/tax.pdf"))
        try repository.applyPaperless(source, to: result.document.id)
        let document = try XCTUnwrap(repository.document(result.document.id))
        XCTAssertEqual(document.title, "Property tax 2025")
        XCTAssertEqual(document.correspondent, "Wood County Treasurer")
        XCTAssertEqual(document.documentType, "Taxes")
        XCTAssertEqual(document.collections, ["Taxes"], "a type matching a collection files it")
        XCTAssertEqual(document.tags, "Property")
        XCTAssertEqual(document.summary, "Paid online")
        XCTAssertEqual(document.amount, "USD 3972.96")
        XCTAssertFalse(document.needsReview, "curated in paperless, so already reviewed")
        XCTAssertEqual(try repository.processingJob(document.id)?.state, "complete", "paperless's text is kept, not read again")
        XCTAssertEqual(try repository.filingRuleInput(document).text.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Wood County Treasurer property tax statement")
        let protected = Set(try XCTUnwrap(repository.analysis(document.id)).protectedFields)
        XCTAssertTrue(protected.isSuperset(of: ["title", "correspondent", "tags", "collections", "documentType", "documentDate"]),
                      "the owner's paperless curation is protected from suggestions")
        let again = try await importer.importFile(root.appendingPathComponent("export/originals/tax.pdf"))
        XCTAssertTrue(again.isDuplicate, "importing the same export twice skips what's already there")
    }
}
