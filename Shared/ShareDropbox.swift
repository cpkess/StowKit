import Foundation

/// The hand-off between the Share extension and the app. The extension can't write into the
/// app's sandbox, so both use a folder in their shared App Group container: the extension drops a
/// file there and posts a notification; the app imports whatever it finds and removes it.
enum ShareDropbox {
    /// Team-prefixed, so macOS allows it without a provisioning profile. Must match both targets'
    /// `com.apple.security.application-groups` entitlement.
    static let group = "WZJ4ZPRH72.com.stowkit.app"
    static let notification = Notification.Name("com.stowkit.app.sharedDocument")
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Shared Inbox", isDirectory: true)
    }
    static func notifyApp() {
        DistributedNotificationCenter.default().postNotificationName(notification, object: nil, userInfo: nil, deliverImmediately: true)
    }
    /// Writes under a hidden name, then renames, so the app never imports a half-copied file
    /// (it skips hidden files). A clashing name gets " 2", " 3", and so on.
    /// `folder` is injectable because the real one is watched by the running app: a test writing
    /// there would import its fixture into the owner's archive.
    static func place(_ write: (URL) throws -> Void, named filename: String, in folder: URL? = ShareDropbox.folder) throws -> URL {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".partial-\(UUID().uuidString)")
        try write(partial)
        let name = URL(fileURLWithPath: filename)
        let base = name.deletingPathExtension().lastPathComponent, ext = name.pathExtension
        var destination = folder.appendingPathComponent(filename), copy = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base) \(copy)").appendingPathExtension(ext); copy += 1
        }
        do { try FileManager.default.moveItem(at: partial, to: destination) }
        catch { try? FileManager.default.removeItem(at: partial); throw error }
        return destination
    }

    static func filename(fromTitle title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String((cleaned.isEmpty ? "Web Page" : cleaned).prefix(100))
    }
}

import CoreGraphics

/// WebKit's PDF export is one very tall page, awkward to read and to OCR. It is cut into
/// letter-proportioned pages by drawing the vector page once per slice, so the text stays text.
enum PDFPaginator {
    static func paginate(_ pdf: Data) throws -> Data {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { throw CocoaError(.fileReadCorruptFile) }
        let full = page.getBoxRect(.mediaBox)
        let pageHeight = (full.width * 11 / 8.5).rounded()
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { throw CocoaError(.fileWriteUnknown) }
        var box = CGRect(x: 0, y: 0, width: full.width, height: pageHeight)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        var top = full.maxY
        while top > full.minY + 1 {
            context.beginPDFPage(nil)
            context.saveGState()
            context.clip(to: box)
            // PDF space runs bottom-up: shift so this slice's top edge meets the page's top edge.
            context.translateBy(x: -full.minX, y: pageHeight - top)
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
            top -= pageHeight
        }
        context.closePDF()
        return output as Data
    }
}
