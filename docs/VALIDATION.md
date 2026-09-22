# Validation

## 1.5.0 (11) release build

September 22, 2026, owner's Mac. `scripts/build-distribution.sh` (Developer ID, Production, profile
719e9bc1…) passed its entitlement and Info.plist checks; the app and then the signed DMG were notarized,
stapled, and accepted by Gatekeeper (`notarize.sh`, profile AbleKit). The `.sha256` sidecar was regenerated
after stapling and checks OK. The appcast was signed with the `stowkit` EdDSA key and its length matches the
DMG (6,111,379 bytes). The stapled app launched on the owner's archive with its five documents, and typing
"treasurer" then Clear Search logged no reentrancy warning (`grep -c reentrant` = 0).

**Not established.** An update from 1.4.0 through Sparkle to this version was not observed at release time;
the release notes' list of 1.5 features not yet used on a real archive still stands.

## NSTableView reentrancy warning: cause and fix (1.5.0)

September 22, 2026, on the owner's Mac (macOS 27, Debug build, real archive).

- **Cause: SwiftUI's `List`, not StowKit code.** Bisecting the library list down to a bare `List { ForEach
  { Text } }`, with no selection, row view, context menu, filter bar, sidebar extras, or animation, still
  logged it. A `ScrollView` + `LazyVStack` in its place did not. A standalone 40-line SwiftUI app (a
  `List` of five items filtered by a search, built with `swiftc`, no StowKit code) logged the same warning
  when its list grew from one row back to five. In that app: shrinking did not log it; growing back when
  the remaining row was the *first* one did not; appending rows (Load More) did not; inserting one row at
  the top did not; growing when rows are inserted above a row already shown did. `.id(items.count)`
  avoided it; `.id(search)` did not, because the id changed before the results arrived.
- **Fix:** `LibraryStore.listIdentity` changes in the same update that delivers a *different* query's
  results (search text, destination, filter, sort), and the list is `.id(listIdentity)`, so a new query
  gets a new table. Refreshes of the same query and Load More keep the table. Rows' search layout now
  follows the results on screen (`showingSearchResults`) rather than the search field, which also covers
  what the old `.id(search.isEmpty)` rebuild was for.
- **Checked on the real archive**, one action per fresh launch with `open --stderr`: typing "treasurer"
  then Clear Search: `grep -c reentrant` = 0 (it was 1 on every earlier run, including bisect builds);
  People & Things → Wood County Treasurer, then removing the chip: 0. The list came back to five rows,
  selection kept, no overlapping rows.
- **Tests:** full hosted suite, 184 tests, 0 failures (output saved and read).

**Not established.** Other ways a list can grow in place under the same query (a sync bringing several
documents that sort above a shown one) were not tried and could still log the warning once; the
standalone app suggests a single insert does not. This is a workaround for AppKit/SwiftUI behaviour, not
a change Apple has confirmed.

## 1.5.0 (11) signed test build on the owner's archive

September 22, 2026, with the owner's go-ahead (the V9 migration is one way). 1.4.0 was quit (no second
instance) and the signed 1.5.0 test build launched with `open --stderr`:

- **Migration**: the archive opened as V9 with its five documents, and the new Type, Amount, Due, and
  Expires fields, the Filter menu, Upcoming, Tags, and (after the next step) People & Things all appeared.
- **Facts from real text**: Suggest Again on the Wood County property tax receipt set its date to June 23,
  2025 (it had been the import day), type "Payment Confirmation", amount "$4,072.28" (the total including a
  $99.32 fee), and people & things "Wood County Treasurer, OH", "Christopher Kessler", "Autoagent.com". The
  title also changed ("Payment Confirmation for Real Estate"), as automatic titles may.
- **Filters**: clicking "Wood County Treasurer" in People & Things showed 1 of 1 documents with an
  "About:" chip and Save View; removing the chip restored all five.
- **A warning, reproduced**: "Application performed a reentrant operation in its NSTableView delegate. This
  warning will become an assert in the future." AppKit logs it once per launch, so each action was tested on a
  fresh launch: not on idle launch, not on applying a filter from the sidebar, but on removing the filter
  chip and, separately, on clearing a search. Both grow the list back while a document is selected. Search
  clearing predates 1.5, but whether 1.4.0 logged it is unknown: it can't open the migrated archive to check.

**Not established.** Export was not run on the real archive: its folder picker needs full-screen control,
and the approval timed out. No reminder was created, no paperless export imported, and multi-select, saved
views, and tag renaming were not exercised here. The reentrancy warning is resolved in the entry above.

## Reminders and Upcoming (unreleased)

September 21, 2026. A document with a due or expiry date shows "Due <date> · Add Reminder" (and the same
for Expires) in its details. Nothing is created until the owner clicks: then StowKit asks macOS for
Reminders access (first time only), adds a reminder to the default list for 9 AM that day, titled
"Due: <title>" or "Renew or replace: <title>", with sender and amount in the notes, and remembers it per Mac
so the row reads "Reminder added". A sidebar Upcoming entry shows documents overdue, or due or expiring
within 90 days. New: the `personal-information.calendars` entitlement and a Reminders usage string in both
builds.

`ReminderTests`, 2 tests, pass: the reminder's wording, notes, date, and 9 AM time, no expiry reminder
without an expiry date, and Upcoming including exactly the overdue, due-soon, and expiring-soon documents.
Full suite: 184 tests, 0 failures (output saved and read). Version is now 1.5.0 (11) in both targets.

**Not established.** No reminder has been created: that needs the owner's Reminders permission and writes
to their real Reminders, so no test does it. EventKit behavior in the sandboxed, signed app is unverified.

## People & things, and related documents (unreleased)

September 21, 2026. The existing, already-synced "People & things" field is now treated as a list, like
tags (comma- or semicolon-separated), so no sync format changed. The search index gained an `entities`
table (identity ":3", rebuilt from saved data). A People & Things sidebar section lists the most used with
counts, each with a kind (Person, Organization, Property, Vehicle, Product, Account, School, Pet, Other;
per Mac, a label and icon only) and Rename/Remove across the archive; the Filter menu has "About". The
details pane's Related list shows other documents outside Trash that share a person or thing, most shared
first. Suggestions now propose up to five names; each is kept only if its words appear together, in order,
in the text, and joins the owner's list unless the field is protected (editing it protects it). Names
need filing confidence. The field was already journaled as a manual field, so suggested names sync that way.
Rules, saved views, and entity kinds now share one JSON-in-a-checkpoint helper.

`EntityTests`, 4 tests, pass: names checked against the text (split lines allowed, order required,
invented dropped, duplicates merged), merging with protection and confidence, related documents (most
shared first, Trash and unrelated excluded), the About filter and facet counts, and entity rename with
protection and kinds surviving a reopen. Mutation check: with the name check accepting everything, the
first test fails. Full suite: 182 tests, 0 failures (output saved and read).

**Not established.** Not seen in the running app, and no model output with names observed on real
documents. Manual links between documents that share no name are not built.

## Multi-select editing (unreleased)

September 21, 2026. The document list takes ⌘- and ⇧-click; with several selected, the details pane is a
bulk editor: add to or remove from a collection, add or remove a tag, set sender, type, or date, mark
reviewed or needs review, favorite, Suggest Again, and Move to Trash (the Delete key trashes the whole
selection). Each change goes through `update` per document, so it is protected and synced exactly like a
single edit; unchanged documents aren't rewritten. `selection` is now "the one selected document" over a
`selectedIDs` set, and refreshing the list no longer collapses a multi-selection.

`BulkEditTests`, 3 tests, pass on a real `LibraryStore` with imported PDFs: a multi-selection survives
refreshes; one change applies to exactly the selected documents with the fields protected; an unchanged
document isn't rewritten; tags are added and removed; trashed and then deleted documents leave the
selection. Mutation check: without the multi-selection guard in `reconcileSelection`, the first test fails.
Full suite: 178 tests, 0 failures (output saved and read).

**Not established.** Not used in the running app yet; ⌘/⇧-click behavior is SwiftUI's `List` and was not
exercised by a test.

## Import from paperless-ngx (unreleased)

September 21, 2026. File → Import from paperless-ngx… reads a `document_exporter` folder (`manifest.json`,
and `*-manifest.json` files from `--split-manifest`), imports each original through the normal importer
(duplicates skipped by SHA-256), then applies its details through `update`, so each changed field is
protected from suggestions: title, created date, correspondent → sender, document type → Type, tags,
notes → summary, and custom fields whose names mention amount/total/price/cost, due, or expiry/renewal.
A type or tag matching a collection name files it there; the paperless inbox tag keeps it in Inbox,
otherwise it arrives reviewed. Paperless's `content` becomes the document's text and processing is
marked complete, unless StowKit had already started reading the file. A summary lists failures.

`PaperlessTests`, 4 tests, pass against a fictional export written in the documented format: field
mapping (including "USD3972.96" → "USD 3972.96"), split manifests, both date styles, and an end-to-end
import of a real PDF (details, collection match, text kept, protection, and a second import detected as a
duplicate). Mutation check: without the inbox-tag mapping, the end-to-end test fails. Full suite: 175
tests, 0 failures (one run, output saved and read).

**Not established.** Built from paperless-ngx's documented export format; no real paperless export has been
imported. Other custom fields, storage paths, owners and permissions, and archived (OCR'd PDF) versions
are ignored; the original file is what StowKit keeps.

## Tags, filters, and saved views (unreleased)

September 21, 2026. A Filter menu under the search field narrows any view by tag, sender, type, date
(last 30 days, this year, last year, or a year), due or expiring (overdue, due in 30 days, expiring in
90), or "not in a collection"; active filters show as removable chips and combine with the sidebar place
and search text. Save View… keeps place, search, and filters in a new Saved sidebar section (per Mac,
like rules). A Tags sidebar section lists the most used tags with counts; each can be renamed or removed
across the archive (outside Trash), as the owner's edit, so protected and synced. Tags are still stored
and synced as comma-separated text; only the search index treats them as items. The index gained
sender, type, date, due, and expiry columns and a `tags` table; its identity moved to ":2", so existing
indexes rebuild from saved data on first launch.

`FilterTests`, 4 tests, pass: every filter kind alone, filters combined with search and with a
collection, case-insensitive tags and senders, Trash excluded, facet counts, tag rename merging and
removal with protection, and saved views surviving a reopen. Mutation check: with the filter conditions
left out of the query, the filter test fails.

Full suite: **this entry was first committed saying "171 tests, 0 failures", which was wrong.** The run
that preceded the commit reported 1 failure (1 unexpected); the commit command didn't stop on it and its
output wasn't kept. Four reruns, with output saved: three had 0 failures, and one had 6, all in the two
Vision OCR tests (`testVisionReadsImageAndScannedPDF` threw the `e5rt` text-recognition error, and
`testMixedPDFPersistsPerPageMethodsAndSearchableText` failed because its scanned page couldn't be read).
The lost failure was most likely that same thrown error, but that is inferred, not observed. No test
touched by this work failed in any run.

**Not established.** Not seen in the running app yet (see the V9 note above). If the search index
cannot be written, the browse fallback ignores filters.

## Dates, amounts, and document types (unreleased)

September 21, 2026. Schema V9 adds `documentType`, `amount` (as written), `dueDate`, and `expiresAt`
to the document record (lightweight migration; defaults fill old rows). The model now proposes an
issue date, due date, expiry date, and amount; `DocumentFacts` keeps a date only if macOS's
`NSDataDetector` finds that same day in the text, and an amount only if its digits appear there. The
built-in rules read a date only when it follows a label such as "Date:" or "Invoice date". Verified
facts fill unprotected fields even when filing is uncertain; the type needs filing confidence. The
document date is replaced automatically only while it is still the import day (date edits weren't
tracked as protected before 1.5); Use Suggestions may replace it. Editing any of these fields now
protects it. The details pane has Type, Amount, Due, and Expires; the list shows "Due <date>"; search
and the export manifest include them.

Sync: the four fields travel in the document record. A record from an older Mac, without them, now
applies ("no observation"); a field unknown to this version is carried along instead of rejected.
**Macs on 1.4 or earlier still reject the new fields and stop syncing until they update.**

`DocumentFactsTests`, 9 tests, pass: date and amount checks, labeled dates, an invented date and amount
dropped, the import-default rule (and explicit acceptance overriding it), type needing confidence,
edits protecting the fields, a V8 archive with a document opening as V9 and saving the new fields, and
records from older and newer Macs both applying. Mutation check: without the older-Mac allowance the
sync test fails with `invalidPayload`. Two `SyncRecoveryTests` inserted a V1 record into the live
archive to simulate a legacy document; they now insert the current record type. Full suite: 167 tests,
0 failures.

**Not established.** Not run against the owner's archive: opening it with V9 migrates it one way, after
which 1.4 and earlier can no longer open it, so that needs the owner's go-ahead. No model output with
the new fields has been observed on real documents yet.

## Export (unreleased)

September 21, 2026. File → Export Archive… (⇧⌘E; also in Settings) writes a new folder, readable
without StowKit: `Documents/<collection>/<yyyy-MM-dd> <title>.<ext>` (first collection alphabetically,
`Unfiled` for none; clashes numbered), `Text/` with the extracted text, `manifest.json` and
`manifest.csv` (title, date, sender, all collections, tags, summary, SHA-256…), and `README.txt`.
Trash is excluded. Originals only in iCloud are downloaded first. Each copy is streamed through SHA-256
and removed unless it matches the recorded fingerprint; failures are listed in the README and the
finished alert. The folder is named `.partial` until complete. Progress shows in the list footer
with Stop.

`ExportTests`, 4 tests, pass: layout, text, manifest (all collections kept, tags split), every exported
file re-hashed against the manifest, Trash left out, CSV quoting, safe and numbered names, and a
corrupted original reported and left out. Mutation check: with the fingerprint comparison removed,
the corruption test fails (2 exported, 0 failures). The corruption must keep the file's size: a
different-sized file is already refused by `localOriginal`'s size check, which first masked the
mutation. Full suite: 158 tests, 0 failures.

**Not established.** No export of the owner's real archive yet (the folder picker is a system panel
that background UI control can't drive). Time Machine coverage of the sandbox container is stated in
Settings as advice, not tested.

## 1.4.0 release build

September 21, 2026: version 1.4.0, build 10, from `f304ac9`. Before release the owner reported that
Share → StowKit worked for their own shares on the signed test build (a file and a web page into a
running StowKit), which covers the live hand-off the earlier test left out. `build-distribution.sh`:
all checks passed, including the extension's team signature and App Group. App and extension are
universal; Production; no runner or probe strings. App notarization
`91f1e47e-db95-4d16-baf0-dcf997a74278`, DMG notarization `7576ff22-dd17-4ce2-8e9e-a3c9e499040c`, both
Accepted, stapled, Gatekeeper-accepted. DMG SHA-256, regenerated after stapling:
`c08a3e44af60b800bfeaea4249226a267cadf87d467c20e9d3c9e7a07d2a6dfa` (5,305,561 bytes). The mounted
image's app passes `codesign --verify --deep --strict`, its extension `codesign --verify --strict`, plus
`spctl` and stapler validation. Appcast signed for build 10 (no Keychain prompt, reusing the approved
`sign_update`).

Update from the *released* 1.3.0: a copy of the notarized 1.3.0 app, run from a scratch folder on
the owner's archive, offered "StowKit 1.4.0 is now available—you have 1.3.0" from the live feed;
Install Update downloaded, verified, installed, and relaunched it. The copy then reported 1.4.0, passed
`codesign --verify --deep --strict` and `spctl`, contained `StowKitShare.appex`, and its executable
matched this release build byte for byte. The copy and its extension registration were removed.

**Not established.** The install was into a user-writable scratch folder, not `/Applications`.

## Share → StowKit extension (unreleased)

September 21, 2026. A new `StowKitShare` app-extension target (`com.stowkit.app.share`, share
services) is embedded in the app. Shared PDFs and images (Finder, Preview, Mail…) are copied, and a
shared web address (Safari and others) is loaded off screen in WebKit and saved as a paginated PDF
titled after the page, into `Shared Inbox` in the App Group container
`WZJ4ZPRH72.com.stowkit.app` (team-prefixed, so no provisioning profile is needed). Files are written
under a hidden name and renamed, so the importer never takes a partial file. The extension then posts
a distributed notification; the app imports the folder's files into Inbox (on that notification,
every 30 s, and at launch), deleting each staging copy once imported. Web pages load without the
owner's Safari cookies, so a page behind a login saves as its login page.

Build: the hand-written project gained the target, an Embed Foundation Extensions phase, and a shared
`Shared/ShareDropbox.swift` compiled into both targets. `build-distribution.sh` now chooses Info.plist and
entitlements per target (the local config sets the app's for every target) and refuses an export whose
extension isn't team-signed or lacks the App Group. Signed 1.4.0 (10) export: all checks passed; the
extension is Developer ID, hardened runtime, universal, sandboxed with the App Group and network
client. After launch, `pluginkit` listed `com.stowkit.app.share(1.4.0)` and the app had created
`Shared Inbox`.

`ShareExtensionTests`, 5 tests, pass: hidden-then-rename placement and " 2" numbering, no residue after
a failed write, safe filenames from page titles, a 2,000-point page cut into three 612×792 pages with
text still extractable in order, and the drop folder deleting (not trashing) an imported file. They
write to temporary folders, never the real drop folder the running app watches. Full suite: 154 tests,
0 failures.

**Run, same day, after the owner enabled the extension.** A compiled driver calling
`NSSharingService.sharingServices(forItems:)` and `perform(withItems:)` (the Share menu's path),
with StowKit quit so nothing reached the archive:

- Still not offered at first, even enabled. Three registrations existed: the Developer ID export,
  the Debug build, and Xcode's archive-intermediate copy (development-signed; the one `pluginkit`
  had chosen). With the other two removed (`pluginkit -r`) and the export added (`pluginkit -a`),
  "StowKit" appeared in the list. The dictionary activation rule was also replaced by an explicit
  predicate (URLs, file URLs, images, PDFs, up to 20), matching Apple's Notes extension; which of the
  two changes was decisive was not isolated.
- `https://example.com` saved as `Example Domain.pdf`, text extractable, but on two pages: the
  off-screen view was 1,200 points tall and a page 1,165, so every page overflowed. With the view set
  to one page height, the same page saved as one 900×1165 page ("Example Domain 2.pdf": the live
  clash-numbering worked too).
