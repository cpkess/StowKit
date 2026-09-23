#if DEBUG
import Foundation
import PDFKit
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Debug-only probe for originals macOS text recognition refuses. It reports what each page looks
/// like and which recognition variants succeed, so a fallback is chosen from evidence rather than
/// guesswork. Runs only when STOWKIT_OCR_DIAGNOSTIC is set; never part of a release build.
enum OCRDiagnostic {
    static var isRequested: Bool { ProcessingInfo.value != nil }
    private enum ProcessingInfo { static var value: String? { ProcessInfo.processInfo.environment["STOWKIT_OCR_DIAGNOSTIC"] } }

    static func run(root: URL) {
        let originals = root.appendingPathComponent("Originals")
        var files: [URL] = []
        if let walker = FileManager.default.enumerator(at: originals, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where !url.hasDirectoryPath { files.append(url) }
        }
        NSLog("OCRDIAG: %d originals under %@", files.count, originals.path)
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            report(url)
        }
        NSLog("OCRDIAG: done")
    }

    private static func report(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let ext = url.pathExtension.lowercased()
        guard ext == "pdf" else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                NSLog("OCRDIAG %@: image unreadable (%lld bytes)", url.lastPathComponent, size ?? 0)
                return
            }
            NSLog("OCRDIAG %@: image %dx%d %@", url.lastPathComponent, image.width, image.height, describe(image))
            attempts(image, name: url.lastPathComponent)
            return
        }
        guard let pdf = PDFDocument(url: url), let cgPDF = CGPDFDocument(url as CFURL), let page = cgPDF.page(at: 1) else {
            NSLog("OCRDIAG %@: PDF unreadable", url.lastPathComponent)
            return
        }
        let crop = page.getBoxRect(.cropBox), media = page.getBoxRect(.mediaBox)
        let embedded = pdf.page(at: 0)?.string ?? ""
        NSLog("OCRDIAG %@: pdf pages=%d bytes=%lld crop=%.1fx%.1f media=%.1fx%.1f rotation=%d embeddedChars=%d",
              url.lastPathComponent, pdf.pageCount, size ?? 0, crop.width, crop.height, media.width, media.height,
              page.rotationAngle, embedded.count)
        // Images the page draws, which is what recognition ultimately sees.
        if let dictionary = page.dictionary { describeResources(dictionary, name: url.lastPathComponent) }
        guard let rendered = try? OCRService.renderForDiagnostic(page) else {
            NSLog("OCRDIAG %@: render failed", url.lastPathComponent)
            return
        }
        NSLog("OCRDIAG %@: render %dx%d %@", url.lastPathComponent, rendered.width, rendered.height, describe(rendered))
        attempts(rendered, name: url.lastPathComponent)
    }

    private static func describeResources(_ dictionary: CGPDFDictionaryRef, name: String) {
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else {
            NSLog("OCRDIAG %@: page has no image XObjects", name)
            return
        }
        CGPDFDictionaryApplyBlock(xobjects, { key, value, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let streamDictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var width = 0 as CGPDFInteger, height = 0 as CGPDFInteger, bits = 0 as CGPDFInteger
            CGPDFDictionaryGetInteger(streamDictionary, "Width", &width)
            CGPDFDictionaryGetInteger(streamDictionary, "Height", &height)
            CGPDFDictionaryGetInteger(streamDictionary, "BitsPerComponent", &bits)
            var filter: UnsafePointer<Int8>?
            CGPDFDictionaryGetName(streamDictionary, "Filter", &filter)
            var colorSpace: UnsafePointer<Int8>?
            CGPDFDictionaryGetName(streamDictionary, "ColorSpace", &colorSpace)
            NSLog("OCRDIAG %@: xobject %s %ldx%ld bits=%ld filter=%s colorspace=%s", name, key,
                  width, height, bits, filter ?? "?", colorSpace ?? "?")
            return true
        }, nil)
    }

    private static func describe(_ image: CGImage) -> String {
        "bits=\(image.bitsPerComponent)/\(image.bitsPerPixel) alpha=\(image.alphaInfo.rawValue) space=\(image.colorSpace?.name.map(String.init(describing:)) ?? "none")"
    }

    /// The shipping chain — accurate, then fast, then Apple Intelligence — on a real page, so the
    /// log shows which tier each of the owner's documents needed.
    private static func attempts(_ image: CGImage, name: String) {
        let semaphore = DispatchSemaphore(value: 0)
        let start = Date()
        Task {
            do {
                let page = try await OCRService().readForTesting(image)
                NSLog("OCRDIAG %@: chain %@ %.1fs words=%d head=%@", name, page.readByModel ? "MODEL" : "recognition",
                      Date().timeIntervalSince(start), TextQuality.words(in: page.text).count,
                      String(page.text.prefix(70)).replacingOccurrences(of: "\n", with: " "))
                // For a thin result the model's own answer explains why it was or wasn't taken.
                if !page.readByModel, TextQuality.words(in: page.text).count < 12 {
                    let reader = AppleImageTextReader()
                    let answer = (try? await reader.read(image)) ?? ""
                    NSLog("OCRDIAG %@: model would say words=%d head=%@", name, TextQuality.words(in: answer).count,
                          String(answer.prefix(70)).replacingOccurrences(of: "\n", with: " "))
                }
            } catch {
                NSLog("OCRDIAG %@: chain FAILED %.1fs %@", name, Date().timeIntervalSince(start), String(describing: error))
            }
            semaphore.signal()
        }
        semaphore.wait()
    }
    private static func recognizeText(_ image: CGImage, level: VNRequestTextRecognitionLevel) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
    }
    /// Vision's document reader, a different pipeline from plain text recognition (macOS 26+).
    @available(macOS 26.0, *)
    private static func recognizeDocument(_ image: CGImage) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var output = Result<String, Error>.success("")
        Task {
            do {
                let request = RecognizeDocumentsRequest()
                let observations = try await request.perform(on: image)
                output = .success(observations.map { $0.document.text.transcript }.joined(separator: "\n"))
            } catch { output = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try output.get()
    }

    private static func scaled(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return nil }
        let scale = Double(maxPixel) / Double(longest)
        let width = Int((Double(image.width) * scale).rounded()), height = Int((Double(image.height) * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
    private static func redrawnWithoutAlpha(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
    private static func jpegRoundTrip(_ image: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
#endif
