# StowKit — working notes for Claude Code

Native, local-first macOS household document archive. Swift 5 / SwiftUI / SwiftData,
one package dependency (Sparkle, the owner's choice for automatic updates, 2026-09-21). Built entirely by Codex through Milestone 6;
Claude Code took over on 2026-09-20.

Product north star: `docs/PRODUCT_BRIEF.md` (the owner's original spec — what StowKit is
*meant* to be). What is actually built and proven: `README.md` and `docs/VALIDATION.md`.
When the two disagree, VALIDATION.md wins.

## Build, test, run

```bash
xcodebuild -project StowKit.xcodeproj -scheme StowKit -configuration Debug -derivedDataPath /tmp/StowKitDerived build
```

```bash
xcodebuild -project StowKit.xcodeproj -scheme StowKit -configuration Debug -derivedDataPath /tmp/StowKitDerived -destination 'platform=macOS' test
```

- Requires real Xcode (26/27). SwiftData and Observation macros **cannot** expand inside a
  restricted nested sandbox — builds need escalated/unsandboxed execution. If a build fails
  with macro errors, that is the sandbox, not the code.
- Default build is ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`), sandboxed, no iCloud
  container, no team required. Keep it that way: a contributor with no Apple account must
  still be able to clone and run.
- Tests are hosted XCTest against the real services — no mock parallel implementations.
  They create isolated temp archives; they never touch the user's real library.
- Deployment target macOS 14.0. Current version 1.4.0, build 10 (released 2026-09-21). The app icon is
  drawn by `scripts/make-icon.swift` into `StowKit/Assets.xcassets`; edit the script, not the PNGs.

## Architecture in one pass

Layering is strict and deliberate — do not blur it:

- `App/` — `LibraryStore` (`@MainActor @Observable`) holds all presentation state, the
  sequential import queue, and cloud UI state. `StowKitApp` is one window + commands.
- `Models/` — `Sendable` value snapshots (`HouseholdDocument`, `LibraryCollection`).
  **SwiftUI never owns SwiftData model objects or file-storage decisions.**
- `Persistence/` — `ArchiveRepository` (`@MainActor`, small metadata transactions only,
  `autosaveEnabled = false`, explicit save/rollback) plus `+Processing`, `+Intelligence`,
  `+Sync`, `+SyncRecovery`, `+Cloud*` extensions. Versioned schemas V1–V8 in
  `*Schema.swift` with a migration plan. V9 (1.5) gave the document record its own class,
  `ArchiveSchemaV9.DocumentRecord`; `ArchiveSchemaV1.DocumentRecord` remains only for old versions and
  migration tests.
- `Services/` — actors for anything expensive: `DocumentStorageManager` (file coordination,
  chunked copy/hash, staging/promotion), `DocumentImporter`, `DocumentProcessor` (OCR
  orchestration), `DocumentIntelligenceProcessor`, `OCRService`, `TextSearchService`,
  `FullTextIndex` (system SQLite FTS5 — no package), `ThumbnailService`.
- `Intelligence/` — provider protocol + Apple Foundation Models provider + deterministic
  rule-based fallback. **AI is never required** for import, OCR, search, or manual filing.
- `Cloud/` + `Sync/` — opt-in CloudKit transport, coordinator, wire models.
- `Features/` — SwiftUI views only.

Files stay small (mostly <300 lines); `ArchiveRepository` is split across extensions rather
than growing. Match that when adding code.

## Conventions Codex established

- **Preserve originals exactly.** Originals are read-only, opaque-ID (`Originals/AB/UUID.pdf`),
  never foldered by collection name. Nothing derived may mutate them. OCR failure must never
  remove or alter a document.
- **All expensive work is async, durable, and resumable.** Page-level checkpoints; interrupted
  extraction resumes after the last saved page. Trash pauses jobs; Restore resumes them.
- **Explicit transactions.** Check for existing records before insert — SwiftData's
  unique-attribute upsert will silently overwrite metadata otherwise. Failed saves roll back
  and surface to the user.
- **Never silently discard user edits.** Manually edited fields (including ones the user
  *cleared*) are protected from AI suggestions and from remote overwrite.
- Comments explain *why*, not *what*, and are rare. Dense, idiomatic Swift. No custom design
  system — Apple system typography, materials, sidebar/toolbar conventions.
- Prefer native Apple frameworks; add a dependency only for a real capability gap. So far: Sparkle 2
  (a sandboxed app cannot replace itself in /Applications without its installer service).

## Documentation discipline — the most important convention

Codex kept a hard line between **implemented** and **verified**, and the docs are written to
never overclaim. `docs/VALIDATION.md` records, per date: what was run, what passed, what
failed, and explicitly what the result does *not* establish. Release notes list unverified
limitations up front.

Keep doing this. When you finish work:

1. Record evidence in `docs/VALIDATION.md` (command, result, and the boundary of the claim).
2. Update `README.md` status language only to what you actually observed.
3. Do not call something "ready", "working", or "complete" on the strength of a fake-transport
   test or a code reading. Say which test ran on which machine with which account.

## iCloud / household sharing

Opt-in only; SwiftData's automatic CloudKit integration is `.none` — sync is hand-rolled
through `CloudSyncCoordinator` + `ArchiveCloudTransport`.

- Cloud document UUID = deterministic hash of archive UUID + original SHA-256, so concurrent
  identical imports converge on one record while each Mac keeps its local UUID and path.
- Originals upload as 8 MiB immutable chunks + manifest; metadata publishes only after an
  independent full download verifies the bytes. 64 GiB file ceiling.
- Change feeds use `desiredKeys = [metadata, operationID, textHead]` so browsing and search
  never pull CKAssets. Local files are **never** evicted automatically (that's unbuilt work).
- Only the exact acknowledged operation UUID is cleared, so edits made during a request survive.
- Foreground sync only: on connect, on local edit, and a 60-second timer. No push subscriptions.

Provisioned builds need `Config/iCloud.local.xcconfig` (gitignored; copy from
`iCloud.xcconfig.example`). Team Gamergrams LLC `WZJ4ZPRH72`, container
`iCloud.com.stowkit.app`. Development and Production archives are separate — an existing
binding reports a mismatch rather than switching environments.

**Status: private same-account sync passes a live smoke test in both Development and
Production. Cross-account household sharing has never been tested.** See the acceptance
checklist in `docs/ICLOUD_SETUP.md` — it is the definition of done for sharing.

### Live verification runner

Excluded from normal builds behind `STOWKIT_LIVE_VERIFICATION` (plus
`STOWKIT_PRODUCTION_VERIFICATION` to target Production). It builds a special app that runs at
launch, uses only generated fictional bytes in an isolated archive, and prints
`STOWKIT_LIVE: SUCCESS`/`FAIL`. Exact commands in `docs/ICLOUD_SETUP.md`. **Never distribute
that build** — `scripts/build-distribution.sh` clears both flags.

## Release pipeline

```bash
scripts/build-distribution.sh WZJ4ZPRH72 Config/iCloud.local.xcconfig build/<new-dir> [PROFILE_UUID]
```

Archives + exports Developer ID, hardened runtime, universal, then refuses the export if the
entitlement or Info.plist is not `Production`, if the profile is device-restricted, or if
`get-task-allow` is set. Then:

```bash
scripts/notarize.sh /path/to/StowKit.app <keychain-profile>
scripts/package-dmg.sh /path/to/StowKit.app <version> build/releases
scripts/notarize.sh build/releases/StowKit-<version>.dmg <keychain-profile>
```

Then write and sign the Sparkle appcast, and attach it to the GitHub release **as `appcast.xml`**
alongside the DMG and checksum: the app's feed is `releases/latest/download/appcast.xml`, so a
release without one breaks updates for everyone.

```bash
scripts/make-appcast.sh build/releases/StowKit-<version>.dmg <version> <build>
```

The EdDSA private key is in the owner's login Keychain, account `stowkit` (`sign_update --account
stowkit`); the first use from a new `sign_update` binary raises a Keychain prompt only the owner can approve. Never commit it or print it. The public key is in `Config/StowKitCloud-Info.plist`.

Sign the DMG before notarizing it. The notarytool keychain profile in use is named `AbleKit`.
**Regenerate the `.sha256` sidecar after stapling** (`shasum -a 256 X.dmg > X.dmg.sha256`):
`package-dmg.sh` writes it before signing and stapling change the file, so as written it is
stale and every downloader's check fails.
`build/` is gitignored. Full walkthrough: `docs/DISTRIBUTION.md`.

Gotcha Codex hit: command-line `STOWKIT_CLOUD_ENVIRONMENT=Production` overrides alone left the
local xcconfig's `Development` value baked into the signed entitlements. The script now
generates a `Distribution.xcconfig` that `#include`s the local one and forces Production in
both places. Don't "simplify" that away.

## Known issues / traps

- **Never put the document preview back in a `VSplitView`.** The launch freeze of 2026-09-20 was
  our bug: the split view rebuilt the preview pane ~20 times a second (302 rebuilds in 15 s
  while its parent redrew 3 times), and with `PDFView` each rebuild made a new viewer running
  PDFKit's Vision analysis — 454 in 15 s, 521 threads, 3.5 GB, app hung. It reproduced on a
  healthy Mac. `DocumentDetailView` now uses a `VStack`, and the preview renders with
  `CGPDFDocument` rather than `PDFView`. Don't reintroduce either.
- **A restart making a symptom disappear is not a root cause.** That freeze was first written
  up as a transient macOS state because it vanished after a restart; running the old code
  again proved otherwise. Reproduce with the old code before concluding anything is external.
- **To count view rebuilds, launch with `open --stderr <file>` and `NSLog` probes.** The
  sandboxed app's `NSLog` and `Logger` output did not show up in `log show`, which made two
  rounds of probes look like they never ran. XCTest can't catch this: its host renders no
  library view.
- **`e5rt` log lines mean macOS text recognition is degraded.** They name *system* model bundles
  under `/System/Library/PrivateFrameworks/TextRecognition.framework/Resources/`, not any
  StowKit cache (no such cache exists). They were present during the first freeze and may
  have worsened it, but the freeze reproduces without them. The single-threaded test suite
  passes through them, so green tests do not clear them. `PDFView.setDocumentAnalysisEnabled:`
  exists at runtime but is not public SDK API — ask before using it.
- **First Vision call costs ~46s cold, ~0.08s warm**, measured in a standalone tool with no
  StowKit code — it is Apple's cost, not ours. The warm state is shared across processes but
  expires after idle, so this *recurs*; it is not a one-time first-launch charge. Extraction
  already shows a spinner and `· 1 of N`, so nothing looks frozen; `ProcessingInspector` adds
  a caption after six seconds explaining the wait. Don't try to work around the delay itself,
  and don't pre-warm Vision at launch — that spends CPU for every user who never imports a scan.
- Schema V7→V8 exists only because macOS 27 exposed an inherited-property collision on a
  reserved `hash` property (renamed to `sourceHash`). Both V7 and V8 stay in the migration
  plan because a dev build already opened V7. Don't prune migration versions.
- A `#Predicate` over the frozen collection array crashed reproducibly; the fallback now
  filters bounded value snapshots instead. Don't reintroduce predicates over that array.
- **Collection evidence is compared by words, not characters.** The model reflows its quotes
  (spacing, punctuation, words joined across lines); an exact match rejected 3 of 4 correct
  collections on the owner's documents. See `UnderstandingPolicy.evidenceSupported`.
- **Check for a second running instance** (`pgrep -lf StowKit.app`) after quitting test builds:
  `osascript quit` once stopped only one of two, leaving both on the same archive and iCloud.
- Confidence-based filing is a conservative heuristic, not a calibrated probability. Analysis
  reads at most 4,000 UTF-8 bytes from the first eight pages — do not describe it as
  whole-document understanding.
- **Permanent deletion uses tombstones — never delete a `StowMetadata` record.** A tombstone keeps only
  `id`, `contentHash`, and `deleted`; it stops a Mac that missed the deletion from recreating the
  document. Content records are deleted only after iCloud accepts the tombstone. A deletion beats a
  concurrent edit (mutation-tested: without that branch the document comes back). Verified against the
  fake transport only, not across two live Macs.
- **One archive, in iCloud (owner's direction, 2026-09-21).** There is no archive picker. At launch
  `ArchiveResolver` decides: connect, upload (asks if the archive has documents), join the account's
  single zone (only when this Mac's archive is empty), or stay local with a stated reason — never a
  silent merge or a guess between zones. `pauseCloud()` records an *owner's* pause
  (`StowKitCloudPausedByOwner`); nothing else may call it. The account-change observer used to call it,
  which silently turned iCloud off; it now stops the transport and reconnects.
- **An iCloud copy of this Mac's own archive is a duplicate.** 1.x could open one into
  `CloudArchives/<account>/<archive ID>`. `CloudSetup.activeRoot` ignores it, and `ArchiveCopies`
  deletes it only when it has no unsent edits and every document's bytes exist in the real archive.
- **The owner's own iCloud archive is zone `StowKit-4017FFBA-…`** — never delete it. Two fictional
  zones from Codex's September smoke tests (`462F692A-…`, `72CAADA2-…`) were deleted
  on 2026-09-21 by `ArchiveMaintenance` (see `docs/ICLOUD_SETUP.md`); only the owner's zone remains. Never pick zones by a short name: the
  1.1.0 picker listed the owner's archive as "iCloud Archive 4017".
- **1.5 added synced fields (`documentType`, `amount`, `dueDate`, `expiresAt`) and relaxed validation:**
  missing V9 fields are allowed, unknown fields are carried along. Macs on ≤1.4 still stall on them.
- **Adding a synced document field breaks older Macs.** `validateIncoming` rejects any field one side
  lacks (both directions), and a different `formatVersion` is rejected too. Prefer deriving facts
  from existing fields (as `carriesOnlyImportDetails` does); if a field is unavoidable, it needs a
  compatibility plan and a note that every Mac must update.
- **Tests share the app's settings.** The hosted test runner uses the app's own container, so
  `UserDefaults.standard` in a test is the owner's real settings: `InboxFolderTests` once erased the
  owner's inbox folder that way. Inject a throwaway `UserDefaults(suiteName:)` instead.
- **The project file is hand-written.** Settings Xcode templates add by default can be missing:
  `LD_RUNPATH_SEARCH_PATHS` was, and the first Sparkle build crashed at launch. Launch the signed
  build before calling anything done.
- **Two targets now: the app and `StowKitShare`** (Share extension). Anything setting Info.plist or
  entitlements through an xcconfig must pick per `$(TARGET_NAME)`, as `build-distribution.sh` and
  `iCloud.tests.xcconfig` do, or the extension is signed as the app. Versions are set in both targets'
  configs; bump them together. `Shared/ShareDropbox.swift` is compiled into both. Tests must never
  write to `ShareDropbox.folder`: the running app imports whatever lands there.
- **Stale extension registrations hide Share → StowKit.** Xcode registers the archive-intermediate and
  Debug copies too, and `pluginkit` may choose a development-signed one that the Share menu then
  omits. Check `pluginkit -m -v -i com.stowkit.app.share`; remove extras with `pluginkit -r <path>`.
  The App Group folder is readable from the shell but not writable, so never leave test files in it.
- Token-expiry full scans retain absent local records — that is *not* authoritative deletion
  reconciliation, and shouldn't be described as such.

## Open work

**Direction (owner, 2026-09-21):** replace paperless-ngx. iCloud holds the one archive; the Mac
uploads, reviews and searches, and acts as an edge processor for files a phone drops into an inbox.
Phone input: an iCloud Drive "StowKit Inbox" folder first, an iOS companion later. Build order:
(a) one archive — done, see VALIDATION; (b) documents from iCloud that were never understood get suggestions on
the Mac that has their text — done, grace-period rule, no claims yet; (c) the iCloud Drive
inbox — done (`InboxFolder`, Settings → Inbox Folder); (d) paperless parity: filing rules — done, per Mac (`FilingRule`, `ArchiveRepository+Rules`); still to do: saved views, custom fields, bulk edit, export. Rule sync is safe to add once every Mac runs ≥1.3, which skips unknown record types into CloudState instead of stalling.

Earlier list, roughly in the order Codex intended:

1. **Household sharing acceptance** — two iCloud accounts, two Macs, against the checklist in
   `docs/ICLOUD_SETUP.md`. This is the blocking gate for calling iCloud ready.
2. **Optimized storage** (brief §21) — designed in `docs/STORAGE_ARCHITECTURE.md`. Steps 1
   (disk accounting, `DocumentStorageManager.usage()`) and 2 (pins plus manual "Remove
   Download" through the single guarded `evictOriginal`) are built, tested against the fake
   transport only. Nothing evicts automatically. Hold step 3 (V9 `lastAccessedAt` and an
   automatic policy) until manual eviction has been used on a real archive.
3. Cloud thumbnails; extractor-version negotiation.
4. Push subscriptions / background sync (foreground-only today).
5. Tombstone-based permanent deletion is built; still missing are authoritative reconciliation after a
   token reset, and live two-Mac verification.
6. Not yet started from the brief: entities, related documents, reminders, semantic search,
   Spotlight, App Intents, iOS companion. (Share extension: built, 1.4.0.)

## Working with the owner

- Ships through GitHub `cpkess/StowKit`, commits straight to `main`, and cuts tagged
  prereleases with `gh release create`. Ask before committing, pushing, or releasing.
- Values verified claims over optimistic ones. Reporting a failure accurately is worth more
  here than making a green checkmark appear.
