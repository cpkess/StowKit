# Milestone 4 validation

Validated on September 13, 2026 with Xcode 26.3 / Swift 6.2.4 on Apple Silicon.

## Automated checks

The final run passed all 42 tests with zero failures (17 archive tests, 13 processing tests, and 12 search tests). Run the shared StowKit scheme's XCTest target using the README command. Tests create and remove their own temporary archives; they do not import personal documents.

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

## Search checks

- Weighted ranking prioritizes title matches; snippets contain highlight spans.
- Prefixes, accents, case, exact phrases, unmatched quotes, and punctuation behave as documented.
- Literal SQL/FTS-looking input cannot broaden results or execute SQL.
- AND terms match different metadata fields and different extracted pages.
- Title edits remove old matches; Favorites, custom collections, Inbox failure state, Trash, and Restore update incrementally.
- Extract Again removes stale OCR matches without changing metadata.
- Pending receipts replay after reopening; repeated rebuilds remain idempotent.
- An index commit followed by an unacknowledged receipt and newer edit preserves the latest source state.
- A corrupt cache is recreated from saved metadata/text.
- An index-path write failure preserves browsing; fixing the path and rebuilding restores search.
- Fallback browsing respects collection and Trash filters.
- Three pages cover 123 records without duplicate IDs; LibraryStore initially holds only 50 and Load More expands to 100.
- Rapid query changes discard stale results; a duplicate-report selection can resolve outside the first page.
- A real V2 store migrates to V3 without losing metadata, completed jobs, or saved page text. V1 migration also exercises the production background recovery path.

## Synthetic index benchmark

Run from the repository root:

```sh
xcrun swiftc -O StowKit/Models/Document.swift StowKit/Models/Search.swift StowKit/Services/FullTextIndex.swift scripts/search-benchmark.swift -o /tmp/stowkit-search-benchmark
/tmp/stowkit-search-benchmark 50000
```

This compiles the app's actual index implementation. It creates a temporary SQLite cache with 50,000 synthetic records and approximately 4.8 KB of extracted text per record, then removes it. Six queries (prefix, title, common multiword, phrase, unique, and no match) run five times; each includes exact result counts and up to 50 snippets. The deliberately repeated text makes common queries match much of the archive. No personal documents are accessed.

Measured on the development Apple Silicon Mac. The final run overlapped the Release build, so these are development-machine observations rather than isolated performance guarantees:

| Operation | Time |
| --- | ---: |
| Index 50,000 synthetic documents | 16.325 s |
| Reopen existing index | 1.493 ms |
| Search median, 30 queries | 49.949 ms |
| Search 95th percentile | 332.204 ms |
| Slowest search | 336.069 ms |
| First 50 metadata IDs | 292.091 ms |
| Archive count/size statistics | 4.763 ms |

The cache was 447.3 MB, including stored text and FTS postings. These are optimized index timings, excluding the 150 ms UI debounce, SwiftData snapshot fetching, thumbnails, and view rendering. Index reopening is not total application launch. A full 50,000-record SwiftData migration, OCR run, peak-memory profile, and interactive large-archive test remain unmeasured. Timings depend on hardware, document lengths, and match frequency.

The benchmark caught an expensive SQLite count plan that repeated MATCH per document. The final query makes FTS drive the join and generates snippets only for the selected window.

## Native UI status for Milestones 3 and 4

Native visual verification remains pending. Automatic approval review blocked UI inspection because the Mac had been confirmed locked and no unlock confirmation was received. Automated build, migration, repository, processing, full-text search, and real OCR tests ran successfully. No visual verification of progress, View Text, Copy All, Retry, snippets, or Load More is claimed.

When the desktop is available: import clearly marked scan/PDF fixtures, inspect extracted text, search an OCR-only phrase with ⌘K, verify highlighted snippets and scoped ⌘F, exercise Load More with a larger fixture library, and rebuild the index from Settings. Check metadata edits, Trash/Restore, and an existing duplicate outside the first page. Quit/relaunch during processing and confirm checkpoint recovery. Do not use personal records for the smoke test.

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

Finder mouse dragging was not separately exercised end-to-end; the drop-provider path is covered in XCTest. No AI, cloud synchronization, real iCloud placeholders, disk-full fault injection, or end-to-end large-archive UI benchmark is claimed. OCR was validated in the Milestone 3 automated tests above, not in this earlier UI smoke test. The macOS 14 deployment target compiles against the installed SDK; runtime testing on macOS 14 hardware remains outstanding.

## Toolchain notes

SwiftData and Observation compiler macros require Xcode execution outside this environment's restricted nested sandbox. Approved Xcode builds succeed. Hosted test builds can emit Xcode's standard signed-test-framework stripping notices; App Intents metadata extraction is skipped because this milestone has no App Intents integration.

During the test runs, Core Data emitted model-checksum and Array<String> materialization diagnostics while initializing/migrating versioned schemas. A fallback predicate on the frozen collection array caused a reproducible crash during development. That predicate was removed; the collection fallback now filters bounded value snapshots. The final migration, fallback, and reopened-data assertions passed. This diagnostic is recorded without assuming it is harmless or changing the frozen V1 schema to suppress it.
