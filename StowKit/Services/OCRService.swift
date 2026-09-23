import Foundation
import PDFKit
import Vision
import ImageIO
import CoreGraphics

protocol DocumentTextExtractor: Sendable {
    func pageCount(for input: ExtractionInput) async throws -> Int
    func extractPage(for input: ExtractionInput, index: Int) async throws -> ExtractedPage
}

/// PDF parsing, rasterization, and Vision requests are confined to this background actor.
actor OCRService: DocumentTextExtractor {
    private let modelReader: any ImageTextReading
    init(modelReader: any ImageTextReading = AppleImageTextReader()) { self.modelReader = modelReader }
    private var cachedID: UUID?
    private var pdf: PDFDocument?
    private var cgPDF: CGPDFDocument?

    func pageCount(for input: ExtractionInput) throws -> Int {
        try Task.checkCancellation()
        // Drop the previous document even on retries; an unavailable original may have been restored.
        cachedID = nil; pdf = nil; cgPDF = nil
        guard FileManager.default.fileExists(atPath: input.url.path) else { throw ProcessingError.missingOriginal }
        if input.isImage {
            guard let source = CGImageSourceCreateWithURL(input.url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
                throw ArchiveError.invalidDocument
            }
            return 1
        }
        guard let loaded = PDFDocument(url: input.url) else { throw ArchiveError.invalidDocument }
        guard !loaded.isLocked else { throw ProcessingError.lockedPDF }
        guard loaded.pageCount > 0 else { throw ArchiveError.invalidDocument }
        pdf = loaded
        cgPDF = CGPDFDocument(input.url as CFURL)
        cachedID = input.documentID
        return loaded.pageCount
    }

    func extractPage(for input: ExtractionInput, index: Int) async throws -> ExtractedPage {
        try await extract(input, index: index)
    }
    private func extract(_ input: ExtractionInput, index: Int) async throws -> ExtractedPage {
        try Task.checkCancellation()
        if input.isImage {
            guard index == 0 else { throw ProcessingError.unreadablePage }
            guard let source = CGImageSourceCreateWithURL(input.url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 3200,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw ProcessingError.unreadablePage }
            return try await recognize(image)
        }
        if cachedID != input.documentID { _ = try pageCount(for: input) }
        guard let page = pdf?.page(at: index) else { throw ProcessingError.unreadablePage }
        let embedded = TextNormalization.normalize(page.string ?? "")
        if Self.hasUsableEmbeddedText(embedded) { return ExtractedPage(text: embedded, method: .embedded) }
        guard let cgPage = cgPDF?.page(at: index + 1) else { throw ProcessingError.unreadablePage }
        let image = try autoreleasepool { try Self.render(cgPage) }
        let recognized = try await recognize(image)
        // Sparse digital text is still useful when a blank/low-contrast raster yields no OCR.
        if recognized.text.isEmpty && !embedded.isEmpty { return ExtractedPage(text: embedded, method: .embedded) }
        return recognized
    }
    static func hasUsableEmbeddedText(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        let readable = scalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        let broken = scalars.filter { $0 == "\u{FFFD}" || CharacterSet.controlCharacters.contains($0) }.count
        // Short headers alone are not evidence that a scanned page has a complete text layer.
        return readable >= 60 && Double(broken) / Double(max(scalars.count, 1)) < 0.02
    }
    /// Accurate recognition, then fast, then Apple Intelligence. macOS text recognition can fail
    /// for the rest of a process's life (an `e5rt` compute error seen on macOS 27: the first
    /// accurate request in a process succeeds and every later one throws at once), while fast
    /// recognition keeps working — so a page is never lost to that. A page fast recognition can
    /// only turn into noise is offered to the model, which reads the image instead.
    private func recognize(_ image: CGImage) async throws -> ExtractedPage {
        try Task.checkCancellation()
        var text = ""
        do { text = try Self.recognizeText(image, level: .accurate) }
        catch {
            try Task.checkCancellation()
            text = (try? Self.recognizeText(image, level: .fast)) ?? ""
            if text.isEmpty && !modelReader.isAvailable { throw error }
        }
        try Task.checkCancellation()
        let recognized = TextNormalization.normalize(text)
        guard TextQuality.looksUnusable(recognized, minimumWords: TextQuality.scannedPageMinimumWords),
              modelReader.isAvailable else {
            return ExtractedPage(text: recognized, method: .ocr)
        }
        guard let read = try? await modelReader.read(image) else { return ExtractedPage(text: recognized, method: .ocr) }
        let transcribed = TextNormalization.normalize(read)
        // Keep whatever reads better; the model is a fallback, not an authority.
        guard !transcribed.isEmpty, Self.reads(transcribed, betterThan: recognized) else {
            return ExtractedPage(text: recognized, method: .ocr)
        }
        return ExtractedPage(text: transcribed, method: .ocr, readByModel: true)
    }
    /// More of the page, in words a human could read. Text is never traded for less text: a model
    /// that answers a receipt with one clean word has read less of the page, not more — that
    /// happened on the owner's archive ("Dillenburg" for a page recognition read as eight words).
    static func reads(_ candidate: String, betterThan current: String) -> Bool {
        let candidateWords = TextQuality.words(in: candidate).count, currentWords = TextQuality.words(in: current).count
        guard currentWords > 0 else { return candidateWords > 0 }
        guard candidateWords >= currentWords else { return false }
        let candidateShare = TextQuality.readableShare(candidate), currentShare = TextQuality.readableShare(current)
        return candidateShare > currentShare + 0.1 || candidateWords >= currentWords * 2
    }
    private static func recognizeText(_ image: CGImage, level: VNRequestTextRecognitionLevel) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
    }
    #if DEBUG
    /// The recognition chain on one image, for tests.
    func readForTesting(_ image: CGImage) async throws -> ExtractedPage { try await recognize(image) }
    /// The exact image the recognizer is given, for `OCRDiagnostic`.
    static func renderForDiagnostic(_ page: CGPDFPage) throws -> CGImage { try render(page) }
    #endif
    private static func render(_ page: CGPDFPage) throws -> CGImage {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0, box.width.isFinite, box.height.isFinite else { throw ProcessingError.unreadablePage }
        let rotated = abs(page.rotationAngle) % 180 == 90
        let width = rotated ? box.height : box.width
        let height = rotated ? box.width : box.height
        // Bound memory per page while retaining enough pixels for household paperwork.
        let scale = min(3, 3200 / max(width, height))
        let size = CGSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ProcessingError.unreadablePage
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ProcessingError.unreadablePage }
        return image
    }
}
