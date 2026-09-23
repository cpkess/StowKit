import Foundation

/// Whether text read from a page is worth keeping. Optical recognition on a decorative or
/// low-contrast scan returns confident nonsense rather than nothing ("Ctrtifuation Qf lirtb"), and
/// that is indistinguishable from real text by length alone. The test is shape, not spelling: a
/// word a human could read has vowels and no long consonant runs, and carries no stray symbols.
enum TextQuality {
    /// Words that look like language, as a share of all words. 1 for clean text, near 0 for noise.
    static func readableShare(_ text: String) -> Double {
        let words = Self.words(in: text)
        guard !words.isEmpty else { return 0 }
        return Double(words.filter(isWordLike).count) / Double(words.count)
    }
    /// A full page that recognition turned into a handful of words was mostly missed, even when
    /// those words read cleanly: a birth certificate that yields only its heading is not "read".
    /// Ten words is the line between a page that was read and one that was barely touched: the
    /// birth certificate that produced "CERTIFICATE OF LIVE BIRTH 858046" and nothing else sits
    /// well below it, while a short receipt or a tax stub sits above.
    static let scannedPageMinimumWords = 10
    /// True when a page's text is too poor to keep, so another reader should try.
    static func looksUnusable(_ text: String, minimumWords: Int = 4, threshold: Double = 0.6) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return true }
        guard Self.words(in: trimmed).count >= minimumWords else { return true }
        return readableShare(trimmed) < threshold
    }

    static func words(in text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter { $0.count >= 2 }
    }

    private static let strays = Set("@*^~|\\{}<>¥£¢§¤©®\u{FFFD}")
    private static let edges = CharacterSet(charactersIn: ".,;:!?()[]{}\"'“”‘’«»-–—/\\|•·")
    private static func isWordLike(_ word: String) -> Bool {
        if word.contains(where: strays.contains) { return false }
        let core = word.trimmingCharacters(in: edges)
        guard core.count >= 2 else { return false }
        // Figures, dates, phone numbers and amounts are readable without being words.
        if core.contains(where: \.isNumber) {
            return core.allSatisfy { $0.isNumber || $0.isLetter || "-/.,:$%€#".contains($0) }
        }
        guard core.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" || $0 == "." }) else { return false }
        let letters = core.filter(\.isLetter)
        guard letters.contains(where: isVowel) else { return false }
        var run = 0
        for character in letters {
            run = isVowel(character) ? 0 : run + 1
            if run > 3 { return false }
        }
        return true
    }
    private static func isVowel(_ character: Character) -> Bool {
        guard let scalar = character.lowercased().unicodeScalars.first else { return false }
        // Accented vowels read as vowels; anything outside Latin is left to the consonant-run rule.
        return "aeiouyàáâãäåèéêëìíîïòóôõöùúûüýÿœæ".unicodeScalars.contains(scalar)
    }
}
