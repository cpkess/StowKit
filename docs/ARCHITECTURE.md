# StowKit architecture

## Current scope

Milestone 3 is a native archive with persistent background text extraction and local OCR. Manual organization remains available throughout processing. AI classification, a dedicated full-text index, CloudKit, and household sharing remain unimplemented. All processing stays on this Mac.

## Project structure

- `App/LibraryStore.swift`: observable presentation state, navigation, a sequential import queue, persistent metadata edits, and native drop-provider delivery.
- `App/StowKitApp.swift`: one shared library window, search commands, and minimal Settings.
- `Models/Document.swift`: Sendable value snapshots, navigation, and collection definitions. SwiftUI does not own SwiftData models or file-storage decisions.
- `Persistence/ArchiveSchema.swift`: frozen V1 document, collection, and archive models plus the migration-plan entry point. `ProcessingSchema.swift` adds V2 job and page-text tables through a lightweight migration; V1 document fields remain unchanged.
- `Persistence/ArchiveRepository.swift`: explicit metadata transactions. Autosave is disabled; failed saves roll back and are reported. Existing records are checked before insertion to avoid SwiftData unique-attribute upserts silently changing documents.
- `Services/DocumentStorageManager.swift`: actor-isolated file coordination, chunked copying/hashing, validation, recovery receipts, promotion, and external working copies.
- `Services/DocumentImporter.swift`: joins file and metadata commits and reports duplicates, including documents in Trash.
- `Services/ThumbnailService.swift`: background ImageIO/Core Graphics rendering, small cached thumbnails, and downsampled image previews.
- `Persistence/ArchiveRepository+Processing.swift`: durable job transitions, migration backfill, per-page checkpoint transactions, and retry/reset operations.
- `Services/DocumentProcessor.swift`: one-job-at-a-time orchestration with cancellation, per-job failure isolation, and Trash-aware pausing.
- `Services/OCRService.swift`: actor-confined PDF parsing, rasterization, and Vision requests behind `DocumentTextExtractor`.
- `Services/TextSearchService.swift`: background database queries for page text and an on-demand extracted-text reader. Large text is absent from UI document snapshots.
- `Features/Library`: sidebar, import picker/drop target, list, thumbnails, reports, search, custom collections, and context actions.
- `Features/DocumentViewer`: persistent editable inspector, PDFKit page navigation, image previews, Quick Look, and Trash/Restore controls.
- `StowKitTests`: hosted XCTest tests using temporary roots and generated fixtures. Tests exercise the production services, not parallel mock implementations.

## Import transaction and recovery

1. Start security-scoped access to the selected source and coordinate a read. Reject unsupported extensions, directories, empty files, and bytes that do not match a supported file type. Locked PDFs are allowed even when no thumbnail can be rendered.
2. Stream the source into an app-owned staging directory in 1 MiB chunks, computing SHA-256 over exactly the bytes written. Synchronize the staged file. Compare source size/modification time before and after copying to detect concurrent changes.
3. Publish a JSON receipt atomically, containing the UUID, original filename, content type, hash, size, import time, and generated relative path. The receipt contains no extracted document text.
4. Look up the content hash in SwiftData, including Trash. If a duplicate exists, verify its archived original before discarding the staging copy; preserve the existing metadata. If the existing original cannot be verified, retain the new recovery copy and report a failure rather than claim safe deduplication.
5. Verify the staged hash and atomically rename into `Originals/<UUID prefix>/<UUID>.<extension>` on the same filesystem. Mark the original read-only.
6. Save the SwiftData document and queued processing job in one transaction. Remove the receipt only after the metadata transaction succeeds. Failure to clean a committed receipt is harmless: next launch deduplicates it.

At launch, inspect the small Staging directory rather than scan all originals. Resume receipts left before promotion, after promotion, or after database commit. Recheck hashes and identity. Corrupt recovery manifests are retained and reported while valid pending imports continue. Incomplete streaming copies without a receipt are discarded; the source is untouched. Files still waiting in the in-memory import queue, or interrupted before a receipt was published, must be selected again after an unexpected quit. Once the original is archived, OCR work is durable in the processing-job table. Pending source selections before archive import are still an in-memory queue; they are distinct from processing jobs.

This provides process-interruption recovery; it is not a promise against disk failure or loss of the entire Mac. File and metadata storage are independent, so the receipt bridges their transaction boundary. No automatic orphan-original deletion or storage eviction is implemented.

