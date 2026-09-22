import Foundation
import SQLite3

/// Used exclusively by TextSearchService's background model actor. This is a disposable cache.
final class FullTextIndex {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    struct Failure: LocalizedError {
        let code: Int32
        let message: String
        var errorDescription: String? { "Search index: \(message)" }
    }
    init(url: URL, archiveID: UUID) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let code = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else { let error = failure(code); sqlite3_close(database); database = nil; throw error }
        do {
            sqlite3_busy_timeout(database, 5_000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE IF NOT EXISTS info (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            // ":2" added filter columns and tags, ":3" entities (1.5); a changed identity rebuilds from saved data.
            let identity = archiveID.uuidString + ":3"
            let oldIdentity = try rows("SELECT value FROM info WHERE key='identity'").first?.first
            if oldIdentity != identity {
                try execute("DROP TABLE IF EXISTS content")
                try execute("DROP TABLE IF EXISTS documents")
                try execute("DROP TABLE IF EXISTS collections")
                try execute("DROP TABLE IF EXISTS tags")
                try execute("DROP TABLE IF EXISTS entities")
                try execute("DELETE FROM info")
            }
            try execute("CREATE TABLE IF NOT EXISTS documents (id TEXT PRIMARY KEY, title TEXT NOT NULL, imported REAL NOT NULL, bytes INTEGER NOT NULL, trashed INTEGER NOT NULL, favorite INTEGER NOT NULL, inbox INTEGER NOT NULL, sender TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL DEFAULT '', dated REAL NOT NULL DEFAULT 0, due REAL, expires REAL)")
            try execute("CREATE INDEX IF NOT EXISTS document_date ON documents(trashed, imported DESC, id)")
            try execute("CREATE INDEX IF NOT EXISTS document_title ON documents(trashed, title COLLATE NOCASE, id)")
            try execute("CREATE TABLE IF NOT EXISTS collections (documentID TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY(name, documentID))")
            try execute("CREATE INDEX IF NOT EXISTS collection_document ON collections(documentID)")
            try execute("CREATE TABLE IF NOT EXISTS tags (documentID TEXT NOT NULL, key TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY(key, documentID))")
            try execute("CREATE INDEX IF NOT EXISTS tag_document ON tags(documentID)")
            try execute("CREATE TABLE IF NOT EXISTS entities (documentID TEXT NOT NULL, key TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY(key, documentID))")
            try execute("CREATE INDEX IF NOT EXISTS entity_document ON entities(documentID)")
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS content USING fts5(title, correspondent, metadata, body, tokenize='unicode61 remove_diacritics 2', prefix='2 3 4')")
            try execute("INSERT OR REPLACE INTO info VALUES ('identity', ?)", [identity])
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { sqlite3_close(database) }
    private func failure(_ code: Int32) -> Failure {
        Failure(code: code, message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database.")
    }
    @discardableResult private func statement<T>(_ sql: String, _ values: [String], _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &pointer, nil)
        guard code == SQLITE_OK, let pointer else { throw failure(code) }
        defer { sqlite3_finalize(pointer) }
        for (index, value) in values.enumerated() {
            let bound = sqlite3_bind_text(pointer, Int32(index + 1), value, -1, transient)
            guard bound == SQLITE_OK else { throw failure(bound) }
        }
        return try body(pointer)
    }
    func execute(_ sql: String, _ values: [String] = []) throws {
        try statement(sql, values) { pointer in
            var code = sqlite3_step(pointer)
            while code == SQLITE_ROW { code = sqlite3_step(pointer) }
            guard code == SQLITE_DONE else { throw failure(code) }
        }
    }
    func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        try statement(sql, values) { pointer in
            var result: [[String]] = []
            var code = sqlite3_step(pointer)
            while code == SQLITE_ROW {
                result.append((0..<sqlite3_column_count(pointer)).map { column in
                    sqlite3_column_text(pointer, column).map { String(cString: $0) } ?? ""
                })
                code = sqlite3_step(pointer)
            }
            guard code == SQLITE_DONE else { throw failure(code) }
            return result
        }
    }
    var isBuilt: Bool { get throws { try !rows("SELECT value FROM info WHERE key='built'").isEmpty } }
    func finishBuild() throws { try execute("INSERT OR REPLACE INTO info VALUES ('built','yes')") }
    func reset() throws {
        try transaction {
            try execute("DELETE FROM content")
            try execute("DELETE FROM collections")
            try execute("DELETE FROM tags")
            try execute("DELETE FROM entities")
            try execute("DELETE FROM documents")
            try execute("DELETE FROM info WHERE key='built'")
        }
    }
    func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try work(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func replace(_ document: HouseholdDocument, body: String, failed: Bool) throws {
        let id = document.id.uuidString
        try remove(id)
        try execute("INSERT INTO documents(id,title,imported,bytes,trashed,favorite,inbox,sender,kind,dated,due,expires) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", [id, document.title, String(document.importedAt.timeIntervalSince1970), String(document.fileSize), document.trashedAt == nil ? "0" : "1", document.favorite ? "1" : "0", document.needsReview || failed ? "1" : "0", document.correspondent, document.documentType, String(document.documentDate.timeIntervalSince1970)])
        // Optional dates stay NULL when absent (binding "" would make them compare as text).
        if let due = document.dueDate { try execute("UPDATE documents SET due=? WHERE id=?", [String(due.timeIntervalSince1970), id]) }
        if let expires = document.expiresAt { try execute("UPDATE documents SET expires=? WHERE id=?", [String(expires.timeIntervalSince1970), id]) }
        let rowID = sqlite3_last_insert_rowid(database)
        try execute("INSERT INTO content(rowid,title,correspondent,metadata,body) VALUES(?,?,?,?,?)", [String(rowID), document.title, document.correspondent, document.searchableText, body])
        for name in document.collections { try execute("INSERT INTO collections VALUES(?,?)", [id, name]) }
        for name in document.tagList { try execute("INSERT OR IGNORE INTO tags VALUES(?,?,?)", [id, name.lowercased(), name]) }
        for name in document.entityList { try execute("INSERT OR IGNORE INTO entities VALUES(?,?,?)", [id, name.lowercased(), name]) }
    }
    func remove(_ id: String) throws {
        try execute("DELETE FROM content WHERE rowid IN (SELECT rowid FROM documents WHERE id=?)", [id])
        try execute("DELETE FROM collections WHERE documentID=?", [id])
        try execute("DELETE FROM tags WHERE documentID=?", [id])
        try execute("DELETE FROM entities WHERE documentID=?", [id])
        try execute("DELETE FROM documents WHERE id=?", [id])
    }
    func statistics() throws -> LibraryStatistics {
        let row = try rows("SELECT count(*), coalesce(sum(CASE WHEN trashed=0 AND inbox=1 THEN 1 ELSE 0 END),0), coalesce(sum(trashed),0), coalesce(sum(bytes),0) FROM documents")[0]
        return LibraryStatistics(documents: Int(row[0]) ?? 0, inbox: Int(row[1]) ?? 0, trash: Int(row[2]) ?? 0, bytes: Int64(row[3]) ?? 0)
    }
    func search(_ query: String, destination: LibraryDestination?, filter: LibraryFilter = LibraryFilter(), newestFirst: Bool, offset: Int, limit: Int) throws -> (rows: [[String]], total: Int) {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let expression = SearchQuery.expression(query)
        if searching && expression == nil { return ([], 0) }
        var filters = [destination == .trash ? "d.trashed=1" : "d.trashed=0"]
        var values: [String] = []
        switch destination {
        case .inbox: filters.append("d.inbox=1")
        case .favorites: filters.append("d.favorite=1")
        case .collection(let name):
            filters.append("EXISTS (SELECT 1 FROM collections c WHERE c.documentID=d.id AND c.name=?)"); values.append(name)
        default: break
        }
        let (filterSQL, filterValues) = Self.conditions(filter)
        filters += filterSQL; values += filterValues
        if searching { filters.append("content MATCH ?"); values.append(expression!) }
        // FTS must drive the join, including count(*). With an ordinary JOIN SQLite can
        // scan the active-document index and rerun MATCH for every document (quadratic).
        let from = (searching ? " FROM content CROSS JOIN documents d ON content.rowid=d.rowid" : " FROM documents d") + " WHERE " + filters.joined(separator: " AND ")
        let total = Int(try rows("SELECT count(*)" + from, values)[0][0]) ?? 0
        let snippet = searching ? "snippet(content,-1,'\u{E000}','\u{E001}','…',24)" : "''"
        let order = searching ? "bm25(content,10.0,5.0,2.0,1.0),d.imported DESC,d.id" : (newestFirst ? "d.imported DESC,d.id" : "d.title COLLATE NOCASE,d.id")
        // Rank/limit before generating snippets. Otherwise SQLite can render snippets for
        // every candidate while maintaining its sort, making broad queries very expensive.
        let selected = try rows("SELECT d.id,d.rowid" + from + " ORDER BY " + order + " LIMIT ? OFFSET ?", values + [String(limit), String(offset)])
        let result = try selected.map { row -> [String] in
            guard searching else { return [row[0], ""] }
            let excerpt = try rows("SELECT " + snippet + " FROM content WHERE rowid=? AND content MATCH ?", [row[1], expression!]).first?.first ?? ""
            return [row[0], excerpt]
        }
        return (result, total)
    }

    /// SQL for a filter. Text matches ignore case; periods and "upcoming" use today's bounds.
    static func conditions(_ filter: LibraryFilter, now: Date = Date()) -> ([String], [String]) {
        var sql: [String] = [], values: [String] = []
        if let tag = filter.tag { sql.append("EXISTS (SELECT 1 FROM tags t WHERE t.documentID=d.id AND t.key=?)"); values.append(tag.lowercased()) }
        if let entity = filter.entity { sql.append("EXISTS (SELECT 1 FROM entities e WHERE e.documentID=d.id AND e.key=?)"); values.append(entity.lowercased()) }
        if let sender = filter.sender { sql.append("d.sender=? COLLATE NOCASE"); values.append(sender) }
        if let type = filter.type { sql.append("d.kind=? COLLATE NOCASE"); values.append(type) }
        if let period = filter.period {
            let (start, end) = period.bounds(now: now)
            sql.append("d.dated>=? AND d.dated<?"); values += [String(start.timeIntervalSince1970), String(end.timeIntervalSince1970)]
        }
        let today = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        switch filter.upcoming {
        case .overdue: sql.append("d.due IS NOT NULL AND d.due<?"); values.append(String(today))
        case .dueSoon: sql.append("d.due IS NOT NULL AND d.due>=? AND d.due<?"); values += [String(today), String(today + 31 * 86_400)]
        case .expiringSoon: sql.append("d.expires IS NOT NULL AND d.expires>=? AND d.expires<?"); values += [String(today), String(today + 91 * 86_400)]
        case .soon:
            sql.append("((d.due IS NOT NULL AND d.due<?) OR (d.expires IS NOT NULL AND d.expires>=? AND d.expires<?))")
            values += [String(today + 91 * 86_400), String(today), String(today + 91 * 86_400)]
        case nil: break
        }
        if filter.noCollection { sql.append("NOT EXISTS (SELECT 1 FROM collections c WHERE c.documentID=d.id)") }
        return (sql, values)
    }
    /// What the filter menus offer: tags, senders, and types by use, and document years; Trash excluded.
    func facets() throws -> LibraryFacets {
        func counted(_ sql: String) throws -> [(name: String, count: Int)] {
            try rows(sql).map { ($0[0], Int($0[1]) ?? 0) }.filter { !$0.name.isEmpty }
        }
        var facets = LibraryFacets()
        facets.tags = try counted("SELECT min(t.name), count(*) FROM tags t JOIN documents d ON d.id=t.documentID WHERE d.trashed=0 GROUP BY t.key ORDER BY count(*) DESC, min(t.name) LIMIT 200")
        facets.entities = try counted("SELECT min(e.name), count(*) FROM entities e JOIN documents d ON d.id=e.documentID WHERE d.trashed=0 GROUP BY e.key ORDER BY count(*) DESC, min(e.name) LIMIT 200")
        facets.senders = try counted("SELECT min(sender), count(*) FROM documents WHERE trashed=0 AND sender<>'' GROUP BY sender COLLATE NOCASE ORDER BY count(*) DESC LIMIT 40")
        facets.types = try counted("SELECT min(kind), count(*) FROM documents WHERE trashed=0 AND kind<>'' GROUP BY kind COLLATE NOCASE ORDER BY count(*) DESC LIMIT 40")
        facets.years = try rows("SELECT DISTINCT CAST(strftime('%Y', dated, 'unixepoch', 'localtime') AS INTEGER) FROM documents WHERE trashed=0 AND dated>0 ORDER BY 1 DESC").compactMap { Int($0[0]) }
        return facets
    }
    /// Other documents outside Trash sharing a person or thing with this one, most shared first.
    func related(to id: String, limit: Int = 12) throws -> [(id: String, shared: [String])] {
        let found = try rows("""
            SELECT other.documentID, group_concat(other.name, '|') FROM entities mine
            JOIN entities other ON other.key=mine.key AND other.documentID<>mine.documentID
            JOIN documents d ON d.id=other.documentID AND d.trashed=0
            WHERE mine.documentID=? GROUP BY other.documentID ORDER BY count(*) DESC, max(d.dated) DESC LIMIT ?
            """, [id, String(limit)])
        return found.map { ($0[0], $0[1].split(separator: "|").map(String.init)) }
    }
}