- A disposable PDF was copied byte-for-byte (`cmp`).
- `https://en.wikipedia.org/wiki/Paper` saved as `Paper - Wikipedia.pdf`, 10 pages, text in order;
  pages 1–3 viewed: faithful rendering, but one lazily loaded image below the fold was blank.

**Not established.** The hand-off to a running StowKit (notification → import) was not run live,
because the test files would have entered the owner's archive; it is covered by
`testTheDropFolderDeletesImportedFilesRatherThanTrashingThem` only. The shell could read the App
Group folder but not delete from it ("Operation not permitted"), so the four test files had to be
removed by the owner before StowKit's next launch. Pages behind a login and lazily loaded images are
known gaps.

## Organize Inbox: batch suggestions and filing (unreleased)

September 21, 2026. Organize Inbox… (button under the Inbox list, and File → ⇧⌘I) opens a window
listing every document awaiting review, not just the loaded page, with its suggested title,
sender, collection (changeable per row, or None), and certainty, each with a checkbox. Suggest for All
re-queues suggestions for every Inbox document not already being read, and the rows update as each
finishes. Apply accepts each ticked row the way Use Suggestions does, with the row's collection:
suggested fields filled and protected, filed, and marked reviewed. One failure doesn't stop the rest.
Use Suggestions now goes through the same `acceptSuggestion`.

