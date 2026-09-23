import XCTest
import CoreGraphics
import AppKit
@testable import StowKit

/// What StowKit does when macOS text recognition gives nothing usable: keep reading with a second
/// recognizer, and only then offer the page image to Apple Intelligence.
final class TextFallbackTests: XCTestCase {

    // Real output from the owner's archive, September 22, 2026, when recognition fell back to its
    // fast level: two pages read well, two turned into confident nonsense.
    private let clean = [
        "Wood County Treasurer, OH J 419-354-9130 Thankyou foryour payment of $3,972.96 real estate taxes",
        "STOWKIT QA- FICTIONAL TEST ONLY Insurance policy Policy number 4471 covers the household",
        "Department of Taxation Tax.Ohio.gov school district income tax return for the year"
    ]
    private let noise = [
        "Ctrtifuation Qf lirtb t.rytt @t @bio tpartwnt. @f *ealtb - ¥",
        "arye £\u{FFFD}e\u{FFFD}e St&le ofofiw, Woodc'tr4nty &4\u{FFFD}hor¢zf Chrhto her P",
        "\u{FFFD}\u{FFFD}\u{FFFD} xwq zzt frtk @@@ *** ¥¥"
    ]

    func testNonsenseIsRejectedAndRealTextIsKept() {
        for text in clean {
            XCTAssertFalse(TextQuality.looksUnusable(text), "real text was treated as unusable: \(text)")
        }
        for text in noise {
            XCTAssertTrue(TextQuality.looksUnusable(text), "nonsense was treated as usable: \(text)")
        }
        XCTAssertTrue(TextQuality.looksUnusable(""), "a page with no text needs another reader")
        XCTAssertTrue(TextQuality.looksUnusable("Total $42"), "a couple of words is not a page of text")
        XCTAssertGreaterThan(TextQuality.readableShare(clean[0]), TextQuality.readableShare(noise[0]))
    }

    func testAccentsAndFiguresCount() {
        XCTAssertFalse(TextQuality.looksUnusable("Prämie für Hausratversicherung beträgt 240,00 EUR jährlich"),
                       "German with accents reads as text")
        XCTAssertFalse(TextQuality.looksUnusable("Invoice 2026-09-14 total $1,204.55 due 2026-10-01 account 55-2213"),
                       "dates, amounts and account numbers read as text")
    }

    /// The model is asked only when recognition failed, and only its better answer is kept.
    func testModelIsAskedOnlyForUnusablePagesAndOnlyWinsWhenBetter() async throws {
        let page = Self.image(of: "STOWKIT QA FICTIONAL ONLY Household utility bill for August 2026 total $84.20 due September 30 account 55-2213 for the home at 14 Example Lane")
        let reader = StubReader(output: "STOWKIT QA FICTIONAL ONLY Certificate of live birth State of Ohio")
        let service = OCRService(modelReader: reader)
        let recognized = try await service.readForTesting(page)
        XCTAssertFalse(recognized.readByModel, "readable text must not be sent to a model")
        let asked = await reader.calls
        XCTAssertEqual(asked, 0)

        let unreadable = Self.image(of: "\u{FFFD}\u{FFFD} xwq zzt @@@")
        let second = try await service.readForTesting(unreadable)
        let askedAgain = await reader.calls
        XCTAssertEqual(askedAgain, 1, "an unusable page is offered to the model")
        XCTAssertTrue(second.readByModel)
        XCTAssertTrue(second.text.contains("Certificate of live birth"))

        let poorModel = StubReader(output: "\u{FFFD}\u{FFFD}\u{FFFD} @@@ ***")
        let third = try await OCRService(modelReader: poorModel).readForTesting(unreadable)
        XCTAssertFalse(third.readByModel, "a model answer no better than the recognizer's is discarded")
    }

