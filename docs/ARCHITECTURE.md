# Milestone 1 handoff

## Structure

- `StowKit/App`: application scene, menu commands, Settings, and observable in-memory library state.
- `StowKit/Models`: value-type document, navigation destination, and collection definitions.
- `StowKit/Features/Library`: native sidebar, filtered document list, search, sort, context menus, and collection sheet.
- `StowKit/Features/DocumentViewer`: editable inspector, review controls, PDFKit adapter, image preview, and Quick Look.
- `StowKit/SampleData`: eight fictional household records and clearly labeled generated preview fixtures.
- `StowKit.xcodeproj`: dependency-free native macOS application target.

## Decisions

The shell uses NavigationSplitView, standard List selection, system fonts, toolbars, native menus, a resizable preview/metadata divider, and system colors. It does not introduce a custom design system. A macOS 14 minimum supports Observation and the native empty-state components.

LibraryStore owns sample state on the main actor; views bind directly to the selected value-type document. Selection is reconciled when search, navigation, or membership changes remove the selected record. Collections are logical many-to-many memberships, never file paths. Stable document UUIDs identify sample preview files. Models are intentionally not SwiftData models yet: persistence and schema migration decisions belong to the next milestone.

PDFKit renders PDFs, while SwiftUI displays images. Quick Look is a separate native presentation. PDF preview uses single-page fitting to keep a complete document visible in the limited pane. Users can hide details for a larger preview. Original-file operations currently open generated samples only.

Sample fixtures are generated with AppKit in the app's temporary directory. The eight tiny one-page fixtures are rendered on the main actor because AppKit view drawing requires it. This is demo scaffolding, not a production importer. Production hashing, storage, OCR, and thumbnail operations must be asynchronous and off the main actor.

Search currently scans eight in-memory sample records. It is not a full-text index and makes no 50,000-document performance claim. Do not carry this approach into production-scale search.

The model includes collections, tags, and entities sufficient for the shell. It does not prematurely implement the full processing, ownership, cloud, or action schema. A production record should separate immutable source identity from editable metadata and local cache state.

## Next step: Milestone 2

Introduce a migration-ready SwiftData store and a dedicated original-file storage service. Add security-scoped file import and drag/drop for PDF/JPEG/PNG/HEIC, streaming SHA-256 duplicate detection, atomic opaque-ID storage, persistent metadata, thumbnails, and recoverable deletion. Verify byte-for-byte source preservation and duplicate handling before proceeding to OCR. Keep generated samples explicitly separate from the real archive.

Before cloud implementation, write a dedicated design covering archive ownership IDs, CKShare household membership, private/shared record zones, CKAsset originals, conflict resolution, tombstones, resumable transfers, and a local cache with offline pins. Do not assume SwiftData automatic CloudKit synchronization alone implements household sharing. Cloud-only states must never be presented before originals have actually been uploaded and verified.

## Validation and limitations

Debug build succeeded with Xcode 26.3 / Swift 6.2.4 on Apple Silicon. Native runtime inspection confirmed all eight list rows, Inbox's three-item review badge, PDF text rendering, image selection, the PNG preview, and matching inspector metadata. Visual inspection confirmed the three-pane layout. The preview/details balance was subsequently adjusted to give preview more room and fit one PDF page. Runtime checks also confirmed that searching “refrigerator” yields exactly the warranty, Inbox filters to three review documents, and Mark Reviewed removes a document from Inbox, decrements the badge, and selects the next record. Broader keyboard and metadata-edit smoke testing remains recommended; no automated UI suite is claimed.

The restricted command sandbox prevented Swift Observation's compiler plugin from launching; building through approved Xcode execution succeeded. This is an execution-environment constraint, not an application dependency. Xcode emits its standard notice that App Intents metadata extraction is skipped because this milestone has no App Intents integration.

Foundation Models, Vision OCR, CloudKit, household sharing, original storage, and storage optimization are deliberately unimplemented. Their availability and entitlement requirements have not been validated by this milestone. The sandboxed app has user-selected read access and no network entitlement. Distribution signing, notarization, an app icon, and release packaging remain future work.
