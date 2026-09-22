import XCTest
import CoreGraphics
@testable import StowKit

@MainActor final class BulkEditTests: XCTestCase {
    private var root: URL!
    private var sources: URL!
    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitBulk-\(UUID())")
        root = base.appendingPathComponent("Archive"); sources = base.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    private func pdf(_ name: String, shade: CGFloat) throws -> URL {
        let url = sources.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)), mediaBox: &box, nil))
        context.beginPDFPage(nil); context.setFillColor(CGColor(gray: shade, alpha: 1)); context.fill(CGRect(x: 40, y: 40, width: 200, height: 60))
        context.endPDFPage(); context.closePDF()
        return url
    }
    private func store(with count: Int) async throws -> LibraryStore {
        let store = LibraryStore(root: root, processingEnabled: false)
        await store.start()
        store.enqueueImports(try (0..<count).map { try pdf("Doc \($0).pdf", shade: 0.1 + CGFloat($0) * 0.2) })
        let deadline = Date().addingTimeInterval(20)
        while store.isImporting && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        store.destination = .recent
        await store.waitForSearch()
        XCTAssertEqual(store.documents.count, count)
        return store
    }

    func testAMultiSelectionIsNotCollapsedWhenTheListRefreshes() async throws {
        let store = try await store(with: 3)
        store.selectedIDs = Set(store.documents.prefix(2).map(\.id))
        XCTAssertNil(store.selection, "no single document while several are selected")
        store.reconcileSelection()
        store.refreshTextSearch(resetLimit: false)
        await store.waitForSearch()
        XCTAssertEqual(store.selectedIDs.count, 2)
        store.selection = store.documents[2].id
        XCTAssertEqual(store.selectedIDs, [store.documents[2].id], "choosing one document selects only it")
    }
    func testOneChangeAppliesToEverySelectedDocumentAsTheOwnersEdit() async throws {
        let store = try await store(with: 3)
        let chosen = Set(store.documents.prefix(2).map(\.id))
        XCTAssertEqual(store.bulkEdit(chosen) { document in
            document.collections.insert("Taxes"); BulkEditView.add("2025", to: &document); document.needsReview = false; document.correspondent = "County"
        }, 2)
        let repository = try ArchiveRepository(root: root)
        for id in chosen {
            let document = try XCTUnwrap(repository.document(id))
            XCTAssertEqual(document.collections, ["Taxes"])
            XCTAssertEqual(document.tags, "2025")
            XCTAssertFalse(document.needsReview)
            let protected = Set(try XCTUnwrap(repository.analysis(id)).protectedFields)
            XCTAssertTrue(protected.isSuperset(of: ["collections", "tags", "review", "correspondent"]), "protected like a single edit")
        }
        let untouched = try XCTUnwrap(store.documents.first { !chosen.contains($0.id) })
        XCTAssertTrue(try XCTUnwrap(repository.document(untouched.id)).collections.isEmpty)
        XCTAssertEqual(store.bulkEdit(chosen) { $0.correspondent = "County" }, 0, "an unchanged document isn't rewritten")
        XCTAssertEqual(store.bulkEdit(chosen) { BulkEditView.remove("2025", from: &$0) }, 2)
        XCTAssertEqual(try repository.document(chosen.first!)?.tags, "")
    }
    func testTrashingASelectionAndDeletingDropsThemFromTheSelection() async throws {
        let store = try await store(with: 3)
        let chosen = Set(store.documents.prefix(2).map(\.id))
        store.selectedIDs = chosen
        store.bulkEdit(chosen) { $0.trashedAt = Date() }
        await store.waitForSearch()
        XCTAssertEqual(store.documents.count, 1)
        store.deletePermanently(Array(chosen))
        XCTAssertTrue(store.selectedIDs.isDisjoint(with: chosen))
    }
}
