<!-- Original StowKit product brief, authored by the project owner and used as the source specification for all Codex development (Milestones 1-6). Preserved verbatim; recovered from the Codex attachment store on 2026-09-20. Treat as the product's north star, not as a record of what is built - see README.md and docs/VALIDATION.md for actual status. -->

# StowKit

Build **StowKit**, a lightweight, native macOS document-management application inspired by Paperless-ngx, but designed specifically for Apple platforms.

StowKit should feel like an Apple utility rather than a self-hosted enterprise document-management system.

The core product promise is:

> **Drop documents into StowKit. StowKit understands them, organizes them, stores them safely, and makes them instantly retrievable.**

The guiding principle is:

> **The document should organize itself.**

---

# 1. Product Goals

StowKit should be:

- Native to macOS
- Extremely lightweight
- Fast to launch and search
- Local-first
- Privacy-focused
- Optimized for Apple Silicon
- Integrated with iCloud
- Able to intelligently manage local disk usage
- Shareable between household members
- Simple enough that a nontechnical user can use it without understanding document-management concepts
- Capable of using Apple Intelligence / Apple's Foundation Models framework for document understanding where available
- Functional without requiring Docker, a server, PostgreSQL, Redis, Elasticsearch, or a web browser

StowKit should initially target a **household document archive**, not enterprise document management.

Typical documents include:

- Tax documents
- Insurance policies
- Receipts
- Warranties
- Vehicle documents
- Home records
- School documents
- Bills
- Financial statements
- Contracts
- Medical documents
- Pet records
- Travel documents
- Manuals
- Scanned paperwork

---

# 2. Target Platforms

Primary:

- macOS
- Apple Silicon
- Native Swift / SwiftUI application

Future:

- iPhone
- iPad

The initial architecture should anticipate an iOS companion, but **do not build the full iOS application during the first implementation unless necessary for shared code architecture**.

---

# 3. Technology Philosophy

Prefer Apple-native frameworks whenever reasonable.

Avoid unnecessary dependencies.

Preferred technology stack:

- Swift
- SwiftUI
- SwiftData where appropriate
- CloudKit
- iCloud
- PDFKit
- Vision
- VisionKit where applicable
- Quick Look
- Foundation Models framework / Apple Intelligence where available
- App Intents
- Uniform Type Identifiers
- CryptoKit if document hashing is needed

Use third-party packages only when there is a meaningful capability gap.

Do NOT build this as:

- Electron
- React Native
- a web app
- a local web server
- Docker containers
- a client/server architecture

The Mac application itself should be the application.

---

# 4. Core Mental Model

The StowKit workflow is:

**Capture → Understand → Stow → Find**

Users should not have to manually organize every document.

A new document enters the system.

StowKit:

1. imports it
2. preserves the original
3. extracts text
4. understands the document
5. generates useful metadata
6. categorizes it
7. stores it
8. indexes it
9. makes it searchable

Only documents with uncertain classifications should require user review.

---

# 5. Main Navigation

Use a native macOS three-pane NavigationSplitView-style interface.

Suggested structure:

```text
┌────────────────┬──────────────────────────┬──────────────────────┐
│ Sidebar        │ Document List            │ Inspector / Preview  │
│                │                          │                      │
│ Inbox          │ Property Tax Bill        │ PDF Preview          │
│ Recent         │ State Farm Policy        │                      │
│ Favorites      │ Refrigerator Receipt     │ Metadata             │
│                │ School Tuition           │                      │
│ Collections    │                          │ Related Documents    │
│ Home           │                          │                      │
│ Vehicles       │                          │                      │
│ Financial      │                          │                      │
│ Insurance      │                          │                      │
│ Taxes          │                          │                      │
│ Kids           │                          │                      │
│ Receipts       │                          │                      │
│                │                          │                      │
└────────────────┴──────────────────────────┴──────────────────────┘
```

The design should feel closer to:

- Finder
- Notes
- Preview
- Mail

than to a database administration interface.

Use standard macOS behaviors wherever possible.

---

# 6. Document Import

Support:

