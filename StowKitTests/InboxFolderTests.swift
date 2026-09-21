import XCTest
import CoreGraphics
@testable import StowKit

@MainActor final class InboxFolderTests: XCTestCase {
    private var base: URL!
    private var inbox: URL { base.appendingPathComponent("Inbox") }
    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitInboxFolder-\(UUID())")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: InboxFolder.bookmarkKey)
    }
    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: InboxFolder.bookmarkKey)
        try? FileManager.default.removeItem(at: base)
    }
    @discardableResult
    private func pdf(_ name: String, shade: CGFloat = 0.3) throws -> URL {
        let url = inbox.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(url: url as CFURL)), mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: shade, alpha: 1)); context.fill(CGRect(x: 54, y: 600, width: 504, height: 40))
        context.endPDFPage(); context.closePDF()
        return url
    }
    private func folder() async throws -> (InboxFolder, ArchiveRepository, [ImportResult]) {
        let root = base.appendingPathComponent("Archive")
        let storage = DocumentStorageManager(root: root)
        try await storage.prepare()
        let repository = try ArchiveRepository(root: root)
        var results: [ImportResult] = []
        let folder = InboxFolder(importer: DocumentImporter(repository: repository, storage: storage),
                                 onImported: { results.append($0) }, onChange: {})
        return (folder, repository, results)
    }

    func testCandidatesAreSupportedTopLevelDocumentsOnly() throws {
        try pdf("b-scan.pdf"); try pdf("a-scan.PDF")
        try Data("x".utf8).write(to: inbox.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: inbox.appendingPathComponent(".partial.pdf"))
        try FileManager.default.createDirectory(at: inbox.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: inbox.appendingPathComponent("Sub/nested.pdf"))
        XCTAssertEqual(try InboxFolder.candidates(in: inbox).map(\.lastPathComponent), ["a-scan.PDF", "b-scan.pdf"])
    }
    func testScanImportsThenTrashesAndDuplicatesAreTrashedToo() async throws {
        let bytes = try Data(contentsOf: try pdf("first.pdf", shade: 0.2))
        let (folder, repository, _) = try await folder()
        try folder.use(inbox)
        folder.stop()
        await folder.scan()
        XCTAssertEqual(try repository.documentCount(), 1)
        XCTAssertTrue(try InboxFolder.candidates(in: inbox).isEmpty, "An imported file leaves the inbox")
        XCTAssertTrue(folder.status.contains("imported 1"), folder.status)

        try bytes.write(to: inbox.appendingPathComponent("again.pdf"))
        await folder.scan()
        XCTAssertEqual(try repository.documentCount(), 1, "Identical bytes are not imported twice")
        XCTAssertTrue(try InboxFolder.candidates(in: inbox).isEmpty, "A duplicate is already archived, so it leaves the inbox")
    }
    func testFileThatFailsIsLeftInPlaceAndNotRetriedUntilChanged() async throws {
        let empty = inbox.appendingPathComponent("empty.pdf")
        try Data().write(to: empty)
        let (folder, repository, _) = try await folder()
        try folder.use(inbox)
        folder.stop()
        await folder.scan()
        XCTAssertEqual(try repository.documentCount(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path), "A failed file stays for the owner")
        XCTAssertTrue(folder.status.contains("couldn’t be imported"), folder.status)
    }
    func testFolderIsRememberedAcrossLaunches() async throws {
        let (first, _, _) = try await folder()
        try first.use(inbox)
        first.stop()
        let (second, _, _) = try await folder()
        XCTAssertEqual(second.url?.standardizedFileURL.path, inbox.standardizedFileURL.path)
        second.stopUsing()
        let (third, _, _) = try await folder()
        XCTAssertNil(third.url)
    }
}
