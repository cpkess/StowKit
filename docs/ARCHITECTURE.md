# StowKit architecture

## Current scope

Milestone 4 adds a local SQLite FTS5 index, ranked search, highlighted snippets, and bounded library loading to the native archive and OCR pipeline. Manual organization remains available throughout processing. AI classification, CloudKit, and household sharing remain unimplemented. All processing stays on this Mac.

## Project structure

- `App/LibraryStore.swift`: observable presentation state, navigation, a sequential import queue, persistent metadata edits, and native drop-provider delivery.
- `App/StowKitApp.swift`: one shared library window, search commands, and minimal Settings.
- `Models/Document.swift`: Sendable value snapshots, navigation, and collection definitions. SwiftUI does not own SwiftData models or file-storage decisions.
- `Persistence/ArchiveSchema.swift`: frozen V1 document, collection, and archive models plus the migration-plan entry point. `ProcessingSchema.swift` adds V2 job and page-text tables through a lightweight migration; V1 document fields remain unchanged. `SearchSchema.swift` adds V3 append-only index receipts and a migration-maintenance marker; V2 page and job fields also remain unchanged.
- `Persistence/ArchiveRepository.swift`: explicit metadata transactions. Autosave is disabled; failed saves roll back and are reported. Existing records are checked before insertion to avoid SwiftData unique-attribute upserts silently changing documents.
- `Services/DocumentStorageManager.swift`: actor-isolated file coordination, chunked copying/hashing, validation, recovery receipts, promotion, and external working copies.
- `Services/DocumentImporter.swift`: joins file and metadata commits and reports duplicates, including documents in Trash.
- `Services/ThumbnailService.swift`: background ImageIO/Core Graphics rendering, small cached thumbnails, and downsampled image previews.
- `Persistence/ArchiveRepository+Processing.swift`: durable job transitions, migration backfill, per-page checkpoint transactions, and retry/reset operations.
- `Services/DocumentProcessor.swift`: one-job-at-a-time orchestration with cancellation, per-job failure isolation, and Trash-aware pausing.
- `Services/OCRService.swift`: actor-confined PDF parsing, rasterization, and Vision requests behind `DocumentTextExtractor`.
- `Services/TextSearchService.swift`: background model actor for bounded source reads, processing migration recovery, incremental index synchronization, search, fallback browsing, and extracted-text inspection.
- `Services/FullTextIndex.swift`: system SQLite FTS5 connection, transactions, weighted ranking, scoped queries, snippets, and rebuildable cache schema. No package dependency.
- `Features/Library`: sidebar, import picker/drop target, list, thumbnails, reports, search, custom collections, and context actions.
- `Features/DocumentViewer`: persistent editable inspector, PDFKit page navigation, image previews, Quick Look, and Trash/Restore controls.
- `StowKitTests`: hosted XCTest tests using temporary roots and generated fixtures. Tests exercise the production services, not parallel mock implementations.

## Import transaction and recovery

1. Start security-scoped access to the selected source and coordinate a read. Reject unsupported extensions, directories, empty files, and bytes that do not match a supported file type. Locked PDFs are allowed even when no thumbnail can be rendered.
2. Stream the source into an app-owned staging directory in 1 MiB chunks, computing SHA-256 over exactly the bytes written. Synchronize the staged file. Compare source size/modification time before and after copying to detect concurrent changes.
3. Publish a JSON receipt atomically, containing the UUID, original filename, content type, hash, size, import time, and generated relative path. The receipt contains no extracted document text.
4. Look up the content hash in SwiftData, including Trash. If a duplicate exists, verify its archived original before discarding the staging copy; preserve the existing metadata. If the existing original cannot be verified, retain the new recovery copy and report a failure rather than claim safe deduplication.
5. Verify the staged hash and atomically rename into `Originals/<UUID prefix>/<UUID>.<extension>` on the same filesystem. Mark the original read-only.
6. Save the SwiftData document, queued processing job, and search-change receipt in one transaction. Remove the receipt only after the metadata transaction succeeds. Failure to clean a committed receipt is harmless: next launch deduplicates it.

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

The library initially fetches only 50 result documents from SwiftData. Load More increases the requested window by 50; a fresh query of that window avoids duplicate/skipped rows when edits change its order. Changing search/scope/sort resets the window. Only loaded documents and the active job have UI processing snapshots. Counts use database aggregates. A duplicate report can select a document outside the loaded window through a separate single-document snapshot.

Normal launch reads pending import receipts, interrupted jobs, and pending index receipts; it does not enumerate the full library or open originals. A one-time V3 migration backfills missing processing jobs in batches of 256 and persists a completion marker. Initial index creation/rebuilding reads metadata in batches of 64 and joins saved page text. These operations run off the main actor. The UI remains responsive, but first-build search waits for backfill to finish. Text for a batch (including a very long individual document) is materialized for indexing; text is never carried into list snapshots.