- Drag and drop into the app
- File picker
- Drag onto the Dock icon eventually
- Share Extension eventually
- Scan/import from iPhone eventually

Initial supported formats should include:

- PDF
- JPEG
- PNG
- HEIC

Design the importer so other formats can be supported later.

When importing a document:

1. Calculate a cryptographic hash.
2. Detect duplicates.
3. Preserve the original file.
4. Create an internal document record.
5. Generate a preview/thumbnail.
6. Extract text.
7. Run document understanding.
8. Generate metadata.
9. Index the document.
10. Place it into the appropriate collection or review queue.

Never modify the original source document.

---

# 7. Document Data Model

Create a robust but simple underlying model.

A document should conceptually include:

```swift
Document {
    id
    createdAt
    importedAt
    modifiedAt

    originalFilename
    displayTitle

    fileType
    fileSize
    contentHash

    documentDate
    dueDate
    expirationDate

    correspondent
    documentType

    summary

    extractedText

    confidenceScore

    processingStatus

    favorite

    storageStatus

    collectionRelationships
    tagRelationships
    entityRelationships
}
```

Do not make the UI expose the complexity of the underlying schema.

---

# 8. Collections

Collections are the primary visible organization mechanism.

Example defaults:

- Home
- Vehicles
- Financial
- Taxes
- Insurance
- Kids
- Medical
- Pets
- Travel
- Warranties
- Receipts
- Legal

Collections should not represent filesystem directories.

Documents may belong to more than one collection.

Users should be able to create custom collections.

---

# 9. Tags

Support tags, but treat them as secondary organization.

Tags should mostly be generated automatically.

Example:

```text
property-tax
2026
navigator
warranty
school
state-farm
receipt
```

Do not force users to maintain a complicated tagging taxonomy.

---

# 10. Entities

Create an entity system that allows documents to be associated with real-world things.

Entity types should eventually include:

- Person
- Organization
- Property
- Vehicle
- Product
- Account
- School
- Pet
- Other

Examples:

```text
Chris
Lydia
Etta
Viva

Home

Lincoln Navigator

State Farm

St. Rose

LG Refrigerator
```

Documents can connect to multiple entities.

This should eventually allow StowKit to build relationships between documents without relying solely on folders or tags.

---

# 11. Document Understanding Pipeline

Build document processing as a modular pipeline.

Conceptually:

```text
Import
  ↓
Type Detection
  ↓
OCR / Text Extraction
  ↓
Document Structure Recognition
  ↓
AI Understanding
  ↓
Metadata Extraction
  ↓
Classification
  ↓
Indexing
  ↓
Storage
```

Each stage should have an independent status.

Failures should not corrupt or block the document from being archived.

---

# 12. OCR

Use Apple's Vision framework where practical.

For PDFs:

- Prefer embedded text when good text already exists.
- Use OCR only when needed.

For scans/images:

- Perform local OCR.

Store normalized extracted text in the database/index.

OCR should happen asynchronously without blocking the interface.

---

# 13. Apple Intelligence / Foundation Models

Create an abstraction called something like:

```swift
DocumentIntelligenceProvider
```

The rest of StowKit should not directly depend on a specific AI implementation.

Possible implementations:

```text
AppleFoundationModelProvider
RuleBasedProvider
FutureExternalModelProvider
```

The default should use Apple's on-device Foundation Models framework where available.

AI should analyze the document and return structured information.

Conceptually:

```swift
DocumentUnderstanding {
    suggestedTitle
    documentType
    primaryCollection
    suggestedCollections
    correspondent

    documentDate
    dueDate
    expirationDate

    amount
    currency

    people
    organizations

    tags

    summary

    confidence
}
```

Use strongly typed structured output rather than parsing arbitrary free-form text whenever Apple's APIs support it.

AI must never modify the original document.

---

# 14. Graceful AI Degradation

StowKit must remain useful without Apple Intelligence.

If Foundation Models are unavailable:

- OCR still works.
- Full-text search still works.
- Manual metadata still works.
- Simple deterministic categorization may still work.
- Users can manually assign collections.

AI should enhance StowKit rather than become a hard dependency.

---