## Metadata and ownership

Each document stores its UUID, stable archive UUID, immutable source identity, file size/type/hash, and relative file path separately from editable metadata. Collections are many-to-many name memberships; default and custom collection definitions persist separately. Tags and entities currently use editable comma-separated text. Normalize them into dedicated records when entity relations and renaming require it, using a schema migration.

The current library uses one local household archive identity. It is not a CloudKit zone or authentication identity. Metadata edits and Trash transitions save synchronously as small SwiftData transactions on the main actor. Large file copying, hashing, image decoding/downsampling, and thumbnail generation run on service actors. PDF loading occurs in a detached task, with presentation handled by PDFKit.

Text extraction does not classify metadata: new records need manual review, titles come from filenames, and the initial document date is the import date until edited. OCR text is stored for retrieval, but importing does not parse dates or amounts into metadata fields.

## Deletion and original protection

Trash is a reversible metadata timestamp. It hides documents from active navigation and search while leaving original paths, thumbnails, IDs, hashes, and metadata intact. Restore clears the timestamp. There is no automatic purge or permanent deletion in this milestone. Deduplication includes Trash.

The inline viewer reads archived originals. External Open creates a separate writable temporary copy with the original filename, so Preview or another application cannot accidentally save over the archive. Edits to working copies require an explicit future reimport; they are never synchronized back implicitly. Temporary copies are not a durable document location.

## Performance boundary

List thumbnails are requested lazily and cached by immutable document UUID. Image previews are capped at 2,048 pixels on their longest side. Hashing and file copies use bounded buffers. One import batch continues after individual errors; additional batches append to the running queue.

This milestone loads metadata snapshots and filters them in memory. It does not scan original contents at launch; the background queue opens originals only when processing them. Text queries use folded substring predicates on separate page records, through an actor constructed off the main thread. Search can combine metadata and matches from different pages without eagerly loading OCR text. Query generations discard stale asynchronous results. There is no dedicated full-text index or relevance ranking yet, and no validated 50,000-document search/launch target. Milestone 4 should introduce paged fetches and incremental indexing before production-scale search claims.

## Processing pipeline

V2 adds a unique job per document and separate page-text records. Successful imports create the job atomically with metadata. On launch, documents migrated from V1 receive missing jobs; interrupted extraction/saving states return to queued with their checkpoints intact. Jobs in Trash pause, and failed jobs wait for explicit retry. This startup step reads metadata only.

A job proceeds through queued → extracting text → saving text (per page) → complete. Errors retain the failed stage, message, attempt count, and any completed pages. Page text, its extraction method, and the next-page checkpoint save in one transaction. Resuming never skips a page whose text was not committed. The worker processes one document at a time while the importer and UI remain available. A persistence error stops the worker and surfaces a restart message rather than spinning on failed saves.

PDF pages with enough plausible embedded text use PDFKit text directly. Sparse or broken text layers trigger rasterization and Vision OCR. Each page is considered separately, supporting mixed digital/scanned PDFs. The initial heuristic is intentionally simple: a plausible but incomplete text layer can still miss image-only content on the same page. Images use ImageIO orientation correction and bounded downsampling. PDF rasterization respects crop boxes and rotation. Rendered pages are capped at 3,200 pixels on the longest side; OCR quality on tiny text or poor scans is not guaranteed. Vision uses accurate recognition, language correction, and automatic language detection.

The inspector exposes progress, extracted page text, Copy All, Retry (resume), and Extract Again (reset derived text). Empty pages are successful results with no recognized text, while locked PDFs and missing/unreadable originals produce actionable errors. Neither OCR nor retry modifies originals or manual metadata. Completed text remains queryable after an extraction error. A document moved to Trash during an in-flight request stays paused even if that request fails; Restore resumes unfinished work.

## Next milestone

Milestone 4 adds incremental full-text indexing, paginated metadata fetches, and stronger search performance and presentation. Milestone 5 adds on-device intelligence with a deterministic fallback. Keep the text-extraction service and its durable queue independent of AI availability.

Before cloud implementation, write a separate design covering private/shared CloudKit zones, CKShare membership, CKAsset originals, record ownership, conflicts, tombstones, asset verification, cache pins, and transfer recovery. SwiftData automatic CloudKit integration alone is not a household-sharing implementation. The local unique attributes and name-based memberships will need deliberate migration; sync remains disabled rather than being implied by the data model.