The 50,000-document benchmark measures the actual SQLite index with synthetic metadata and extracted text. It does not measure a 50,000-record SwiftData migration, total application launch, OCR throughput, or UI memory. See VALIDATION.md for measured timings and outstanding checks.

## Full-text index and recovery

SwiftData is authoritative. Import, metadata edits, processing transitions, saved pages, and extraction resets append UUID-addressed change receipts in the same save as the source changes. The background actor reads up to 256 receipts, coalesces document IDs, reads fresh source snapshots/page text, and commits a SQLite transaction. Only after that commit does it delete those exact receipts in SwiftData. A crash between commits replays the same updates. Concurrent edits append different receipt IDs and survive acknowledgement of earlier changes. Search always reads its visible document metadata fresh from SwiftData.

The SQLite cache lives at `Search/Search.sqlite`, with WAL and FULL synchronous commits. It stores an archive identity, cache format, and completed-build marker. Interrupted initial builds safely repeat bounded backfill; changes made during backfill replay afterward. Missing caches rebuild automatically. `SQLITE_CORRUPT`/`SQLITE_NOTADB` encountered while opening cause only the search cache and its sidecars to be recreated. Busy, permission, and disk errors are reported rather than interpreted as corruption. Settings can rebuild the index; browsing falls back to bounded SwiftData fetches if index access fails. A failure discovered later during a query is reported for explicit rebuilding. The collection fallback filters bounded SwiftData batches in memory: SQL predicates on the frozen transformable collection array can crash the framework. Only this error fallback scans active metadata to count collection membership; normal collection queries use indexed SQLite membership rows. Original files and saved OCR text are never deleted by index recovery.

The [system SQLite FTS5 engine](https://www.sqlite.org/fts5.html) indexes title, correspondent, remaining metadata, and combined page text with BM25 weights 10/5/2/1. Metadata includes collections, tags, entities, filename, and readable/numeric document dates. Unicode tokenization ignores case and diacritics. Unquoted words become ANDed literal prefixes; quoted groups become exact token phrases. Punctuation separates words, and query operators are treated as literal input. Punctuation-only input yields no matches. This is word search, not arbitrary mid-word substring or semantic search.

Active views exclude Trash; Inbox also includes failed extraction. SQL applies Favorites and collection filters before counting/ranking. Search orders by relevance, then import date and UUID; browsing uses import date or case-insensitive title with UUID tie-breaking. Full-text matches drive the count join explicitly to prevent SQLite from repeating MATCH for every archive row. Snippets are generated only after selecting the result window. SwiftUI renders plain text with bold match spans, never HTML.

Queries are debounced by 150 ms. Cancellation checks bound work between indexing batches; query generations discard stale responses after a new query or metadata edit. SQLite statements already executing are allowed to finish on the background actor. Completing extraction refreshes the current query, and journal replay keeps committed partial text recoverable after interruption.

## Processing pipeline

V2 adds a unique job per document and separate page-text records. Successful imports create the job atomically with metadata. On launch, documents migrated from V1 receive missing jobs; interrupted extraction/saving states return to queued with their checkpoints intact. Jobs in Trash pause, and failed jobs wait for explicit retry. This startup step reads metadata only.

A job proceeds through queued → extracting text → saving text (per page) → complete. Errors retain the failed stage, message, attempt count, and any completed pages. Page text, its extraction method, and the next-page checkpoint save in one transaction. Resuming never skips a page whose text was not committed. The worker processes one document at a time while the importer and UI remain available. A persistence error stops the worker and surfaces a restart message rather than spinning on failed saves.

PDF pages with enough plausible embedded text use PDFKit text directly. Sparse or broken text layers trigger rasterization and Vision OCR. Each page is considered separately, supporting mixed digital/scanned PDFs. The initial heuristic is intentionally simple: a plausible but incomplete text layer can still miss image-only content on the same page. Images use ImageIO orientation correction and bounded downsampling. PDF rasterization respects crop boxes and rotation. Rendered pages are capped at 3,200 pixels on the longest side; OCR quality on tiny text or poor scans is not guaranteed. Vision uses accurate recognition, language correction, and automatic language detection.

The inspector exposes progress, extracted page text, Copy All, Retry (resume), and Extract Again (reset derived text). Empty pages are successful results with no recognized text, while locked PDFs and missing/unreadable originals produce actionable errors. Neither OCR nor retry modifies originals or manual metadata. Completed text remains queryable after an extraction error. A document moved to Trash during an in-flight request stays paused even if that request fails; Restore resumes unfinished work.

## Next milestone

Milestone 5 adds on-device intelligence with a deterministic fallback. Keep the text-extraction service and its durable queue independent of AI availability.

Before cloud implementation, write a separate design covering private/shared CloudKit zones, CKShare membership, CKAsset originals, record ownership, conflicts, tombstones, asset verification, cache pins, and transfer recovery. SwiftData automatic CloudKit integration alone is not a household-sharing implementation. The local unique attributes and name-based memberships will need deliberate migration; sync remains disabled rather than being implied by the data model.