# 15. Confidence-Based Filing

Avoid requiring users to approve every document.

Use a confidence-based system.

Conceptually:

```text
High confidence
→ automatically stow

Medium confidence
→ stow, but surface prominently in Recent

Low confidence
→ Needs Review
```

Initial thresholds can be configurable constants rather than user-facing settings.

Example:

```text
>= 0.90   Auto-file
0.65–0.89 Auto-file + highlight
< 0.65    Needs Review
```

The Inbox should primarily represent documents that need attention.

---

# 16. Search

Search is one of the most important parts of StowKit.

Provide instantaneous local full-text search.

Search across:

- titles
- OCR text
- correspondents
- document types
- collections
- tags
- entities
- dates

Search should behave more like Spotlight than a traditional database search page.

Keyboard shortcut:

```text
⌘K
```

should activate global StowKit search.

Eventually support natural-language queries such as:

```text
Find the warranty for the refrigerator.

Show me the Navigator insurance policy.

What did we pay for the couch?

Find our property tax bill from last year.
```

Do not make semantic search a blocker for V1.

Start with excellent full-text search.

---

# 17. Document Inspector

Selecting a document should expose:

- preview
- title
- summary
- document date
- correspondent
- collections
- tags
- entities
- extracted dates
- detected amount
- storage status
- processing status
- original filename

Metadata should be editable.

AI-generated metadata should not be visually overwhelming.

---

# 18. Original File Storage

Do not use the human organizational hierarchy as the physical file hierarchy.

Internally, documents can use opaque IDs.

Example:

```text
Documents/
    71/
        71F348AC...pdf
    A9/
        A9127B...pdf
```

Metadata determines logical organization.

This makes it possible for documents to appear in multiple collections without duplication.

---

# 19. iCloud

iCloud should be a core architecture component.

The archive should ultimately synchronize between authorized devices.

Use CloudKit and/or Apple's appropriate iCloud document-storage APIs.

Architect this carefully before implementation.

Requirements:

- Original documents can live primarily in iCloud.
- Metadata synchronizes.
- Multiple Macs/iPhones can eventually access the archive.
- A document should not disappear merely because the main MacBook is offline.
- Conflict handling should be predictable.

Do not assume that the MacBook itself must operate as a server.

---

# 20. Household Sharing

StowKit should eventually support a shared household archive.

Example:

```text
StowKit Household

Members:
Chris
Lydia
```

Both members should eventually be able to:

- import documents
- view shared documents
- search
- edit metadata
- create collections

Use native Apple/iCloud identity and sharing mechanisms where possible rather than building custom usernames/passwords.

Architect the data model for shared ownership from the beginning even if sharing is implemented after the initial MVP.

Eventually support both:

```text
Shared Household Documents

Private Documents
```

but private archives are not required for V1.

---

# 21. Storage Optimization

One of StowKit's major differentiators is intelligent local-storage management.

Documents should support states conceptually similar to:

```text
Cloud Only

Optimized

Available Offline
```

For Optimized documents, keep lightweight local information such as:

- metadata
- OCR text
- thumbnail
- search index
- small preview if needed

The full original can remain in iCloud until requested.

The user should eventually be able to configure options such as:

```text
Keep documents from the last 12 months downloaded.

Maximum archive disk usage: 10 GB.
```

Build storage-management logic behind a dedicated abstraction such as:

```swift
DocumentStorageManager
```

Do not spread storage decisions throughout the UI layer.

---

# 22. Local Cache

Treat downloaded originals as a cache when appropriate.

Track:

```text
lastAccessed
localSize
downloadStatus
pinStatus
```

Eventually implement an LRU-style eviction system.

Pinned documents must never be automatically removed locally.

Do not implement aggressive eviction until the core archive is stable.

---

# 23. Duplicate Detection

Use cryptographic content hashing.

When importing an exact duplicate:

- detect it
- avoid storing the file twice
- tell the user it already exists

Later support near-duplicate detection, but exact duplicates are sufficient initially.

---

# 24. Related Documents

Design the data model so documents can eventually be linked.

Examples:

