import XCTest
import PDFKit
import CoreText
@testable import StowKit

/// Tests never write to `ShareDropbox.folder`: the running app watches it, and would import a
/// fixture into the owner's archive.
@MainActor final class ShareExtensionTests: XCTestCase {
    private var base: URL!
    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitShare-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    func testPlacingNeverShowsAPartialFileAndNumbersClashingNames() throws {
        var sawPartial = false
        let first = try ShareDropbox.place({ url in
            XCTAssertTrue(url.lastPathComponent.hasPrefix("."), "written under a hidden name, which the importer skips")
            sawPartial = true
            try Data("one".utf8).write(to: url)
        }, named: "Receipt.pdf", in: base)
        let second = try ShareDropbox.place({ try Data("two".utf8).write(to: $0) }, named: "Receipt.pdf", in: base)
        XCTAssertTrue(sawPartial)
        XCTAssertEqual(first.lastPathComponent, "Receipt.pdf")
        XCTAssertEqual(second.lastPathComponent, "Receipt 2.pdf")
        XCTAssertEqual(try InboxFolder.candidates(in: base).map(\.lastPathComponent), ["Receipt 2.pdf", "Receipt.pdf"])
    }
    func testFailedWriteLeavesNothingBehind() {
        XCTAssertThrowsError(try ShareDropbox.place({ _ in throw CocoaError(.fileWriteUnknown) }, named: "x.pdf", in: base))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), [])
    }
    func testWebPageTitlesBecomeSafeFilenames() {
        XCTAssertEqual(ShareDropbox.filename(fromTitle: "Invoice #42 / ACME: Paid?"), "Invoice #42 ACME Paid")
        XCTAssertEqual(ShareDropbox.filename(fromTitle: "  \n "), "Web Page")
        XCTAssertEqual(ShareDropbox.filename(fromTitle: String(repeating: "a", count: 300)).count, 100)
    }
    func testATallPageIsCutIntoLetterPagesAndKeepsItsText() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 2000)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data as CFMutableData)), mediaBox: &box, nil))
        context.beginPDFPage(nil)
        for (text, y) in [("TOPWORD", 1950.0), ("MIDDLEWORD", 1000.0), ("BOTTOMWORD", 40.0)] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 18, nil)]))
            context.textPosition = CGPoint(x: 72, y: y); CTLineDraw(line, context)
        }
        context.endPDFPage(); context.closePDF()
        let paged = try XCTUnwrap(PDFDocument(data: PDFPaginator.paginate(data as Data)))
        XCTAssertEqual(paged.pageCount, 3, "2000 points tall at 792 per page")
        XCTAssertEqual(paged.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))
        XCTAssertTrue(paged.page(at: 0)?.string?.contains("TOPWORD") == true, "the top of the page comes first")
        XCTAssertTrue(paged.page(at: 2)?.string?.contains("BOTTOMWORD") == true)
        XCTAssertTrue(paged.string?.contains("MIDDLEWORD") == true, "text stays searchable text")
    }
    func testTheDropFolderDeletesImportedFilesRatherThanTrashingThem() async throws {
        let root = base.appendingPathComponent("Archive"), drop = base.appendingPathComponent("Drop")
        let storage = DocumentStorageManager(root: root)
        try await storage.prepare()
        let repository = try ArchiveRepository(root: root)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data as CFMutableData)), mediaBox: &box, nil))
        context.beginPDFPage(nil); context.fill(CGRect(x: 10, y: 10, width: 50, height: 50)); context.endPDFPage(); context.closePDF()
        let folder = InboxFolder(importer: DocumentImporter(repository: repository, storage: storage), fixedFolder: drop, onImported: { _ in }, onChange: {})
        _ = try ShareDropbox.place({ try (data as Data).write(to: $0) }, named: "Shared Page.pdf", in: drop)
        await folder.scan()
        XCTAssertEqual(try repository.documentCount(), 1)
        XCTAssertEqual(try repository.documents().first?.originalFilename, "Shared Page.pdf")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: drop.path), [], "the staging copy is removed")
    }
}
