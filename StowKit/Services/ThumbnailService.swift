import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

actor ThumbnailService {
    let storage: DocumentStorageManager
    init(storage: DocumentStorageManager) { self.storage = storage }

    func thumbnail(for document: HouseholdDocument) async throws -> Data {
        let cache = storage.thumbnailURL(for: document.id)
        if let data = try? Data(contentsOf: cache) { return data }
        guard let original = try await storage.cachedOriginal(for: document) else { throw OriginalAccessError.missing }
        let data = try render(url: original, isImage: document.isImage, maxPixelSize: 160)
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cache, options: .atomic)
        return data
    }
    func imagePreview(for document: HouseholdDocument) async throws -> Data {
        try render(url: await storage.localOriginal(for: document), isImage: true, maxPixelSize: 2048)
    }
    /// Page count and lock state read with Core Graphics. The preview deliberately avoids
    /// `PDFView`: its built-in Live Text analysis once starved the dispatch pool and froze the
    /// app when macOS text recognition was degraded (see docs/VALIDATION.md, 2026-09-20).
    func pdfOutline(for document: HouseholdDocument) async throws -> (pages: Int, locked: Bool) {
        let url = try await storage.localOriginal(for: document)
        guard let pdf = CGPDFDocument(url as CFURL) else { throw ArchiveError.invalidDocument }
        if pdf.isEncrypted && !pdf.isUnlocked { return (0, true) }
        guard pdf.numberOfPages > 0 else { throw ArchiveError.invalidDocument }
        return (pdf.numberOfPages, false)
    }
    /// One rendered page, zero-based, for the preview pane.
    func pagePreview(for document: HouseholdDocument, index: Int) async throws -> Data {
        try render(url: await storage.localOriginal(for: document), isImage: false, maxPixelSize: 2048, page: index + 1)
    }
    private func render(url: URL, isImage: Bool, maxPixelSize: Int, page pageNumber: Int = 1) throws -> Data {
        let image: CGImage
        if isImage {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw ArchiveError.invalidDocument }
            image = thumbnail
        } else {
            guard let pdf = CGPDFDocument(url as CFURL), let page = pdf.page(at: pageNumber) else { throw ArchiveError.invalidDocument }
            let box = page.getBoxRect(.cropBox)
            guard box.width > 0, box.height > 0 else { throw ArchiveError.invalidDocument }
            let rotated = abs(page.rotationAngle) % 180 == 90
            let width = rotated ? box.height : box.width
            let height = rotated ? box.width : box.height
            let scale = CGFloat(maxPixelSize) / max(width, height)
            let size = CGSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
            guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ArchiveError.invalidDocument }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let rendered = context.makeImage() else { throw ArchiveError.invalidDocument }
            image = rendered
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ArchiveError.invalidDocument }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ArchiveError.invalidDocument }
        return data as Data
    }
}