`InboxBatchTests`, 5 tests, pass: only reviewable documents outside Trash are listed; Suggest for All
skips an analysis in flight without restarting it; a chosen collection overrides the suggested one
and is protected; accepting works without a suggestion and ignores an unknown collection; Use
Suggestions still takes the suggested collection. (The first run failed: the test document was
already queued, which the code rightly skips; the test now finishes a suggestion first.) Full suite:
149 tests, 0 failures.

**Not established.** The window itself has not been seen: on the signed test build the owner's Inbox
was empty (they had already filed its documents with the review card), so the command was disabled,
and test documents were not added to the real archive because they would sync to iCloud.

## Why Apple Intelligence never assigned a collection, and an Inbox review flow (unreleased)

September 21, 2026, signed test builds on the owner's archive. A temporary probe in
`UnderstandingPolicy.validated` logged each collection decision while Suggest Again ran on four
owner documents. The model chose sensible, allowed collections every time (Home, Taxes, Home,
Receipts), and every word of every supporting quote was in the document (`tokenPresent=1.00`). Only
the two-word quote matched the document character for character (`rawFound=1`); one other matched
once spacing and punctuation were ignored, and two joined words from separate lines. The exact
match therefore rejected 3 of 4 correct collections and set their confidence to 0, so nothing was
filed. Separately, two of the three were over the 4,000-byte excerpt limit, whose deliberate 0.64
cap keeps long documents below the 0.65 filing threshold; that rule is unchanged.

Fix: `UnderstandingPolicy.evidenceSupported` compares words (case and accents folded): the quote's
words in order, or, for three or more words, all of them present. A word the document lacks still
fails it. Four `IntelligenceTests` built from the measured patterns pass; with the old exact check
put back, the three reflow tests fail and the invented-word test still passes. (These four were
first appended inside a private helper actor after the test class, where XCTest never ran them; the
suite count, 19 instead of 23, exposed it.) On the owner's archive, Suggest Again on the property tax
receipt then filed it in Taxes, "Fairly sure", with sender and tags, and it left Inbox. The model
also replaced the filename title "June 2025 property tax receipt" with "Payment Confirmation": the
filename title isn't protected.

Inbox flow: while browsing Inbox, the details pane shows a review card: "Inbox · n of m", previous
and next (⌘[ ⌘]), the suggestion with Use Suggestions & Next (⌘↩), a button per collection that files
the document and marks it reviewed, and Mark Reviewed & Next (⌥⌘↩). Each decision opens the document
that followed. Seen rendering on the owner's Inbox ("1 of 2", then "1 of 1"); a first version showed
"1 of 5" for a moment on a non-Inbox document while the list still held the previous view, fixed by
waiting for the reload. The accept and file buttons were not pressed on the owner's documents.

During this run a probe build and the test build ran at once on the same archive: `osascript quit`
stopped only one, and the probe had to be terminated. No damage was seen, but two instances share
one database and one iCloud connection; check `pgrep -lf StowKit.app` after quitting.

Full suite: 144 tests, 0 failures (the Vision `e5rt` failures are gone today).

**Not established.** The review card's buttons were not exercised on real documents or in a UI
test (XCTest's host renders no library view). Long documents still stay in Inbox for review by design.

## Sparkle updates end to end: 1.2.9 → published 1.3.0

September 21, 2026, owner's Mac. From `2720ebd` in a temporary worktree, a signed Developer ID build
labelled 1.2.9 (build 8), otherwise identical to 1.3.0, was run from a scratch folder. StowKit →
Check for Updates… fetched the live feed (`releases/latest/download/appcast.xml`) and offered
"StowKit 1.3.0 is now available—you have 1.2.9". Install Update downloaded the published DMG,
installed it, and relaunched the app (new process). Afterwards the app at that location reported
1.3.0 (9), passed `codesign --verify --deep --strict` and `spctl` (Notarized Developer ID), and its
executable's SHA-256 matched the 1.3.0 release build exactly. The feed, EdDSA signature, sandboxed
installer service, and mach-lookup exceptions therefore all work together in a real install.

Cosmetic: the update window shows the whole GitHub release page as release notes, because the
appcast uses `releaseNotesLink`. Embedding the notes as the item's description would read better.

**Not established.** The install replaced an app in a user-writable scratch folder, not
`/Applications`; installing there may ask for an administrator password depending on ownership.
Automatic (silent) installation was not tried.

## 1.3.0 release build

September 21, 2026: version 1.3.0, build 9, from `2720ebd`, built with
`scripts/build-distribution.sh`; all of its checks passed, including the new Sparkle feed, key, and
team checks. App and Sparkle framework are universal (`x86_64 arm64`); Production; no runner or
probe strings. App notarization `a5f3da18-2c7b-42d0-8c78-5aa9d5426fbb`, DMG notarization
`c9d3c972-9ebf-49a0-8e1f-2a8277f26015`, both Accepted, stapled, and accepted by Gatekeeper. DMG
SHA-256, regenerated after stapling: `31932c312093068fc65f4dc364e1429d5c26c034e0910124ecacf82aad1c9ed7`
(4,992,522 bytes). The mounted image holds `StowKit.app` and `Applications`; the app passes
`codesign --verify --deep --strict` and `spctl`. `scripts/make-appcast.sh` wrote and signed
`appcast.xml` (build 9, length 4,992,522); `sign_update` waited on a Keychain prompt for the
`stowkit` key until the owner approved it.

**Not established.** This exact binary was not launched against the owner's archive (the same
source ran as the signed test build in the entry below). No update has been installed by Sparkle.

## Sparkle updater, and a test that erased the owner's inbox folder (unreleased)

September 21, 2026, 1.3.0 (9) signed test builds on the owner's Mac.

**Updater.** Sparkle 2.10.0 through Swift Package Manager: the owner's choice on 2026-09-21, and
StowKit's first dependency. Only signed builds carry `SUFeedURL`
(`https://github.com/cpkess/StowKit/releases/latest/download/appcast.xml`), `SUPublicEDKey`, and
`SUEnableInstallerLauncherService` (`Config/StowKitCloud-Info.plist`), plus the `-spks`/`-spki`
mach-lookup exceptions Sparkle's sandboxed installer needs. The ad-hoc default build has no feed,
so it never updates itself. The EdDSA key is StowKit's own, in the owner's login Keychain under
account `stowkit`, separate from an existing Sparkle key found there. `scripts/make-appcast.sh`
signs a stapled DMG and writes `appcast.xml`; `build-distribution.sh` now also refuses a build
without the feed or key, or whose Sparkle framework isn't signed by the team.

The first signed build **crashed at launch**: `dyld: Library not loaded:
@rpath/Sparkle.framework`, because the hand-written project had no `LD_RUNPATH_SEARCH_PATHS`. With
`@executable_path/../Frameworks` added, the rebuilt app launched on the owner's archive, its menu
showed "Check for Updates…", and Settings has an Updates section and a Rules tab.

**Test isolation bug.** On that launch the Inbox Folder setting was empty. A signed probe build
logged `no bookmark stored`: `InboxFolderTests` removed `StowKitInboxFolderBookmark` from
`UserDefaults.standard` in setUp and tearDown, and the hosted tests share the app's container, so
every test run since the owner chose the folder had erased it. No files were affected: the
`LibraryStore`s the tests create run with processing off and never started the folder. Fixed:
`InboxFolder` takes its defaults, the tests use a throwaway suite, a processing-off store never
creates an inbox folder, and `testTheOwnersRealFolderSettingIsNeverTouched` checks the real key is
unchanged. Full suite: 140 tests, the same 6 Vision failures.

**Not established.** No update has been downloaded or installed: no release carries an
`appcast.xml` yet, so the feed currently returns 404. The end-to-end test needs 1.3.0 published,
then an older build updating to it. The owner has to choose the inbox folder again.

## Filing rules (unreleased)

September 21, 2026, after `08e00df`. Settings → Rules: owner-written rules in the style of
paperless-ngx matching. A rule looks in any of title, sender, file name, or document text (first
100,000 characters), for any of the words, all of the words (whole words), a phrase, or a regular
expression, ignoring case and accents. Its actions are to add a collection, add tags, set the
sender, and mark the document reviewed. Rules run inside `finishAnalysis`, after Apple
Intelligence's merge, on unprotected fields only; a rule's collection replaces the one the model
added, never the owner's. Apply to Existing Documents runs them over everything outside Trash,
only ever adding collections. The inspector names the rules that applied. Rules are stored per
Mac, as JSON in a checkpoint row, with no schema change.

Sync forward compatibility: `applyCloudPage` now keeps a record of an unknown type in CloudState
and skips it instead of throwing. Mutation-tested: with the skip removed,
`testUnknownRecordTypeFromANewerMacDoesNotStallSync` fails with `unsupportedRecord` and the token
does not advance, which is what a 1.2.0 Mac would do.

`FilingRulesTests`, 9 tests, pass: matching per algorithm and field, disabled and empty rules,
protected fields untouched, tags added once, a deleted collection ignored, rules filing a document
the model was unsure about and the result syncing, apply-to-existing skipping Trash and being
idempotent, rules surviving a reopen, and the unknown-record skip. Full suite: 139 tests, 6 failures,
all in `ProcessingTests` (the Vision `e5rt` failures recorded below).

