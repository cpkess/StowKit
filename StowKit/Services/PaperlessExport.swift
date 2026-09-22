import Foundation

/// A paperless-ngx `document_exporter` folder, read into what StowKit keeps. Handles the single
/// `manifest.json` and the `--split-manifest` layout (`manifest.json` for shared objects plus a
/// `*-manifest.json` per document). Only the documented fields are read; anything else is ignored.
struct PaperlessDocument: Equatable, Sendable {
    var pk: Int
    var file: String
    var title: String
    var created: Date?
    var sender: String
    var type: String
    var tags: [String]
    var inbox: Bool
    var content: String
    var notes: [String]
    var amount: String
    var dueDate: Date?
    var expiresAt: Date?
}

enum PaperlessExport {
    enum Failure: LocalizedError {
        case noManifest, unreadable(String)
        var errorDescription: String? {
            switch self {
            case .noManifest: "This folder has no manifest.json. Choose the folder paperless-ngx’s document exporter wrote."
            case .unreadable(let name): "\(name) couldn’t be read as a paperless-ngx manifest."
            }
        }
    }

    static func read(_ folder: URL) throws -> [PaperlessDocument] {
        let files = FileManager.default
        let main = folder.appendingPathComponent("manifest.json")
        guard files.fileExists(atPath: main.path) else { throw Failure.noManifest }
        var manifests = [main]
        if let items = files.enumerator(at: folder, includingPropertiesForKeys: nil) {
            for case let url as URL in items where url.lastPathComponent.hasSuffix("-manifest.json") { manifests.append(url) }
        }
        var objects: [[String: Any]] = []
        for url in manifests {
            guard let array = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] else {
                throw Failure.unreadable(url.lastPathComponent)
            }
            objects += array
        }
        return parse(objects)
    }

    static func parse(_ objects: [[String: Any]]) -> [PaperlessDocument] {
        func names(_ model: String) -> [Int: [String: Any]] {
            Dictionary(objects.filter { $0["model"] as? String == model }.compactMap { object in
                guard let pk = object["pk"] as? Int, let fields = object["fields"] as? [String: Any] else { return nil }
                return (pk, fields)
            }, uniquingKeysWith: { first, _ in first })
        }
        let senders = names("documents.correspondent"), types = names("documents.documenttype"), tags = names("documents.tag")
        let customFields = names("documents.customfield")
        var notes: [Int: [String]] = [:]
        for fields in names("documents.note").values {
            if let document = fields["document"] as? Int, let text = fields["note"] as? String, !text.isEmpty { notes[document, default: []].append(text) }
        }
        var custom: [Int: [(name: String, value: Any)]] = [:]
        for fields in names("documents.customfieldinstance").values {
            guard let document = fields["document"] as? Int, let field = fields["field"] as? Int,
                  let name = customFields[field]?["name"] as? String else { continue }
            let value = ["value_monetary", "value_date", "value_text", "value_float", "value_int"].lazy.compactMap { fields[$0] }.first { !($0 is NSNull) }
            if let value { custom[document, default: []].append((name, value)) }
        }
        return objects.compactMap { object -> PaperlessDocument? in
            guard object["model"] as? String == "documents.document", let pk = object["pk"] as? Int,
                  let fields = object["fields"] as? [String: Any], let file = object["__exported_file_name__"] as? String else { return nil }
            let tagFields = (fields["tags"] as? [Int] ?? []).compactMap { tags[$0] }
            var document = PaperlessDocument(pk: pk, file: file, title: fields["title"] as? String ?? "",
                created: (fields["created"] as? String).flatMap(date), sender: senders[fields["correspondent"] as? Int ?? -1]?["name"] as? String ?? "",
                type: types[fields["document_type"] as? Int ?? -1]?["name"] as? String ?? "",
                tags: tagFields.compactMap { $0["name"] as? String }, inbox: tagFields.contains { $0["is_inbox_tag"] as? Bool == true },
                content: fields["content"] as? String ?? "", notes: notes[pk] ?? [], amount: "", dueDate: nil, expiresAt: nil)
            for (name, value) in custom[pk] ?? [] {
                let key = name.lowercased()
                if document.amount.isEmpty, ["amount", "total", "price", "cost"].contains(where: key.contains) { document.amount = "\(value)" }
                if document.dueDate == nil, key.contains("due"), let day = (value as? String).flatMap(date) { document.dueDate = day }
                if document.expiresAt == nil, ["expir", "renew"].contains(where: key.contains), let day = (value as? String).flatMap(date) { document.expiresAt = day }
            }
            // Paperless monetary values look like "USD1234.56"; keep the figure readable.
            if let range = document.amount.range(of: #"^[A-Z]{3}(?=[0-9])"#, options: .regularExpression) {
                document.amount = document.amount[range] + " " + document.amount[range.upperBound...]
            }
            return document
        }.sorted { $0.pk < $1.pk }
    }

    /// Paperless writes "2024-01-15" (2.x) or a full ISO date-time (older versions).
    static func date(_ value: String) -> Date? {
        if let day = DocumentFacts.date(String(value.prefix(10))) { return day }
        return ISO8601DateFormatter().date(from: value)
    }
}
