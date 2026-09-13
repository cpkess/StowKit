import AppKit
import PDFKit

// Deliberately synthetic. Nothing is read from the user's document library.
enum SampleLibrary {
    static func documents() -> [HouseholdDocument] {
        let rows: [(String, String, String, [String], String, String, String?, Bool, Bool)] = [
            ("2026 Property Tax Bill", "County Treasurer", "Annual property tax assessment for the family home. The first installment is due October 1, 2026.", ["Home", "Taxes"], "property-tax, 2026", "Home", "$4,280.00", true, false),
            ("State Farm Auto Policy", "State Farm", "Auto insurance coverage for the Lincoln Navigator, including liability, comprehensive, and collision protection.", ["Vehicles", "Insurance"], "auto-insurance, navigator, 2026", "Lincoln Navigator, State Farm", "$1,248.00", false, true),
            ("Lincoln Navigator Purchase Agreement", "Lincoln Motor Company", "Vehicle purchase agreement and delivery record. Includes the purchase price and the dealer's terms.", ["Vehicles", "Legal"], "navigator, purchase", "Lincoln Navigator", "$78,450.00", false, true),
            ("St. Rose Tuition Statement", "St. Rose School", "Fall semester tuition statement for the 2026–2027 school year. Includes the payment schedule and activity fees.", ["Kids", "Financial"], "school, tuition, 2026", "St. Rose", "$3,600.00", true, false),
            ("LG Refrigerator Warranty", "LG Electronics", "Limited refrigerator warranty covering parts and labor for one year, with extended coverage on the compressor.", ["Home", "Warranties"], "warranty, refrigerator, lg", "LG Refrigerator, Home", nil, false, true),
            ("Costco Receipt", "Costco Wholesale", "Household shopping receipt, including pantry essentials, cleaning supplies, and school snacks.", ["Receipts", "Financial"], "receipt, household", "Costco", "$186.42", false, false),
            ("Passport Renewal", "U.S. Department of State", "Passport renewal checklist and application instructions. Review the required supporting documents before mailing.", ["Travel"], "passport, renewal", "Chris", "$130.00", true, false),
            ("Homeowners Insurance Policy", "State Farm", "Annual homeowners policy with dwelling, personal property, and personal liability coverage.", ["Home", "Insurance"], "homeowners, policy, 2026", "Home, State Farm", "$2,140.00", false, false)
        ]
        return rows.enumerated().map { index, row in
            let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 12 - index))!
            return HouseholdDocument(id: UUID(), title: row.0,
                originalFilename: row.0.replacingOccurrences(of: " ", with: "_") + (index == 5 ? ".png" : ".pdf"),
                correspondent: row.1, documentDate: date, importedAt: date,
                summary: row.2, collections: Set(row.3), tags: row.4, entities: row.5,
                favorite: row.8, needsReview: row.7, isImage: index == 5, amount: row.6,
                detail: index == 0 ? "First installment due October 1, 2026" : "For your household records")
        }
    }

    /// Small, generated fixtures only; original storage belongs to Milestone 2.
    static func makePreviews(for documents: [HouseholdDocument]) throws -> [UUID: URL] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StowKit-Samples", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [UUID: URL] = [:]
        for document in documents {
            let page = SamplePage(document: document)
            let url = directory.appendingPathComponent(document.id.uuidString).appendingPathExtension(document.isImage ? "png" : "pdf")
            if document.isImage {
                guard let bitmap = page.bitmapImageRepForCachingDisplay(in: page.bounds) else { continue }
                page.cacheDisplay(in: page.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
                try data.write(to: url, options: .atomic)
            } else {
                try page.dataWithPDF(inside: page.bounds).write(to: url, options: .atomic)
            }
            urls[document.id] = url
        }
        return urls
    }
}

private final class SamplePage: NSView {
    let document: HouseholdDocument
    init(document: HouseholdDocument) {
        self.document = document
        super.init(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        func text(_ value: String, _ y: CGFloat, size: CGFloat = 12, bold: Bool = false, gray: Bool = false) {
            (value as NSString).draw(in: NSRect(x: 54, y: y, width: 504, height: 130), withAttributes: [
                .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                .foregroundColor: gray ? NSColor.darkGray : NSColor.black
            ])
        }
        text(document.correspondent.uppercased(), 55, size: 12, bold: true, gray: true)
        text(document.title, 105, size: 27, bold: true)
        text(document.documentDate.formatted(date: .long, time: .omitted), 188, gray: true)
        NSColor.lightGray.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 54, y: 227)); line.line(to: NSPoint(x: 558, y: 227)); line.stroke()
        text("HOUSEHOLD RECORD", 254, size: 10, bold: true, gray: true)
        text(document.summary, 282, size: 15)
        if let amount = document.amount {
            text(document.isImage ? "TOTAL" : "AMOUNT", 414, size: 10, bold: true, gray: true)
            text(amount, 440, size: 30, bold: true)
        }
        text(document.detail, 525, size: 13)
        text("Keep this document with your household records.", 571, gray: true)
        text("SAMPLE DOCUMENT · STOWKIT DEMO\nFictional content for preview purposes only. Not an official record.", 695, size: 10, gray: true)
    }
}