**Not established.** Rules have not been used in the real app or on the owner's archive. They do
not sync; each Mac has its own. Matching on OCR text inherits OCR's mistakes.

## 1.2.0 release build

September 21, 2026: version 1.2.0, build 8, from `1f45b12`, built with
`scripts/build-distribution.sh`; all of its checks passed. Universal (`x86_64 arm64`), Production,
and neither the live-verification nor the maintenance runner's strings are present. App
notarization `512c4a62-d007-4877-abc8-fd6d58037e97` and DMG notarization
`e4688a03-1c8d-4fa8-b9e8-58ebaeded5bf`, both Accepted; both stapled and accepted by Gatekeeper
(`source=Notarized Developer ID`). DMG SHA-256, regenerated after stapling:
`a247095ec3e37c275b01b399b1456c0ef6d27158fe34f59e970f24e3730d3ab3` (3,768,772 bytes). The image,
mounted read-only, holds `StowKit.app` and an `Applications` link; the app passes
`codesign --verify --deep --strict`, stapler validation, and `spctl`, and reports 1.2.0.

**Not established.** This exact binary was not launched against the owner's archive; the identical
source ran as the unnotarized test build recorded below. The limits in the release notes apply.

## Inbox folder from a phone, and overlapping list rows

September 21, 2026, 1.2.0 (8) test build, owner's archive. The owner chose an iCloud Drive folder
(`iCloud Drive/StowKit/Inbox`) in Settings and added a document from their iPhone; it was imported,
its text read, and Apple Intelligence titled it ("Order confirmation for PRL x TÓPA", sender
filled). Three more followed the same way. The owner reported that the file names in the Inbox list
overlapped. Not seen directly: by the time of the screenshot the rows had re-laid out. The likely
cause, from code: the row grew a line when the model's title and sender replaced the one-line
filename title, and the macOS list did not re-measure a row whose content changed in place.

Fix: a row's height no longer depends on its content. The title reserves two lines, the sender line
is always present, and the search excerpt's three lines are reserved only while searching; the list
is rebuilt when searching starts or stops, the one remaining height change. On a rebuilt signed test
build, the five rows in Recent were all one height with no overlap, and a search for "receipt" showed
two rows with excerpts, also without overlap. Full suite: 130 tests, the same 6 Vision failures.

**Not established.** The overlap itself was never reproduced, so the fix is checked against the
explanation, not against the original symptom; a new import arriving while the Inbox list is
visible has not been watched with this build.

## 1.2.0 test build on the owner's real archive