```text
LG Refrigerator

Related Documents:
Purchase Receipt
Warranty
Manual
Insurance Inventory
Repair Receipt
```

Relationships may initially be manual.

AI-based relationship detection can be added later.

---

# 25. Actions

AI may detect actionable information such as:

- payment due date
- renewal
- expiration
- warranty expiration
- appointment
- deadline

Represent these internally as suggested actions.

Do NOT automatically create calendar events or reminders.

Eventually present suggestions such as:

```text
Detected:
Insurance renewal due October 8

[Add Reminder]
```

This is not part of the first implementation.

---

# 26. Privacy

StowKit will contain sensitive personal documents.

Privacy is a core product attribute.

Default behavior should prioritize:

- local processing
- Apple-native APIs
- iCloud
- no third-party analytics
- no uploading document contents to external AI services

Do not add telemetry unless explicitly requested.

Never transmit document contents externally without a deliberate future feature and explicit user consent.

---

# 27. Performance

The application should remain responsive with a large archive.

Design for at least:

```text
10,000–50,000 documents
```

without requiring server infrastructure.

Requirements:

- asynchronous import
- asynchronous OCR
- asynchronous AI processing
- incremental indexing
- lazy thumbnail generation where appropriate
- virtualization/lazy loading in lists
- no blocking large-file operations on the main thread

Launch should not require scanning the entire archive.

---

# 28. Background Processing

Create a processing queue.

Possible document states:

```swift
enum ProcessingState {
    case imported
    case extractingText
    case analyzing
    case indexing
    case complete
    case needsReview
    case failed
}
```

Processing should be resumable.

If the app quits halfway through processing, it should continue safely on next launch.

---

# 29. UI Principles

The UI should be:

- understated
- native
- dense enough to be productive
- not visually busy
- keyboard friendly
- comfortable with thousands of documents

Prefer system components.

Avoid excessive:

- rounded cards
- giant headers
- gradients
- dashboard widgets
- unnecessary animations
- custom controls where native controls work

This should feel like a serious macOS utility.

---

# 30. Keyboard Experience

Support common Mac conventions.

Examples:

```text
⌘N        Import document
⌘K        Search
⌘F        Search/filter current view
⌘O        Open original
Space     Quick Look
Delete    Remove from archive
⌘,        Settings
```

Implement only appropriate shortcuts initially.

---

# 31. Settings

Keep settings minimal.

Potential sections:

```text
General
Storage
AI
iCloud
Household
```

Do not create a large preferences surface in V1.

---

# 32. V1 Scope

The first usable version should focus on:

### Required

1. Native SwiftUI macOS application
2. Persistent document library
3. Drag/drop PDF and image importing
4. Duplicate detection
5. Original preservation
6. PDF/image preview
7. OCR/text extraction
8. Document processing pipeline
9. Collections
10. Tags
11. Editable metadata
12. Full-text search
13. Basic automatic document understanding
14. Apple Foundation Models integration where available
15. Graceful fallback when Apple Intelligence is unavailable
16. Processing status
17. Needs Review queue
18. Clean three-pane interface

### Architect for but do not necessarily implement immediately

- CloudKit synchronization
- household sharing
- iCloud optimized storage
- iPhone app
- Share Extension
- semantic search
- related documents
- reminder suggestions
- private household collections
- Spotlight integration
- App Intents

---

# 33. Explicitly Out of Scope for V1

Do not build:

- Web UI
- user accounts
- custom authentication
- Docker support
- PostgreSQL
- Redis
- Elasticsearch
- rule-builder UI
- workflow builder
- email server ingestion
- external cloud AI
- browser extension
- enterprise roles
- complicated permissions
- OCR configuration screens
- plugin architecture
- NAS/server deployment
- mobile application

unless needed later.

---

# 34. Suggested Project Architecture

Use clear feature/module boundaries.

Conceptually:

