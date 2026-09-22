import XCTest
import CryptoKit
@testable import StowKit

@MainActor final class ExportTests: XCTestCase {
    private var root: URL!
    private var repository: ArchiveRepository!
    private var storage: DocumentStorageManager!
    private var reader: TextSearchService!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitExport-\(UUID())")
        storage = DocumentStorageManager(root: root.appendingPathComponent("Archive"))
        try await storage.prepare()
        repository = try ArchiveRepository(root: root.appendingPathComponent("Archive"))
        let container = repository.container
        reader = await Task.detached { TextSearchService(modelContainer: container) }.value
    }
    override func tearDown() async throws { repository = nil; try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func add(_ title: String, collections: Set<String> = [], text: String? = nil, date: String = "2026-09-17",
                     bytes: String? = nil, trashed: Bool = false) throws -> HouseholdDocument {
        let data = Data((bytes ?? "Fictional export original \(title) \(UUID())").utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let id = UUID()
        let day = try XCTUnwrap(ISO8601DateFormatter().date(from: date + "T12:00:00Z"))
        var document = HouseholdDocument(id: id, archiveID: repository.archiveID, title: title, originalFilename: "scan.pdf",
            documentDate: day, importedAt: day, modifiedAt: day, contentType: "com.adobe.pdf", contentHash: hash,
            fileSize: Int64(data.count), relativePath: "Originals/\(id.uuidString.prefix(2))/\(id).pdf")
        document.collections = collections; document.correspondent = "Fictional Sender"; document.tags = "one, two"
        let url = try storage.originalURL(for: document.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try repository.insert(document)
        if let text {
            _ = try repository.setPageCount(id, count: 1)
            _ = try repository.savePage(id, index: 0, result: .init(text: text, method: .embedded))
        }
        if trashed { document.trashedAt = Date(); try repository.update(document) }
        return try XCTUnwrap(repository.document(id))
    }
    private func export() async throws -> ExportResult {
        let documents = try repository.documents().filter { $0.trashedAt == nil }
        return try await ArchiveExporter(storage: storage, reader: reader).export(documents, into: root, progress: { _, _ in })
    }

    func testExportIsPlainFilesVerifiedAgainstTheirOriginals() async throws {
        try add("Property tax receipt", collections: ["Taxes"], text: "Wood County Treasurer receipt")
        try add("Kitchen proposal", collections: ["Home", "Financial"])
        try add("Loose note")
        try add("Thrown away", trashed: true)
        let result = try await export()
        XCTAssertEqual(result.exported, 3)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(result.folder.lastPathComponent.hasSuffix(".partial"))
        let documents = result.folder.appendingPathComponent("Documents")
        for path in ["Taxes/2026-09-17 Property tax receipt.pdf", "Financial/2026-09-17 Kitchen proposal.pdf", "Unfiled/2026-09-17 Loose note.pdf"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: documents.appendingPathComponent(path).path), path)
        }
        let text = try String(contentsOf: result.folder.appendingPathComponent("Text/Taxes/2026-09-17 Property tax receipt.txt"), encoding: .utf8)
        XCTAssertEqual(text, "Wood County Treasurer receipt")
        let records = try JSONDecoder().decode([ExportRecord].self, from: Data(contentsOf: result.folder.appendingPathComponent("manifest.json")))
        XCTAssertEqual(records.count, 3)
        let kitchen = try XCTUnwrap(records.first { $0.title == "Kitchen proposal" })
        XCTAssertEqual(kitchen.collections, ["Financial", "Home"], "the manifest keeps every collection")
        XCTAssertEqual(kitchen.tags, ["one", "two"])
        for record in records {
            let data = try Data(contentsOf: result.folder.appendingPathComponent(record.file))
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), record.sha256, "byte-identical original")
        }
        XCTAssertFalse(records.contains { $0.title == "Thrown away" })
        let csv = try String(contentsOf: result.folder.appendingPathComponent("manifest.csv"), encoding: .utf8)
        XCTAssertTrue(csv.hasPrefix("Title,Date,Sender,Type,Amount,Due,Expires,Collections,Tags,Summary,File,SHA-256,Needs Review\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.folder.appendingPathComponent("README.txt").path))
    }
    func testACorruptedOriginalIsReportedAndLeftOut() async throws {
        let good = try add("Good")
        let bad = try add("Bad")
        // Same size, different bytes: the size check on opening an original passes, so only the
        // export's own fingerprint check can catch it.
        let url = try storage.originalURL(for: bad.relativePath)
        try Data(String(repeating: "x", count: Int(bad.fileSize)).utf8).write(to: url)
        let result = try await export()
        XCTAssertEqual(result.exported, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].hasPrefix("Bad:"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.folder.appendingPathComponent("Documents/Unfiled/2026-09-17 Bad.pdf").path),
                       "a copy that fails verification is removed")
        XCTAssertTrue(try String(contentsOf: result.folder.appendingPathComponent("README.txt"), encoding: .utf8).contains("Bad:"))
        _ = good
    }
    func testNamesAreSafeAndClashesAreNumbered() throws {
        var taken = Set<String>()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        func doc(_ title: String) -> HouseholdDocument {
            HouseholdDocument(id: UUID(), archiveID: UUID(), title: title, originalFilename: "a.PDF", documentDate: date, importedAt: date,
                modifiedAt: date, contentType: "com.adobe.pdf", contentHash: "", fileSize: 1, relativePath: "")
        }
        let first = ArchiveExporter.relativePath(for: doc("Bill: March/April"), taken: &taken)
        let second = ArchiveExporter.relativePath(for: doc("Bill: March/April"), taken: &taken)
        XCTAssertTrue(first.hasPrefix("Unfiled/") && first.hasSuffix(" Bill March April.pdf"), first)
        XCTAssertTrue(second.hasSuffix(" Bill March April (2).pdf"), second)
        XCTAssertEqual(ArchiveExporter.safe(" ../.. "), "Untitled")
    }
    func testCSVQuotesAwkwardValues() {
        let record = ExportRecord(id: UUID(), title: "Smith, \"J\"", file: "f", textFile: nil, originalFilename: "o", contentType: "c",
            sha256: "h", fileSize: 1, documentDate: "2026-01-01", importedAt: "", sender: "", collections: [], tags: [],
            summary: "Line one\nline two", peopleAndThings: "", favorite: false, needsReview: true)
        let csv = ArchiveExporter.csv([record])
        XCTAssertTrue(csv.contains("\"Smith, \"\"J\"\"\""))
        XCTAssertTrue(csv.contains("\"Line one\nline two\""))
    }
}
