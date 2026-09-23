import Foundation
import CoreGraphics
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Reads text from a page image when macOS text recognition gives nothing usable. Never required:
/// when no reader is available the page keeps whatever recognition managed, as before.
protocol ImageTextReading: Sendable {
    var isAvailable: Bool { get }
    func read(_ image: CGImage) async throws -> String
}

/// Apple Intelligence, on this Mac, from the page image. It is a language model, so it can invent
/// a plausible word: text it returns is marked as model-read and left for the owner to review, and
/// it is only ever asked when recognition has already failed.
struct AppleImageTextReader: ImageTextReading {
    /// A page needs enough detail to read but not so much that a transcription takes minutes.
    static let maximumPixels = 1600
    static let instructions = """
        You transcribe scanned household documents. Write out only the text that is visibly present, \
        in the order it appears. Never guess a name, number, or date you cannot see; leave it out \
        instead. Do not describe, summarise, or comment on the document. If you cannot read any \
        text at all, reply with exactly NOTHING.
        """

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }

    func read(_ image: CGImage) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            guard isAvailable else { return "" }
            let page = Self.scaled(image) ?? image
            // The first request in a process can fail while the model loads; a page that recognition
            // already gave up on is worth one more try (seen on the owner's archive: a licence the
            // model read on the second attempt and not the first).
            for attempt in 0..<2 {
                do {
                    let session = LanguageModelSession(instructions: Self.instructions)
                    let response = try await session.respond(to: Prompt {
                        "Transcribe every word of text in this scanned page."
                        Attachment(page)
                    })
                    return Self.cleaned(response.content)
                } catch {
                    guard attempt == 0 else { throw error }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        #endif
        return ""
    }

    /// "NOTHING" is the model saying it saw no text; anything shorter than a few words is noise.
    static func cleaned(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased() != "NOTHING", !trimmed.isEmpty else { return "" }
        return trimmed
    }
    static func scaled(_ image: CGImage) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maximumPixels else { return nil }
        let scale = Double(maximumPixels) / Double(longest)
        let width = Int((Double(image.width) * scale).rounded()), height = Int((Double(image.height) * scale).rounded())
        guard let context = CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Used where no model should run: tests, and any Mac without Apple Intelligence.
struct NoImageTextReader: ImageTextReading {
    var isAvailable: Bool { false }
    func read(_ image: CGImage) async throws -> String { "" }
}