```text
StowKit/
│
├── App/
│
├── Models/
│   ├── Document
│   ├── Collection
│   ├── Tag
│   ├── Entity
│   └── ProcessingJob
│
├── Features/
│   ├── Library
│   ├── Inbox
│   ├── Search
│   ├── DocumentViewer
│   ├── Import
│   └── Settings
│
├── Services/
│   ├── DocumentImporter
│   ├── DocumentProcessor
│   ├── OCRService
│   ├── DocumentIntelligenceProvider
│   ├── SearchService
│   ├── DocumentStorageManager
│   ├── ThumbnailService
│   └── DuplicateDetectionService
│
├── Persistence/
│
├── Intelligence/
│   ├── AppleFoundationModelProvider
│   └── FallbackIntelligenceProvider
│
└── Utilities/
```

Do not over-engineer modules into separate Swift packages unless there is a clear benefit.

Prefer simple boundaries and protocols.

---

# 35. Engineering Principles

When making implementation decisions:

1. Favor native Apple APIs.
2. Favor fewer dependencies.
3. Keep the data model migration-friendly.
4. Separate file storage from metadata storage.
5. Separate AI from document processing.
6. Never require AI for basic functionality.
7. Preserve source documents exactly.
8. Make all expensive work asynchronous.
9. Make interrupted processing recoverable.
10. Keep the interface simple even if the underlying system is sophisticated.
11. Avoid premature abstractions.
12. Build working vertical slices before expanding scope.

---

# 36. Initial Milestones

## Milestone 1 — Native Shell

Create:

- SwiftUI macOS project
- three-pane layout
- sidebar
- mock document list
- document inspector
- PDF/image preview

Use sample data.

Goal:

The application should already visually resemble the eventual product.

---

## Milestone 2 — Real Document Library

Implement:

- SwiftData models
- file importer
- drag/drop
- internal storage
- hashing
- duplicate detection
- document deletion
- thumbnails
- preview

Goal:

StowKit becomes a functional manual document archive.

---

## Milestone 3 — OCR + Processing Pipeline

Implement:

- processing queue
- Vision text extraction
- PDF embedded text extraction
- processing-state UI
- failure/retry handling

Goal:

Every imported document automatically becomes searchable.

---

## Milestone 4 — Search

Implement:

- full-text indexing
- title search
- OCR search
- metadata search
- instant search UI
- ⌘K

Goal:

Finding documents should become faster than finding them manually in Finder.

---

## Milestone 5 — Intelligence

Implement:

- DocumentIntelligenceProvider protocol
- Foundation Models provider
- structured document analysis
- title generation
- classification
- collection suggestions
- tags
- summary
- confidence scoring
- Needs Review logic

Goal:

Documents begin organizing themselves.

---

## Milestone 6 — iCloud Architecture

Before coding synchronization heavily, document the proposed architecture.

Determine:

- what CloudKit stores
- where originals live
- which metadata syncs
- how shared archives work
- how conflicts work
- how large assets are handled
- how local caching works

Create an architecture note before implementation.

Goal:

Avoid creating a local-storage architecture that later becomes difficult to synchronize.

---

# 37. First Task for Codex

Start by inspecting the repository.

If it is empty, create the native macOS project structure for StowKit.

Build **Milestone 1 only**.

Do not attempt to implement the entire specification immediately.

Create a high-quality native macOS shell using SwiftUI.

The initial app should contain:

- Sidebar
- Inbox
- Recent
- Favorites
- default Collections
- document list
- document inspector
- PDF/image preview area
- mock document metadata
- toolbar
- search field or search affordance

Use realistic mock household documents.

Examples:

```text
2026 Property Tax Bill
State Farm Auto Policy
Lincoln Navigator Purchase Agreement
St. Rose Tuition Statement
LG Refrigerator Warranty
Costco Receipt
Passport Renewal
Homeowners Insurance Policy
```

Prioritize:

1. native macOS behavior
2. clean information architecture
3. excellent visual polish
4. maintainable SwiftUI structure

Do not invent a custom design system.

Use Apple's system typography, spacing, sidebar behaviors, toolbar conventions, context menus, selection states, and materials.

Once Milestone 1 builds successfully, document:

- project structure
- major architectural decisions
- recommended next implementation step
- any Apple-framework limitations discovered

Then stop.

Do not proceed into persistence or AI until the initial native shell is working and coherent.