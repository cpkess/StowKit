import SwiftUI

/// Documents sharing a person or thing with this one: the refrigerator's receipt, warranty, and
/// manual find each other through "LG Refrigerator", with no manual linking.
struct RelatedDocumentsView: View {
    let document: HouseholdDocument
    let load: (HouseholdDocument) async -> [(document: HouseholdDocument, shared: [String])]
    let open: (UUID) -> Void
    @State private var items: [(document: HouseholdDocument, shared: [String])] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Related").font(.subheadline.weight(.medium))
            if items.isEmpty {
                Text("No other documents mention \(document.entityList.joined(separator: ", ")).").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items, id: \.document.id) { item in
                Button { open(item.document.id) } label: {
                    HStack {
                        Text(item.document.title).lineLimit(1)
                        Spacer()
                        Text(item.shared.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(item.document.documentDate, format: .dateTime.year()).font(.caption).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .task(id: "\(document.id)|\(document.entities)") { items = await load(document) }
    }
}
