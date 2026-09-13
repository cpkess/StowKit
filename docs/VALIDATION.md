# Milestone 3 validation

Validated on September 13, 2026 with Xcode 26.3 / Swift 6.2.4 on Apple Silicon.

## Automated checks

The final run passed all 30 tests with zero failures (17 archive tests and 13 processing tests). Run the shared StowKit scheme's XCTest target using the README command. Tests create and remove their own temporary archives; they do not import personal documents.

Coverage:

- PDF byte preservation, SHA-256, file size, and reopening a fresh SwiftData repository.
- Metadata, Favorites, tags, entities, collection membership, custom collections, and archive identity persistence.
- Case-insensitive collection uniqueness.
- Trash and restore persistence.
- Renamed duplicates and duplicates in Trash preserve edited metadata and store one original.
- Distinct contents with the same filename remain separate records.
- Concurrent identical imports commit one record.
- A multi-megabyte PNG crosses streaming-copy chunk boundaries without changing bytes.
- JPEG, PNG, and HEIC import and thumbnail generation; downsampled image preview.
- PDF thumbnail generation and editing a working copy without changing the archived original.
- Rejection of unsupported, empty, mismatched, and invalid inputs.
- Recovery before promotion, after promotion, and after metadata commit.
- A corrupted recovery receipt does not block valid pending imports.
- Missing originals do not cause a potentially needed duplicate recovery copy to be discarded.
- Incomplete copies without receipts are cleaned without touching their sources.
- Batches continue after failures and report duplicates separately.
- File-drop provider delivery for both native URL and data representations.
- Unsafe original paths are rejected.

## Processing checks

- Migration from a real V1 SwiftData store preserves documents, archive identity, custom collections, and original hashes; queued jobs are backfilled.
- Imports and exact duplicates produce one durable processing job.
- Real PDFKit extraction uses embedded text without changing original bytes.
- Real Vision OCR recognizes generated images and scanned PDF pages.
- A mixed PDF uses embedded text on one page and OCR on another; both are saved and searchable.
- Failed extraction keeps completed text; Retry resumes at the failed page without repeating the earlier page.
- Reopening a repository after a simulated interruption resumes the committed checkpoint.
- Cancellation requeues without falsely advancing progress.
- Trash pauses and Restore resumes; an in-flight OCR failure cannot override the paused state.
- A locked PDF fails with an actionable message and does not block the next job.
- Blank images complete with zero text; unavailable originals fail without deleting metadata.
- Search combines metadata and normalized text across pages, including diacritics; a fresh read observes Extract Again resets and subsequent reprocessing.
- The older batch test waits for background search completion before deleting its temporary archive, avoiding test-teardown I/O races.

## Native UI status for Milestone 3

The native UI smoke test could not run because the Mac was locked. Build, migration, repository, queue, search, and real OCR tests ran successfully without an unlocked desktop. No visual verification of the new progress, View Text, Copy All, or Retry controls is claimed yet.

When the desktop is available: launch the new build, import a scan and a mixed PDF, inspect View Text, search a word present only in OCR, and check Retry on a locked PDF. Quit/relaunch while a long PDF is processing and verify that the displayed checkpoint resumes. Use clearly marked fixtures rather than personal records.

## Prior Milestone 2 native smoke test

Using only clearly marked, generated test fixtures:

1. Launched into an empty persistent library.
2. Opened the native file picker and imported a two-page PDF.
3. Verified PDF rendering, thumbnail, Inbox count, and second-page navigation.
4. Edited the title and correspondent in the inspector.
5. Reimported the PDF and verified an “Already in archive” report referencing the edited title.
6. Used ⌘N and imported a PNG; verified its image preview and thumbnail.
7. Quit and relaunched the application. Both documents, original previews, edited title, and correspondent survived.
8. Moved both fixtures to Trash, restored the receipt, and verified it returned to Recent.
9. Moved the receipt back to Trash, leaving the active library empty. Both clearly labeled test fixtures remain recoverable in Trash.

Finder mouse dragging was not separately exercised end-to-end; the drop-provider path is covered in XCTest. No AI, cloud synchronization, real iCloud placeholders, disk-full fault injection, or large-archive load benchmark is claimed. OCR was validated in the Milestone 3 automated tests above, not in this earlier UI smoke test. The macOS 14 deployment target compiles against the installed SDK; runtime testing on macOS 14 hardware remains outstanding.

## Toolchain notes

SwiftData and Observation compiler macros require Xcode execution outside this environment's restricted nested sandbox. Approved Xcode builds succeed. Hosted test builds can emit Xcode's standard signed-test-framework stripping notices; App Intents metadata extraction is skipped because this milestone has no App Intents integration.

During the final run, Core Data emitted a model-checksum diagnostic while initializing versioned schemas. The migration and reopened-data assertions still passed. This diagnostic is recorded without assuming it is harmless or changing the frozen V1 schema to suppress it.
