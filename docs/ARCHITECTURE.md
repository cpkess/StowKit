# StowKit architecture

## Current scope

Milestone 2 is a native manual archive. The three-pane shell now uses real imported files and persistent metadata. OCR, AI, full-text indexing, CloudKit, and household sharing remain unimplemented. All processing stays on this Mac.

## Project structure

- `App/LibraryStore.swift`: observable presentation state, navigation, a sequential import queue, persistent metadata edits, and native drop-provider delivery.
- `App/StowKitApp.swift`: one shared library window, search commands, and minimal Settings.
- `Models/Document.swift`: Sendable value snapshots, navigation, and collection definitions. SwiftUI does not own SwiftData models or file-storage decisions.
- `Persistence/ArchiveSchema.swift`: versioned SwiftData document, collection, and archive models plus the migration-plan entry point. Preserve this schema version once released; add new versions for future changes.
- `Persistence/ArchiveRepository.swift`: explicit metadata transactions. Autosave is disabled; failed saves roll back and are reported. Existing records are checked before insertion to avoid SwiftData unique-attribute upserts silently changing documents.
- `Services/DocumentStorageManager.swift`: actor-isolated file coordination, chunked copying/hashing, validation, recovery receipts, promotion, and external working copies.
- `Services/DocumentImporter.swift`: joins file and metadata commits and reports duplicates, including documents in Trash.
- `Services/ThumbnailService.swift`: background ImageIO/Core Graphics rendering, small cached thumbnails, and downsampled image previews.
- `Features/Library`: sidebar, import picker/drop target, list, thumbnails, reports, search, custom collections, and context actions.
- `Features/DocumentViewer`: persistent editable inspector, PDFKit page navigation, image previews, Quick Look, and Trash/Restore controls.
- `StowKitTests`: hosted XCTest tests using temporary roots and generated fixtures. Tests exercise the production services, not parallel mock implementations.

## Import transaction and recovery

1. Start security-scoped access to the selected source and coordinate a read. Reject unsupported extensions, directories, empty files, and bytes that do not match a supported file type. Locked PDFs are allowed even when no thumbnail can be rendered.
2. Stream the source into an app-owned staging directory in 1 MiB chunks, computing SHA-256 over exactly the bytes written. Synchronize the staged file. Compare source size/modification time before and after copying to detect concurrent changes.
3. Publish a JSON receipt atomically, containing the UUID, original filename, content type, hash, size, import time, and generated relative path. The receipt contains no extracted document text.
4. Look up the content hash in SwiftData, including Trash. If a duplicate exists, verify its archived original before discarding the staging copy; preserve the existing metadata. If the existing original cannot be verified, retain the new recovery copy and report a failure rather than claim safe deduplication.
5. Verify the staged hash and atomically rename into `Originals/<UUID prefix>/<UUID>.<extension>` on the same filesystem. Mark the original read-only.
6. Save the SwiftData record. Remove the receipt only after the metadata transaction succeeds. Failure to clean a committed receipt is harmless: next launch deduplicates it.

At launch, inspect the small Staging directory rather than scan all originals. Resume receipts left before promotion, after promotion, or after database commit. Recheck hashes and identity. Corrupt recovery manifests are retained and reported while valid pending imports continue. Incomplete streaming copies without a receipt are discarded; the source is untouched. Files still waiting in the in-memory import queue, or interrupted before a receipt was published, must be selected again after an unexpected quit. A durable, user-manageable processing queue belongs to Milestone 3.

This provides process-interruption recovery; it is not a promise against disk failure or loss of the entire Mac. File and metadata storage are independent, so the receipt bridges their transaction boundary. No automatic orphan-original deletion or storage eviction is implemented.

## Metadata and ownership

Each document stores its UUID, stable archive UUID, immutable source identity, file size/type/hash, and relative file path separately from editable metadata. Collections are many-to-many name memberships; default and custom collection definitions persist separately. Tags and entities currently use editable comma-separated text. Normalize them into dedicated records when entity relations and renaming require it, using a schema migration.

The current library uses one local household archive identity. It is not a CloudKit zone or authentication identity. Metadata edits and Trash transitions save synchronously as small SwiftData transactions on the main actor. Large file copying, hashing, image decoding/downsampling, and thumbnail generation run on service actors. PDF loading occurs in a detached task, with presentation handled by PDFKit.

No automatic document understanding is implied: new records need manual review, titles come from filenames, and the initial document date is the import date until edited. Importing does not extract dates or amounts.

## Deletion and original protection

Trash is a reversible metadata timestamp. It hides documents from active navigation and search while leaving original paths, thumbnails, IDs, hashes, and metadata intact. Restore clears the timestamp. There is no automatic purge or permanent deletion in this milestone. Deduplication includes Trash.

The inline viewer reads archived originals. External Open creates a separate writable temporary copy with the original filename, so Preview or another application cannot accidentally save over the archive. Edits to working copies require an explicit future reimport; they are never synchronized back implicitly. Temporary copies are not a durable document location.

## Performance boundary

List thumbnails are requested lazily and cached by immutable document UUID. Image previews are capped at 2,048 pixels on their longest side. Hashing and file copies use bounded buffers. One import batch continues after individual errors; additional batches append to the running queue.

This milestone loads metadata snapshots and filters them in memory. It does not read original contents at launch, but it does not yet meet a validated 50,000-document search/launch target. Introduce paged fetches and an incremental full-text index in Milestone 4, before claiming production-scale search. Do not place OCR text into an eagerly loaded UI snapshot. No full-archive performance benchmark has been run.

## Next milestone

Milestone 3 adds a persistent processing-job queue, PDF embedded-text extraction, asynchronous Vision OCR for scanned pages/images, retryable stage states, and recovery after quitting during processing. Keep an imported document accessible even when OCR fails. Milestone 4 then adds incremental full-text indexing; Milestone 5 adds on-device intelligence with a deterministic fallback.

Before cloud implementation, write a separate design covering private/shared CloudKit zones, CKShare membership, CKAsset originals, record ownership, conflicts, tombstones, asset verification, cache pins, and transfer recovery. SwiftData automatic CloudKit integration alone is not a household-sharing implementation. The local unique attributes and name-based memberships will need deliberate migration; sync remains disabled rather than being implied by the data model.
