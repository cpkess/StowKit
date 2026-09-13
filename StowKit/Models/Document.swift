import Foundation

struct LibraryCollection: Identifiable, Hashable {
    let name: String
    let symbol: String
    var id: String { name }

    static let defaults: [Self] = [
        .init(name: "Home", symbol: "house"),
        .init(name: "Vehicles", symbol: "car"),
        .init(name: "Financial", symbol: "banknote"),
        .init(name: "Taxes", symbol: "doc.text"),
        .init(name: "Insurance", symbol: "umbrella"),
        .init(name: "Kids", symbol: "figure.2.and.child.holdinghands"),
        .init(name: "Medical", symbol: "cross.case"),
        .init(name: "Pets", symbol: "pawprint"),
        .init(name: "Travel", symbol: "airplane"),
        .init(name: "Warranties", symbol: "checkmark.shield"),
        .init(name: "Receipts", symbol: "receipt"),
        .init(name: "Legal", symbol: "signature")
    ]
}

enum LibraryDestination: Hashable {
    case inbox, recent, favorites, collection(String)
    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .recent: "Recent"
        case .favorites: "Favorites"
        case .collection(let name): name
        }
    }
}

struct HouseholdDocument: Identifiable, Equatable {
    let id: UUID
    var title: String
    let originalFilename: String
    var correspondent: String
    var documentDate: Date
    let importedAt: Date
    var summary: String
    var collections: Set<String>
    var tags: String
    var entities: String
    var favorite: Bool = false
    var needsReview: Bool = false
    let isImage: Bool
    let amount: String?
    let detail: String
    var previewURL: URL?
    var searchableText: String {
        ([title, originalFilename, correspondent, summary, tags, entities,
          documentDate.formatted(date: .abbreviated, time: .omitted)] + collections.sorted()).joined(separator: " ")
    }
}