    /// The real miss on the owner's archive: a whole birth certificate read as two clean lines.
    func testASparseReadOfAScanCountsAsUnusable() {
        let heading = "CERTIFICATE OF LIVE BIRTH 858046"
        XCTAssertFalse(TextQuality.looksUnusable(heading), "as plain text those words read fine")
        XCTAssertTrue(TextQuality.looksUnusable(heading, minimumWords: TextQuality.scannedPageMinimumWords),
                      "but a full page that yielded four words was mostly missed")
        XCTAssertFalse(TextQuality.looksUnusable(clean[0], minimumWords: TextQuality.scannedPageMinimumWords),
                       "a page that really was read stays usable")
    }

    func testAModelReadOrBarelyReadDocumentIsNeverFiledAutomatically() {
        let full = clean.joined(separator: " ")
        XCTAssertTrue(UnderstandingPolicy.canFileAutomatically(text: full, readByModel: false, scanned: true))
        XCTAssertFalse(UnderstandingPolicy.canFileAutomatically(text: full, readByModel: true, scanned: true),
                       "a model transcription is never trusted enough to file on its own")
        XCTAssertFalse(UnderstandingPolicy.canFileAutomatically(text: "CERTIFICATE OF LIVE BIRTH 858046", readByModel: false, scanned: true),
                       "two lines off a scan cannot support automatic filing")
        XCTAssertTrue(UnderstandingPolicy.canFileAutomatically(text: "Insurance policy. Policy number ABC123.", readByModel: false, scanned: false),
                      "a short text layer in the PDF itself is the document, not a misread")

        // A confident understanding of untrustworthy text leaves the document in Inbox, unfiled.
        var understanding = DocumentUnderstanding()
        understanding.title = "Life Insurance"
        understanding.summary = "Document confirms life insurance coverage."
        understanding.collection = "Insurance"
        understanding.tags = ["insurance"]
        understanding.confidence = 0.95
        var document = HouseholdDocument(id: UUID(), archiveID: UUID(), title: "H. Kessler - Birth Certificate",
            originalFilename: "scan.pdf", documentDate: Date(), importedAt: Date(), modifiedAt: Date(),
            contentType: "com.adobe.pdf", contentHash: "hash", fileSize: 1, relativePath: "Originals/AA/\(UUID()).pdf")
        document.needsReview = true
        let held = UnderstandingPolicy.merge(understanding, into: document, protected: [], trustworthyText: false)
        XCTAssertTrue(held.collections.isEmpty, "it must not be filed into Insurance")
        XCTAssertEqual(held.title, "H. Kessler - Birth Certificate", "and must not be retitled")
        XCTAssertTrue(held.needsReview)
        let trusted = UnderstandingPolicy.merge(understanding, into: document, protected: [], trustworthyText: true)
        XCTAssertEqual(trusted.collections, ["Insurance"], "trustworthy text still files as before")
    }

    func testNothingMeansTheModelSawNoText() {
        XCTAssertEqual(AppleImageTextReader.cleaned("NOTHING"), "")
        XCTAssertEqual(AppleImageTextReader.cleaned("  nothing \n"), "")
        XCTAssertEqual(AppleImageTextReader.cleaned(" Certificate of Live Birth "), "Certificate of Live Birth")
    }

    /// A page method this version has never heard of must not stall text sync.
    func testUnknownExtractionMethodDecodesRatherThanFailing() throws {
        let page = try JSONDecoder().decode(CloudTextPage.self,
            from: Data(#"{"index":0,"text":"hello","method":"handwriting"}"#.utf8))
        XCTAssertEqual(page.method, .ocr)
        XCTAssertEqual(try JSONDecoder().decode(ExtractionMethod.self, from: Data("\"embedded\"".utf8)), .embedded)
    }

    private actor StubReader: ImageTextReading {
        let output: String
        private(set) var calls = 0
        init(output: String) { self.output = output }
        nonisolated var isAvailable: Bool { true }
        func read(_ image: CGImage) async throws -> String { calls += 1; return output }
    }

    private static func image(of text: String) -> CGImage {
        let size = CGSize(width: 1400, height: 300)
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.black])
            .draw(at: CGPoint(x: 30, y: 130))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }
}