September 21, 2026: version 1.2.0, build 8, built with `scripts/build-distribution.sh` (Developer ID,
Production, not notarized; all of the script's checks passed). The signed Info.plist has
`CFBundleIconName` AppIcon and `Production`; the entitlements include
`files.user-selected.read-write` and `files.bookmarks.app-scope`. 1.1.0 was quit and the test build
launched with `open --stderr` on this Mac (Apple Silicon, macOS 27), owner's account. Observed:

- It opened the owner's real archive (`Application Support/StowKit`), not the `CloudArchives` copy
  1.1.0 had been reopening. The sidebar showed "iCloud"; its popover read "Up to date".
- iCloud was back on without the owner doing anything: the resolver's `.connect` for a binding the old bug
  had disabled.
- Settings → Measure Disk Use listed no "Other iCloud archives", a line shown only when
  `CloudArchives/` holds data, so `ArchiveCopies` removed the duplicate copy (its only content).
- The NovoCare form in the real archive already had an Apple Intelligence suggestion, rated
  "Not sure — please check", so its fields were not filled automatically. The missing suggestions
  the owner saw belonged to the duplicate copy only.
- stderr stayed empty.

**Not established.** The container is protected from the shell, so the copy's removal is inferred
from the usage figure, not listed. The sync after reconnecting was not compared record by record
with iCloud. The inbox folder has not yet been used with a real iCloud Drive folder or a phone.

## Inbox folder, for adding documents from a phone (unreleased)

September 21, 2026, after `3eb2556`. Settings → Inbox Folder takes a folder, remembered with a
security-scoped bookmark. Every 30 seconds, and on Check Now, StowKit imports the supported
documents directly inside it through the normal importer, then moves each one to the Trash once
the import (or an identical document already in the archive) is confirmed. Hidden files and
subfolders are ignored. An iCloud Drive file not yet on this Mac is asked to download and taken on
a later pass. A file that fails stays in the folder and isn't retried until it changes. Background
imports update the lists without moving the owner's selection. Entitlements: user-selected files are
now read-write (to trash taken files), and both builds carry `files.bookmarks.app-scope`; the
default build gained `Config/StowKit.entitlements` for that, and `codesign -d --entitlements` on the
Debug app shows both.

`InboxFolderTests`, 4 tests, pass in the sandboxed test host: candidate filtering; import then
trash, with identical bytes counted once and still removed from the folder; an empty file left in
place with a status saying so; the bookmark surviving a new `InboxFolder` and cleared by Stop Using
Folder. Full suite: 130 tests, 6 failures, all the Vision OCR tests in `ProcessingTests` with the
same `e5rt` error as the previous entry.

**Not established.** No real iCloud Drive folder or iPhone was used: the tests' folder is inside the
app's container, so neither the bookmark to a user-chosen folder across a real relaunch nor the
iCloud download path ran. Two Macs watching one folder may both import a file; the identical
imports converge on one iCloud record by design, but that was not run.

## Documents from iCloud get suggestions on this Mac (unreleased)

September 21, 2026, after `3a240ff`. A document that arrives from iCloud is given the analysis state
`remote`, which nothing advanced, so a document its importing Mac never understood (no model, quit
first, or imported by an older build) never got suggestions anywhere. Now
`queueUnprocessedRemoteAnalyses` queues such a document when its text is on this Mac, it still
carries only what import set (no summary, sender, tags, or collections, and a filename title), and
the text has been here for 10 minutes, the importing Mac's grace period. The inspector labels
`remote` as "Details came from iCloud" and offers Suggest Again.

No new synced field: `validateIncoming` rejects a field either side lacks, so a marker would stall
sync on 1.1.0 Macs. If two Macs do process one document, automatic fields merge through
`SyncMergePolicy.preferred` without a conflict.

`CloudArchiveTests`, 24 tests including two new ones, pass against the fake transport: an unprocessed
document from a second archive stays alone inside the grace period and is queued after it; one
whose importing Mac set a summary is left alone.

**Not established.** No live two-Mac run. The worker completing a queued remote document was read
from code (it uses saved text only), not run in a test, because tests use no model provider.
Whether two Macs both processing one document produces a mixed set of fields was not tested.

## One archive in iCloud (unreleased)

September 21, 2026, on `main` after `770fdef`. The owner found StowKit open on a second local copy
of their own iCloud archive (sidebar "iCloud Archive"; picker "On My Mac — Stored on this Mac"),
where a document that arrived from iCloud showed "Suggestions come after the text is read" beside
"Text ready". Two causes, both read from code: 1.x could reopen this Mac's own zone as a separate
copy, and a document arriving from iCloud is given the analysis state `remote`, which nothing ever
advances and the inspector has no wording for. The owner then set the direction: one archive, in
iCloud.

Built: the archive picker and File → Switch Archive are gone; `ArchiveResolver` decides at launch
whether to connect, upload, join, or stay local; `CloudSetup.activeRoot` ignores a remembered copy
of this Mac's own archive; `ArchiveCopies` removes such a copy only when it is provably redundant;
the account-change observer no longer turns iCloud off; the sidebar shows sync status.

`OneArchiveTests`, 10 tests, pass: every resolver branch (including the owner's pause, the old
disabled binding, never guessing between two zones, never merging a Mac that has documents), the
root redirect, and copy retirement (a redundant copy is removed; one with a document the real
archive lacks, or with unsent edits, is kept). Full suite: 124 tests, **6 failures, all in
`ProcessingTests`**, the Vision OCR tests, each throwing
`e5rtError("e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed", 13)`.
`testVisionReadsImageAndScannedPDF` fails identically on unchanged `770fdef` in a separate worktree,
so this is the machine's text recognition, not this change.

**Not established.** Nothing here ran against the owner's real archive or live iCloud: the Debug
build has no iCloud container, so the resolver was exercised only through its pure function. The
join path (a second, empty Mac) is untested on a second Mac. Documents that arrived from iCloud
still never get suggestions; that is the next step (processing claims). Household sharing still
opens a separate local archive for a participant and is untested.

## 1.1.0 release build

September 21, 2026: version 1.1.0, build 7, from `f09cc55`, built with
`scripts/build-distribution.sh`. All of the script's checks passed. The binary is universal, and
contains the permanent-deletion code but not the `ArchiveMaintenance` tool (its text is absent).
Launched against the owner's archive before notarization: over 30 s, 0% CPU, 4 threads, 145 MB,
and it answered Apple Events; the owner's document rendered.

That launch also showed **iCloud off for the owner's archive** (Settings: "iCloud is off"). This
is the 1.0.0 archive-switch bug, fixed in 1.1.0: opening the test archive had called `pauseCloud()`
and disabled it. The owner's iCloud zone still exists; re-enabling was left to the owner.

Apple accepted notarization of the app (`f0a36df9-a2d0-43c3-baa0-5f0c345a68f5`) and of the signed
DMG (`25a176a2-b8c5-4886-88b9-764f565896d1`). Both were stapled and assessed as Notarized Developer
ID. The mounted DMG holds the Applications link and StowKit 1.1.0 (7), Production, with a valid
signature, a stapled ticket, and Gatekeeper acceptance. The sidecar was regenerated after
stapling. **DMG SHA-256: `cff1fa0848412821487e6506555f562faa9458eda7b48958217404ed1be4d7cc`.**

**Not established.** The same limits as 1.0.0, plus permanent deletion and the archive picker
untested on a second Mac or against live deletions.

## Leftover iCloud test archives identified and deleted

September 21, 2026, `ArchiveMaintenance` dry run against the owner's Production iCloud. Three
`StowKit-` zones exist. **`4017FFBA-…` is the owner's own archive**, identified from the local
database and kept. The other two each hold one fictional document from the September
verification runs: `462F692A-…` ("Fictional cloud verification", `fictional-transfer.pdf`,
the successful retry) and `72CAADA2-…` (the same, from the failed first run). Only those two
qualify for deletion.

This corrects an earlier claim that all three archives in the picker were test archives. The
picker listed the owner's archive as "iCloud Archive 4017", because it had not yet learned this
Mac's archive ID, so choosing zones by name would have deleted the owner's iCloud copy.

**Deleted the same day.** The owner ran the maintenance build with `--delete` (this session's
permission check blocked Claude's own run). Its output: mode DELETE, `KEEP StowKit-4017FFBA-…
— this Mac's own archive`, each other zone "1 document(s); all fictional: true", then `DELETED`
for `462F692A-…` and `72CAADA2-…`, `removed CloudValidation/`, `removed local cache
462F692A-…`, `DONE`. A second dry run afterwards listed only `KEEP StowKit-4017FFBA-…`.

**Not established.** The zones' absence was checked only through the app's own zone listing,
not in CloudKit Console. The owner's archive still has iCloud turned off from the 1.0.0 switch
bug; nothing here re-enabled it.

## Permanent deletion, archive picker, and iCloud-style downloads

September 21, 2026, after 1.0.0. Full suite: **114 tests, zero failures** at the time of the
feature commit. Nothing below is released yet.

**Permanent deletion** (`ArchiveRepository+Deletion`). Five tests in `CloudArchiveTests`, run
against the fake transport with two local stores:

- Only documents in Trash can be deleted.
- A deletion removes the local rows, the file, and the search entry.
- The iCloud record becomes a tombstone with exactly `id`, `contentHash`, and `deleted`.
- The original's content is deleted from iCloud, and the other store removes its downloaded copy.
- A stale offline edit on another Mac cannot resurrect the document.
- A concurrent edit that reaches iCloud first still loses to the deletion.
- A local-only archive deletes without iCloud.

The concurrent-edit test was mutation-checked. With the delete-wins conflict branch disabled,
three assertions failed and the document reappeared with a cloud-derived ID — the resurrection
bug the branch exists to prevent.

**Archive picker.** Checked in the signed test build against the owner's Production iCloud. It
listed On My Mac plus three iCloud archives and marked the current one. The current one was
**a fictional test archive from Codex's September smoke tests**: the saved archive choice
already pointed at it before this session, so it had been opened earlier from Settings →
Find My iCloud Archives. Selecting a picker row by background click only dismissed the popover,
a limitation of driving an inactive app. Through the new **File → Switch Archive** menu, the
debug build switched from that test archive back to the owner's archive, which showed its own
document. Switching no longer calls `pauseCloud()`, which had turned iCloud off for the archive
being left.

**Not established.**

- Permanent deletion has not run against live CloudKit or between two physical Macs.
- `deleteContent` and the change feed's tolerance of content-record deletions are exercised
  only by the fake transport; the fake does not emit deletions.
- The download badge and the Download Now / Remove Download menu items were compiled into the
  signed build but not seen on screen, because context menus need full-screen control.
- A popover row press was not observed working, only the equivalent menu command.
- The owner's Delete Permanently and Empty Trash buttons were not pressed on real documents.

## 1.0.0 release build

September 21, 2026: version 1.0.0, build 6, from `8ac44a1`, built with
`scripts/build-distribution.sh` and the installed Developer ID profile. The script's checks all
passed: Developer ID authority, hardened runtime, Production in both entitlements and Info.plist,
no device restriction, and no debugging entitlement. The binary is universal (arm64, x86_64), and
contains no `PDFView` symbols.

Before notarization, the exported app was launched against the owner's archive. Over 45 s: 0% CPU,
4 threads, 148 MB, and it answered Apple Events. The preview rendered; the details-pane fixes were
present. Settings showed iCloud "Up to date" on Production, and **Remove Download** and **Keep
Downloaded** appeared once iCloud was connected. Remove Download was not pressed on the owner's
document.

Apple accepted notarization of the app (`0b688a9c-d450-49e5-ac08-61223ec74b98`) and of the signed
DMG (`88a23663-48f0-4c5e-a8c2-685e0849d2c0`); both tickets were stapled and assessed by Gatekeeper
as Notarized Developer ID. The DMG was then mounted read-only: it holds the Applications link and
StowKit 1.0.0 (6), Production, with a valid signature, a stapled ticket, and Gatekeeper
acceptance. The checksum sidecar that `package-dmg.sh` writes becomes stale once the DMG is signed
and stapled (`962a1d74…` against the final `36e3d07b…`), so it was regenerated after stapling and
verified. **DMG SHA-256: `36e3d07b1e69ba6b9f57bc8970f26e6f9606a6ff7656cda2cc8c09c7ea8b5fb4`.**

**Not established.** The release has not run on a second Mac, on Intel hardware, or on macOS
14–26. Household sharing remains untested across two accounts, as the release notes say first.

## Interface fixes, filename metadata, and Apple Intelligence on medical records

September 21, 2026, macOS 27.0 (26A428), Apple M2 Max, the owner's archive in the running app.
Full suite: **109 tests, zero failures.**

**Apple Intelligence refused medical documents.** Standalone probes with StowKit's own
instructions: model `available`. A neutral utility bill was read in 1.3 s. A fictional medical
authorization form failed in 0.2 s with "May contain unsafe content". Switching to Apple's
permissive content-transformation guardrails alone still refused, because they do not apply
to guided (`@Generable`) output. Permissive guardrails with plain-text output read both medical
samples in 0.4 s. A second defect hid the first: on macOS 27 the refusal is a
`LanguageModelError`, while the code matched only the deprecated `GenerationError`. So the
refusal was never recognized, and every medical record silently fell back to rules.
`AppleFoundationModelProvider` now retries refusals of either type through the permissive
plain-text path, parses the labelled answer with `ModelFields.parseLabeled`, and applies the
same `UnderstandingPolicy.validated` checks. A collection is accepted only with a quote found in
the text, and a sender only if it appears there. The live
`testOnDeviceModelReadsMedicalDocumentsInsteadOfFallingBack` failed with the refusal before the
fix and passes after it. The parser test covers the one-line " / " answer the model actually
produced.

**Filenames.** `FilenameMetadata` turns
`NovoCare_Patient_OBES_Patient_Authorization_FORM_2026-09-17T00_18_36Z.pdf` into the title
"NovoCare Patient OBES Patient Authorization FORM" and the date 2026-09-17. It reads year-first
dates only; February 30th and month-first dates are rejected. `refreshAutomaticMetadataOnce`
applied this to existing documents on launch without recording a manual edit, and re-queued
rule-based analyses. On the owner's archive the document now shows the cleaned title and
Sep 17, 2026, instead of Sep 21, and its suggestions read "Suggested by Apple Intelligence",
where they had read "Local rules".

**Interface, seen on screen.** A single review banner above the editable fields; title, date,
sender, collections, tags, and summary visible without scrolling; a labelled **Add to
Collection** control; processing, storage, and file details under **More Details**, which opens
correctly; jargon replaced throughout.

**Not established.** Suggestion quality across real documents: one real document was observed,
and it stayed in review because long documents are analyzed from an excerpt and capped below
the filing threshold. The permissive path deliberately relaxes Apple's content filter for the
owner's own text; the answers are validated, but their content is not filtered. On macOS 26,
the older `GenerationError` branch is compiled but untested.

## Disk accounting read off the real archive

September 21, 2026: first reading of Settings → Measure Disk Use on the owner's populated archive,
in the running app. It closed the step-1 gap "never read off a real archive", and it exposed a
flaw that the tests had not:

| Line | Reading |
| --- | --- |
| Disk used | 52.7 MB |
| Originals | 537 KB, 7 files |
| Database | 4.5 MB |
| Search index | 2.2 MB |
| Thumbnails | 53 KB |
| Other | **45.5 MB** |

86% of the archive folder was "Other". A temporary probe logging every file that fell into
"Other" found 54 files, all under `CloudValidation/`: seven leftover isolated archives from the
live verification runner (`CloudLiveVerification` writes to
`DocumentStorageManager.defaultRoot/CloudValidation/<UUID>`), 43.4 MiB of fictional fixtures.
Archives opened from iCloud share the same structure, beneath `CloudArchives/`. Neither belongs
to the archive being measured.

`ArchiveUsage` now reports `otherArchives` (`CloudArchives/`) and `verificationData`
(`CloudValidation/`) on their own lines, and `derived` counts only data that regenerates.
`testUsageReportsOtherArchivesAndVerificationDataSeparately` confirms that neither folder lands
in "other", and that a nested archive's `Library.store` is not counted as this archive's
database. Full suite: **103 tests, zero failures**. Re-measured on the real archive, Settings
shows "iCloud test data 45.5 MB" with an explanatory caption, and no "Other" line.

**Not established.** The total still has not been compared with `du`: the app's container is
protected from this shell (`Operation not permitted`). The runner still writes inside the real
archive's folder; moving it elsewhere is untested, so it has not been changed. The leftover test
data has not been deleted — that is the owner's call.

## Launch freeze root cause: a VSplitView rebuild loop in StowKit

September 21, 2026. **This corrects the entry below, which concluded the freeze was a transient
macOS state and not a code defect. That was wrong.** The freeze is a StowKit bug and reproduces
on a healthy system.

`DocumentDetailView` held the preview in a `VSplitView`. Temporary probes, read by launching
with `open --stderr <file>` (the sandboxed app's `NSLog` output did not reach `log show`),
counted what happened in 15 seconds with a two-page PDF selected:

| Event | Count |
| --- | --- |
| Detail view appeared | 1 |
| Detail view body evaluated | 3 |
| Preview pane appeared (destroyed and rebuilt) | 302 |
| Preview load task started | 302 |

The split view rebuilt its own top pane about 20 times a second while nothing above it redrew,
and each rebuild reset the pane's state and restarted its load. CPU held at ~200%. Guarding the
pane's write to its parent's state changed nothing (302 again), so that was not the trigger.
Replacing `VSplitView` with a `VStack` dropped every count to 1 and CPU to 0%.

With the shipped preview, every rebuild created a new `PDFDocument` and a new `PDFView`, and
each `PDFView` runs PDFKit's Vision page analysis. Running the committed `00cdf8c` code (still
`PDFView` in a `VSplitView`) after a restart, with **no `e5rt` messages present**:

| Measurement | Result |
| --- | --- |
| `PDFView`s created | 454 in about 15 s |
| `PDFDocument`s created | 454 |
| Threads | 379 at 15 s, then 521 |
| Resident memory | 3.5 GB |
| Quit Apple Event | hung; the process had to be killed |

That is the original freeze, reproduced without the degraded Vision state. The 261 blocked
analyzer threads and 1.8 GB recorded on September 20 are this loop.

**Fix, in `DocumentDetailView`:** the preview and inspector sit in a `VStack`, and the preview
renders pages with `CGPDFDocument` through `ThumbnailService` instead of hosting `PDFView`.
Either change alone would stop the freeze; both are kept, because the split view also wasted
CPU re-rendering, and `PDFView`'s analysis remains a hazard when Vision is unwell. Measured
on the same archive and document over 60 s: **0% CPU, 4 threads, 178 MB** throughout. The page
rendered, "Page 2 of 2" rendered after paging, and CPU stayed at 0% afterwards. Full suite: **102
tests, zero failures**, including
`testPreviewRendersEachPageWithCoreGraphicsAndReportsLockedPDFs`.

**Not established.** Why `VSplitView` rebuilds its pane; that is SwiftUI's behavior, observed but
not explained. Whether it depends on the document — it was observed with a two-page PDF
selected — and why the shipped build sat idle at 0% right after the September 20 restart,
possibly because a different document was selected; that is unverified. The degraded `e5rt`
state may have made the first incident worse, but it is not required to reproduce it. No
automated test covers view rebuilds, because the XCTest host renders no library view; the probe
method above is the check. Text selection inside the preview pane is gone; View Text and Open a
Copy remain.

## Launch freeze traced to a transient system Vision state

> **Superseded.** The conclusion below is wrong: the freeze is a StowKit bug, reproduced after
> the restart without the degraded state. See the entry above. The measurements below stand.

September 20, 2026: the installed v0.6.0-alpha.2 froze on launch from `/Applications`. The
cause was a macOS text-recognition state that a restart cleared. **No StowKit code was
changed**, and the app has not been shown to be at fault.

`sample` on the frozen process reported `Dispatch Thread Soft Limit: 64 reached in 2018 of
2018 samples -- too many dispatch threads blocked in synchronous operations`, with a 1.7 GB
footprint and 394 threads. The blocked threads were PDFKit's own Live Text analyzer, not
StowKit's extraction pipeline:

```text
-[PDFView visiblePagesChanged:] -> +[PDFPageAnalyzerV2 analyzePage:withBox:requestTypes:]
  -> -[VNRecognizeDocumentsRequest internalPerformRevision:inContext:error:]
  -> -[VNControlledCapacityTasksQueue dispatchSyncByPreservingQueueCapacity:]  (blocked)
```

The frozen app would not answer a Quit Apple Event and had to be killed.

| Measurement | Frozen | After restart |
| --- | --- | --- |
| Threads | 394 | 5 |
| PDFKit analyzer threads | 261 | 0 |
| Vision threads | 64 | 0 |
| Footprint | 1.8 GB | 49.5 MB |
| Dispatch thread soft limit | hit in every sample | not hit |
| `osascript ... get its name` | hung | 0.1 s |

Ruled out by measurement, not by reasoning:

- **Not an old build.** The current `main` build reproduced it identically (261 analyzer
  threads, 1.8 GB), so reinstalling would not have helped.
- **Not StowKit's OCR.** A build with `processingEnabled: false` still froze (278 analyzer
  threads, 353 Vision threads, 1.9 GB).
- **Not a recently deleted document.** The freeze was first reproduced before that deletion.
- **Not redundant `autoScales` writes in `PDFPreview.updateNSView`.** Guarding them changed
  nothing (264 threads) and the change was reverted.

**Correction to the entry below.** "Framework logs still include ... Vision model-resource
messages; their presence did not fail the assertions" and the later note calling the `e5rt`
fallback "a logged warning, not a failure" both understated these. Those messages were the
signature of the degraded state that produced this freeze. The single-threaded test suite
passed through it because it performs one recognition at a time; it took PDFKit's concurrent
per-page analysis to turn the same state into thread-pool starvation. After the restart the
`e5rt` messages are **absent entirely**.

The Vision cold-start cost is unchanged by the restart — 45.1 s first request, 0.08 s warm,
measured again with the standalone probe — so that remains a property of this macOS build and
is independent of the failure above.

**Not established.** Why the degraded state arose, whether it recurs, and whether PDFKit's
analyzer is the only way to trigger it. A minimal `PDFView` harness (250-page text PDF, then a
20-page image-only PDF) produced zero analyzer threads, but its window may never have become
genuinely visible, so it does not isolate anything. If this recurs, the defensive fix is to
render previews with `CGPDFDocument` — which the thumbnail and OCR paths already use — rather
than `PDFView`, so the app cannot wedge itself when Vision is unwell. `PDFView` has a
`setDocumentAnalysisEnabled:` selector at runtime, but it is not in the SDK and was not used.

## Optimized storage, step 2: pins and manual eviction

September 20, 2026: `DocumentStorageManager.evictOriginal` is the only place StowKit removes a
local original, and it checks every invariant from
[the storage architecture](STORAGE_ARCHITECTURE.md) itself rather than trusting a call site.
Each refusal is a distinct `EvictionRefusal` case, so tests assert *why* an eviction was
refused, not merely that it failed. `OriginalState.pinned` is now wired, which needed no
migration. Eviction is manual only; nothing evicts on its own.

Four tests in `CloudArchiveTests` against the fake transport; full suite **101 tests, zero
failures**.

- `testEvictionRemovesTheLocalCopyAndTheOriginalComesBackByteIdentical`: the file goes, the
  derived state (`relativePath`, thumbnail, saved text, completed job) stays, the location
  flips to `.optimized`, and `localOriginal` downloads the bytes back **byte-identical** with
  exactly one transport download.
- `testEvictionRefusesPinnedUnverifiedAndUnfinishedDocuments`: refuses `.pinned`; refuses
  `.noVerifiedCloudCopy` when neither uploaded-and-verified nor downloaded; **accepts** a
  `remote` document, which is the case a naive `cloudVerified`-only rule would have broken;
  refuses `.processingOutstanding` on a separate archive so the refusal cannot come from an
  already-missing file.
- `testEvictionRefusesWithoutSyncAThumbnailOrALocalFile`: refuses `.syncUnavailable`,
  `.sharedArchive`, `.noThumbnail`, and `.notDownloaded` on a second eviction.
- `testEvictionFrontsReclaimedBytesInMeasuredUsage`: measured usage drops by exactly the
  reported reclaimed bytes and one original file, while derived bytes remain.

The suite was checked for vacuous passes by deleting the `pinned` guard and re-running: two
assertions failed. The guard was restored and the suite re-run.

**Not established.** No eviction has been performed in the running app or against live
CloudKit — every result above uses `FakeArchiveCloud`. The inspector's controls have not been
seen on screen. Eviction while a download is genuinely in flight is enforced by a
`downloads[id]` check but is not covered by a test, because the fake transport completes
synchronously. Interrupted-transfer and disk-full recovery from the design note's acceptance
list remain untested.

## Optimized storage, step 1: disk accounting

September 20, 2026: `DocumentStorageManager.usage()` walks the archive and reports allocated
bytes split into originals, database, search index, thumbnails, in-progress transfers, and
other, with a count of files it could not read. Settings replaces the old "Originals" line with
this breakdown behind an explicit **Measure Disk Use** button. **No eviction exists**, and
nothing removes or modifies an original.

Two tests in `ArchiveTests` cover it, and the full suite passes **97 tests with zero failures**.
`testUsageMeasuresDiskAndSeparatesOriginalsFromDerivedData` imports a PDF and a PNG, then
asserts the file count, that originals are at least the recorded logical sizes, that the
database is counted, that the categories sum to the total, that the total equals an independent
walk of the same tree, and that both originals still exist byte-for-byte afterwards —
measurement is a report, never a mutation. `testUsageCountsTrashedOriginalsThatStillOccupyDisk`
asserts trashing frees nothing, which is the current behavior and the reason this work exists.

The `du` acceptance gate holds: on APFS, `du -sk` over a fixture tree equalled the summed
allocated blocks of its files exactly (16384 bytes both ways), so directories contribute
nothing and the reported total is comparable with `du`.

**Not established.** The breakdown has not been read off a real archive in the running app —
the figures above come from tests and a fixture tree, not from Settings on a populated
library. The reconciliation the design note describes (a recorded-size fast path checked
against a background walk) is not built: every measurement is a full walk, taken only when the
button is pressed.

## Vision cold-start cost measured

September 20, 2026: the first `VNRecognizeTextRequest` in a process costs **46.5 s**;
subsequent requests in that process cost **0.08 s**. Measured with a 90 KB standalone Swift
tool containing no StowKit code, so this is a property of Vision on this machine, not of the
app. macOS 27.0 (26A428), Apple M2 Max.

```text
iteration 1: 46.494 s   iteration 2: 0.081 s   iteration 3: 0.085 s   iteration 4: 0.088 s
```

The warm state is **shared between processes and expires**. A second process started
immediately after paid only 0.173 s, and a third 0.178 s; but a fresh process roughly twenty
minutes later paid the full 46.3 s again. The cost therefore recurs after idle rather than
being a one-time, first-launch charge. The `e5rt` fallback messages recorded below appear on
every cold run and remain non-fatal — recognized text is correct in all cases.

Consequence for the UI: text extraction already shows a spinner, a `· 1 of N` label, and a
determinate bar, so the window is **not** a frozen-looking app — but the first page can sit
at `1 of N` for roughly a minute with no stated reason. `ProcessingInspector` now adds a
caption after six seconds on an uncompleted first page. The extraction pipeline is unchanged;
the delay is Apple's and is not worked around.

**Not established.** The exact idle threshold at which the warm state is discarded (observed
lost somewhere between 2 and 20 minutes), whether it is tied to memory pressure, and whether
other Macs or macOS versions behave the same. The caption's six-second threshold is a
judgement call, not a measured optimum, and it was not verified on screen — triggering it
requires an import into a real archive.

## macOS 27 OCR regression — not reproducible in the shipping build

September 20, 2026 (later run, Claude Code): the OCR failure recorded under "Latest regression
status after provisioning" **does not reproduce in the default ad-hoc build**. The full Debug
suite ran **95 tests with zero failures** on macOS 27.0 (26A428), Apple M2 Max, including both
previously failing tests. `ProcessingTests` alone ran 13 tests with zero failures. Evidence:
`/tmp/claude-501/.../full-suite.log`, re-runnable with the standard test command in `README.md`.

The recorded root cause was wrong in one specific way, and the correction matters for anyone
re-investigating. The `e5rt` messages name **system** resources, not anything StowKit generates:

```text
[e5rt] Unable to find a valid E5 in provided path
/System/Library/PrivateFrameworks/TextRecognition.framework/Resources/cr_td_model_v3_e5.mlmodelc.bundle/.
Found bundles : { }. Expected : { H14G.N301.bundle H14C.bundle ... universal.bundle jit.bundle }
```

Those directories exist but hold a flat compiled CoreML model (`coremldata.bin`, `model.mil`,
`weights`) instead of the per-hardware sub-bundles the E5 runtime expects, so e5rt declines the
ANE path and Vision falls back. No `com.apple.e5rt.e5bundlecache` exists under StowKit's
container or `~/Library/Caches` at all, so there is no "StowKit generated E5 cache" to repair —
the earlier attempt to preserve/rename one was operating on a directory that does not exist.
The fallback is a logged warning, not a failure: the assertions on recognized text pass.

Cold-start cost is real and worth knowing: the first Vision call in a fresh process took
**46.2 seconds**; the same test warm took **0.5 seconds**. A user's first scanned import can
therefore appear to hang for roughly a minute.

**The provisioned configuration was then tested and also passes.** After the Apple account was
re-authenticated, `ProcessingTests` ran **13 tests with zero failures** against a test host
signed with the real Development iCloud entitlements (`iCloud.com.stowkit.app`), hardened by the
App Sandbox, and verified with `codesign -d --entitlements`. `testVisionReadsImageAndScannedPDF`
passed in 0.528 s; the cold ~25 s Vision warm-up simply landed on whichever test ran first. The
same `e5rt` messages appear and remain non-fatal. Signing, entitlements, and the sandbox
container therefore do **not** reproduce the failure, and no OCR code was changed.

Running the hosted tests in that configuration needs `Config/iCloud.tests.xcconfig`.
`iCloud.local.xcconfig` applies `CODE_SIGN_ENTITLEMENTS` and `INFOPLIST_FILE` to every target,
so `StowKitTests` requests iCloud entitlements that `com.stowkit.tests` is not registered for
and profile creation fails before compiling. The tests config scopes both settings to the app
target through `$(TARGET_NAME)`.

**Still not established.** Why the September 20 post-provisioning run failed. Both plausible
remaining explanations — a transient Vision/ANE state that has since cleared, or an
interaction with that specific run's environment — are unproven, and the original failing
state no longer exists to inspect. If OCR fails again, capture the full `e5rt`/`e5rtError`
output and the exact build configuration before rebuilding anything.

## Developer ID and Production CloudKit verification

September 20, 2026: deployed the four StowKit record types from Development to Production in `iCloud.com.stowkit.app` under Gamergrams. Created a Developer ID provisioning profile for the existing Gamergrams certificate; it has `ProvisionsAllDevices = true` and Production iCloud entitlements.

Version 0.6.0 build 3 was archived and exported with Developer ID, hardened runtime, arm64 and x86_64, no debugging entitlement, and no device restriction. The distribution script now derives an xcconfig to force Production in both the app settings and signed entitlements; command-line overrides alone left the local xcconfig's Development value in the app. The corrected export passed all checks in `scripts/build-distribution.sh`. Apple accepted notarization for both the app (`a115f374-8fa7-4263-84cc-5fcadeae6831`) and DMG (`0cc52cbb-6067-4416-b6ac-8d145b221746`). Both tickets were stapled and validated, and both passed Gatekeeper assessment as Notarized Developer ID. The final DMG was mounted read-only; the contained app passed strict signature, staple, Gatekeeper, architecture, version, and Production configuration checks. The Applications link and final SHA-256 sidecar were verified. DMG SHA-256: `490987f592ee459f853597cad60f5fcfbde708090d1da22e917a31d5b3a9519f`. This does not establish execution on a second physical Mac or resolve the acceptance limitations below.

An explicitly compiled Production runner used an isolated archive and fictional generated data. The first run failed with “Moving downloaded asset failed” during original transfer. A retry with diagnostic reporting passed zone creation, multi-chunk upload, independent hash verification, searchable metadata/text catch-up without materializing the original, byte-identical explicit download, and an edit converging between two local stores. Evidence: `/tmp/stowkit-production-live-retry.log`. This remains a same-Mac, same-account smoke test; two-Mac/two-account sharing and the other acceptance checks below remain unverified. Generated test zones were retained, and no existing user documents were uploaded.

## v0.6.0-alpha.1 packaging

Built version 0.6.0 (build 2) in Release with Gamergrams development provisioning. The compressed DMG passed `hdiutil verify`; it was mounted read-only and the contained app passed `codesign --verify --deep --strict`. Verified both arm64 and x86_64 architectures, expected version and CloudKit Development bundle settings, and the Applications installation link. The embedded development profile includes one Mac and expires September 19, 2027. This is an unnotarized development prerelease, not general public distribution. Packaging does not resolve the OCR and household acceptance limitations below.

## Latest regression status after provisioning

> **Superseded in part.** The OCR diagnosis below misattributes the `e5rt` messages to a
> StowKit-generated cache; no such cache exists. See "macOS 27 OCR regression — not
> reproducible in the shipping build" above. The rest of this entry stands.

The normal signed Release build succeeds and passes strict code-signature verification. A local copy is available at `build/iCloud-development/StowKit.app` (ignored by Git); it includes the expected container, Development environment, and sharing bundle flag. The cloud test runner is excluded from that build.

The post-provisioning full suite ran 95 tests: all cloud tests passed, but two OCR tests failed with six assertions/errors. Vision reported a missing `main_ane/model.anehash` in StowKit's generated E5 cache and `e5rtError` code 13. A supported per-stage CPU retry experiment still failed the real image/scanned-PDF test and was removed; no OCR code change is shipped. An attempt to preserve/rename only the app's generated cache was denied by macOS (`Operation not permitted`), leaving it unchanged. A final targeted rerun of the original OCR implementation completed 13 processing tests with one remaining image/scanned-PDF runtime failure (`/tmp/stowkit-ocr-cache-recovery.log`). The earlier 95-test pass below remains historical evidence, not the latest all-green status. Current OCR runtime recovery requires further verification; original bytes and saved text are retained.

## Live private CloudKit smoke test

September 19, 2026: provisioning succeeded with Gamergrams LLC, bundle `com.stowkit.app`, container `iCloud.com.stowkit.app`, Development environment. The app's signed entitlements and embedded profile were inspected. An unrestricted signing-identity check found valid Apple Development and Gamergrams Developer ID identities; the earlier sandboxed check could not see them. The previously expired Xcode authentication was restored by the user.

The first signed launch exposed missing custom Info.plist keys. The cloud configuration now supplies an explicit Info.plist; a fresh derived-data build includes the container, environment, and `CKSharingSupported`. An explicitly compiled validation runner then used only fictional generated bytes in an isolated archive. It passed live zone creation, upload of an 8 MiB + 137-byte original through multiple CKAssets, independent download/hash verification before metadata publication, metadata/text catch-up into a second local store without an original file, full-text search, explicit byte-identical download, and a second-store metadata edit converging back through CloudKit. Output: `/tmp/stowkit-live-configured.log`. Successful test zone: `StowKit-35BE7271-4B46-43EC-8698-1EDB9987F4D1` (Development).

The two stores ran on one Mac using one account. This does **not** verify a second physical Mac, invitation acceptance, shared-database permissions, revocation, original-owner offline behavior, quota errors, interrupted transfers, or actual network-byte exclusion. No household invitations were sent and no existing user documents were uploaded. Generated test zones are retained for inspection. The normal build excludes the manual runner; see [setup](ICLOUD_SETUP.md) for explicit invocation.

## CloudKit implementation on macOS 27

September 19, 2026: **95 tests passed with zero failures** on macOS 27.0 (26A428), Xcode 27.0 (27A266a), Apple Silicon. The optimized Release build also succeeded. The full suite includes 13 CloudArchiveTests covering searchable remote text without original downloads, thumbnail behavior, concurrent duplicate imports, conditional-save conflicts, exact acknowledgments, account binding, transactional invalid-page rejection, V7→V8 text-queue migration, multiple text batches past blocked extraction, read-only participants, corrupt-original rejection, and expired-token recovery. Apple Foundation Models reported available; the existing on-device inference test passed.

The first full run found a SQLite lock in the raw legacy migration fixture. Releasing the fixture container in an autorelease pool and setting a bounded SQLite busy timeout fixed fixture construction; the subsequent complete run passed. The V8 migration retains the old property mapping to avoid the macOS 27 inherited `hash` accessor collision. Framework logs still include autoShortcut connection failures, SwiftData diagnostics, and Vision model-resource messages; their presence did not fail the assertions.

Native UI smoke verification: the app opened the existing six-document archive on macOS 27, showed its existing list and Trash count, and opened Settings. Settings correctly displayed iCloud off and the requirement for a configured signed build. Before launch, the SQLite database and originals were backed up to `/tmp/StowKit-pre-V8-backup`; all six original SHA-256 values remained identical afterward. This temporary backup is verification evidence, not a durable user backup. No document contents were changed for this smoke check.

**Historical provisioning blocker, resolved by the live smoke test above:** Xcode now launches, but Apple Accounts reports expired authentication; `security find-identity -v -p codesigning` reports zero valid identities. No live container, private/shared sync, invitation, permission revocation, network asset projection, or quota test has passed yet. No document uploads or invitations were sent. See [setup and live acceptance](ICLOUD_SETUP.md). The sections below are historical checkpoints, not descriptions of the current implementation.

## Local sync recovery

September 14, 2026: the expanded Debug suite passes **82 tests with zero failures**, including 12 new recovery tests. The Release build also succeeded. These cover bounded backfill across restart, edits during backfill, rollback without advancing the checkpoint, conservative legacy protections, independent-field merges and search indexing, persisted baselines/cursors, conflict history and resolution, newer local edits invalidating stale resolutions, later remote edits retaining the local alternative, all-or-nothing invalid-page rejection, stale page rejection, unsupported versions/archive identities/memberships, fake fetch retry, and V5 migration preserving a pending operation UUID.

The receiver handles existing local documents and known collection identities only. Backfill, incoming feeds, and conflict resolution are repository/test APIs, not enabled UI features. No iCloud transport, account binding, new remote originals, or eviction is present. The outgoing fake protocol does not yet implement conditional server saves. The prior Core Data diagnostics remain present; all migration assertions pass. No new interactive UI verification is claimed.

## Local sync foundation (earlier slice)

Validated September 14, 2026 with Xcode 26.3 / Swift 6.2.4 on macOS 15.7.3, Apple Silicon. The Debug suite passed **70 tests with zero failures**, including all prior 57 tests and 13 new sync tests. The Release build also succeeded.

New coverage includes persisted/coalesced snapshots across restart; exact-operation acknowledgments preserving newer edits; unchanged-edit suppression; stable collection IDs and explicit membership removals; journal failure rolling back metadata, manual protections, and search receipts; automatic versus explicitly accepted metadata; fake delivery with a lost acknowledgment and idempotent retry; bounded batches and partial acknowledgment; manual/automatic and same-field conflict policies; Trash/Restore and membership merge behavior; V4 migration preserving document metadata, protected fields, saved OCR progress/text, and search receipts without historical upload enqueueing; and missing/wrong-size original rejection without deleting bytes.

These are local tests with generated fixtures. The app does not instantiate the transport, contact CloudKit, upload documents, or evict originals. Fake transport tests establish receipt behavior, not CloudKit save semantics. At that checkpoint, incoming application and conflict persistence were still pending; the recovery section above records their subsequent local implementation. Collection alias migration, download leases, live account sharing, and metadata-only CloudKit fetches remain unverified/unimplemented. No new interactive UI verification is claimed for this slice. The previously documented Core Data model-checksum and array-materialization diagnostics remain present; migration assertions and all tests pass.

## Milestone 6 architecture review

Reviewed September 14, 2026. This milestone changes documentation only. The [iCloud architecture note](ICLOUD_ARCHITECTURE.md) was checked against the current local schemas, explicit `cloudKitDatabase: .none` configuration, import recovery, incremental search journal, and manual-analysis protections. Apple's CloudKit documentation and the installed Xcode 26.3 SDK informed the API choices; the SDK's CKSyncEngine fetch options do not expose asset-field projection.

Checked documentation links to local files and whitespace with `git diff --check`. No application code, schema, entitlements, signing, or user data changed. Builds and tests were not rerun for this documentation-only milestone; the application validation below remains the last executable verification. CloudKit projection, two-account sharing, encrypted fields, transfers, and eviction are proposed and explicitly untested. The note defines the acceptance gates required before shipping them.

## Milestone 5

Validated on September 13, 2026 with Xcode 26.3 / Swift 6.2.4 on Apple Silicon.

## Automated checks

The final run passed all 57 tests with zero failures (17 archive, 13 processing, 12 search, and 15 intelligence tests). Run the shared StowKit scheme's XCTest target using the README command. Tests create and remove their own temporary archives; they do not import personal documents.

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

## Intelligence checks

- High-confidence rule output files a document, updates search, and preserves source identity/path/date.
- Medium-confidence output files; unknown text keeps the document in Inbox. Uncertain reanalysis returns a previously auto-filed document to review.
- Manual edits, cleared summaries, collection choices, and review flags survive pending analysis.
- An edit made while a provider is running wins at commit time.
- Unknown collection names, absent evidence, fabricated issuers, and nonfinite confidence are rejected.
- Long input is bounded and cannot auto-file based only on its excerpt.
- Interrupted analysis requeues; accepting a displayed proposal persists through reopening.
- Cancellation requeues without applying metadata.
- OCR reset invalidates in-flight results; Trash pauses and Restore resumes analysis.
- A failed provider does not block the next job or existing OCR search.
- A real V3 archive migrates to V4 and retains protected metadata while receiving suggestions.
- The production provider falls back successfully on macOS 15.7.3.

The development Mac runs macOS 15.7.3. Foundation Models code builds against the installed macOS 26.2 SDK but its macOS 26 branch cannot execute here. Live Apple model generation, model refusal/context-overflow behavior, and output quality on an eligible macOS 26 Mac remain unverified. The provider test runs a synthetic Apple-model request when that API and model are available; on this host it exercised the production fallback instead. No generated output is claimed as tested Apple-model output.

## Milestone 4 synthetic index benchmark

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

## Native verification — September 14, 2026

Verified with generated, clearly marked fictional fixtures on the unlocked macOS 15.7.3 desktop. The main pass used the Milestone 5 Release build; the review-state fix was rechecked in the corrected Debug build that passed all 57 tests.

- Imported a two-page mixed PDF through the native picker. The inspector reported two pages, one OCR page; View Text displayed embedded text and OCR separately.
- Confirmed high-confidence filing into Insurance and a cleared Inbox; the PDF preview and page-navigation control worked.
- Searched an OCR-only word (`blueberry`) and visually verified its highlighted result snippet. Vision transcribed `bicycle` as `biccle`; the original remained intact. This is an observed OCR accuracy limitation, not an indexing failure.
- Exercised View Text and Copy All. The copy control was activated; clipboard contents were not independently inspected.
- Changed the title, ran Analyze Again, and confirmed the manual title survived.
- Verified ⌘N, global ⌘K, and scoped ⌘F through the native UI.
- Imported a PNG warranty scan. It rendered correctly, was filed under Warranties, and showed the medium-confidence Suggested filing label.
- Visually inspected the Suggestions sheet, including title, collection, tags, summary, evidence, and the explicit replacement explanation; applied the proposal.
- Found and fixed a review-state bug: accepting already-applied suggestions did not protect unchanged fields or clear Suggested filing. Acceptance now explicitly protects the review decision and nonempty suggested fields in the same metadata transaction. The corrected UI clears the row label; reanalysis preserves acceptance. A regression test verifies acceptance also survives later uncertain OCR results.
- Imported a password-protected PDF. It remained in Inbox, displayed an actionable error and Retry, and retained its archived metadata. Retrying safely returned the same locked-PDF error.
- Rebuilt the search index through Settings and successfully searched the image's OCR-only word `tangerine` afterward.
- Quit and relaunched the application; all three documents, edited title, extraction state, and filing results persisted.
- Moved the warranty to Trash and restored it; it returned to Recent with its reviewed state preserved.
- Finished by moving all three new fixtures to recoverable Trash. Recent and Inbox are empty; Trash contains these three plus the two prior QA fixtures. No personal documents were imported or edited.

Load More with a visually populated 50+ document list, Finder mouse dragging, in-flight quit/relaunch on a long OCR job, and a live Apple model remain outside this desktop smoke test. Pagination, interruption recovery, and drop-provider delivery are covered by the automated suite. Apple generation still requires an eligible macOS 26 installation.

The corrected Debug build and 57-test suite succeeded. The corrected Release build also succeeded after a temporary approval-service capacity error, and was launched successfully at the end of verification. It is left open with an empty active library and all QA fixtures recoverable in Trash.

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
