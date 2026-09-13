import Foundation

enum ProcessingState: String, Codable, Sendable {
    case queued, extractingText, savingText, complete, failed, paused
    var isActive: Bool { self == .extractingText || self == .savingText }
    var label: String {
        switch self {
        case .queued: "Waiting to extract text"
        case .extractingText: "Extracting text"
        case .savingText: "Saving text"
        case .complete: "Text extraction complete"
        case .failed: "Text extraction failed"
        case .paused: "Paused in Trash"
        }
    }
}

enum ExtractionMethod: String, Codable, Sendable { case embedded, ocr }
struct ExtractedPage: Sendable, Equatable {
    let text: String
    let method: ExtractionMethod
}
struct ExtractionInput: Sendable {
    let documentID: UUID
    let url: URL
    let isImage: Bool
}
struct ProcessingSnapshot: Identifiable, Sendable, Equatable {
    let id: UUID
    let state: ProcessingState
    let completedPages: Int
    let pageCount: Int
    let characterCount: Int
    let ocrPages: Int
    let attempts: Int
    let error: String?
    let failedStage: String?
    let updatedAt: Date

    var progressLabel: String {
        if state == .complete && characterCount == 0 { return "No text found" }
        if state.isActive && pageCount > 0 { return "\(state.label) · \(min(completedPages + 1, pageCount)) of \(pageCount)" }
        return state.label
    }
}
struct ExtractedTextPage: Identifiable, Sendable {
    let index: Int
    let text: String
    let method: ExtractionMethod
    var id: Int { index }
}

enum TextNormalization {
    static func normalize(_ text: String) -> String {
        let lines = text.precomposedStringWithCanonicalMapping.components(separatedBy: .newlines).map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func searchKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
