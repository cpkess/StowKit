// Compile with the three app sources listed in docs/VALIDATION.md. Uses synthetic data only.
import Foundation

@main struct SearchBenchmark {
    static func print(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitBenchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let count = Int(CommandLine.arguments.dropFirst().first ?? "50000") ?? 50_000
        let archiveID = UUID()
        let url = root.appendingPathComponent("Search.sqlite")
        var index: FullTextIndex? = try FullTextIndex(url: url, archiveID: archiveID)
        let start = Date()
        for batch in stride(from: 0, to: count, by: 100) {
            try index!.transaction {
                for number in batch..<min(batch + 100, count) {
                    let id = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000 + Double(number))
                    let type = ["Insurance policy", "Property tax bill", "Refrigerator warranty", "School receipt"][number % 4]
                    let document = HouseholdDocument(id: id, archiveID: archiveID, title: "\(type) \(number)", originalFilename: "record-\(number).pdf",
                        correspondent: "Household Company", documentDate: date, importedAt: date, modifiedAt: date,
                        collections: [number % 2 == 0 ? "Home" : "Financial"], tags: "household 2026", entities: "Fictional household",
                        contentType: "com.adobe.pdf", contentHash: id.uuidString, fileSize: 100_000, relativePath: "synthetic")
                    let body = String(repeating: "This fictional household document describes coverage, renewal dates, payment terms, parts, labor, and deductible information. ", count: 40) + " unique\(number)"
                    try index!.replace(document, body: body, failed: false)
                }
            }
        }
        try index!.finishBuild()
        print("Synthetic documents: \(count); approximately 4.8 KB extracted text each")
        print(String(format: "Index build: %.3f s", Date().timeIntervalSince(start)))
        index = nil
        let reopen = Date()
        index = try FullTextIndex(url: url, archiveID: archiveID)
        print(String(format: "Index reopen: %.3f ms", Date().timeIntervalSince(reopen) * 1000))
        let queries = ["warranty", "refrig", "coverage deductible", "\"renewal dates\"", "unique\(count - 1)", "nomatchword"]
        var durations: [Double] = []
        for _ in 0..<5 {
            for query in queries {
                let before = Date()
                let result = try index!.search(query, destination: .recent, newestFirst: true, offset: 0, limit: 50)
                durations.append(Date().timeIntervalSince(before) * 1000)
                if query == "unique\(count - 1)" { precondition(result.total == 1) }
                precondition(result.rows.count <= 50)
            }
        }
        durations.sort()
        print(String(format: "30 queries, including exact counts and snippets: median %.3f ms; p95 %.3f ms; max %.3f ms", durations[durations.count / 2], durations[Int(Double(durations.count - 1) * 0.95)], durations.last!))
        let browse = Date()
        let page = try index!.search("", destination: .recent, newestFirst: true, offset: 0, limit: 50)
        precondition(page.rows.count == min(50, count))
        print(String(format: "First 50 metadata IDs: %.3f ms", Date().timeIntervalSince(browse) * 1000))
        let statsStart = Date()
        _ = try index!.statistics()
        print(String(format: "Archive count/size statistics: %.3f ms", Date().timeIntervalSince(statsStart) * 1000))
        try index!.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        print("Search cache: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
        index = nil
    }
}
