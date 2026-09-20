# iCloud setup and live acceptance

Status, September 19, 2026: Gamergrams LLC development signing and the `iCloud.com.stowkit.app` container are provisioned. A live private-CloudKit smoke test passed (multi-chunk original verification, searchable text catch-up without original materialization, explicit download, and bidirectional metadata edits between two isolated stores on this Mac). **Two-account household sharing and two-Mac acceptance are still unverified.** No existing user documents were uploaded and no invitations were sent.

## Provision a development build

1. Sign in again under Xcode → Settings → Apple Accounts. Choose the Apple Developer Program team that owns StowKit. CloudKit requires an active program membership; a free Personal Team is insufficient. See [Apple's CloudKit encryption sample prerequisites](https://github.com/apple/sample-cloudkit-encryption).
2. Register or select a bundle identifier and an iCloud container owned by that team. Enable the CloudKit service for the app identifier and associate the container. The example's `com.stowkit.app` and `iCloud.com.stowkit.app` are defaults, not proof of ownership. Follow [Apple's iCloud configuration instructions](https://developer.apple.com/documentation/xcode/configuring-icloud-services).
3. Copy `Config/iCloud.xcconfig.example` to `Config/iCloud.local.xcconfig` (ignored by Git). Set `DEVELOPMENT_TEAM` and `STOWKIT_CLOUD_CONTAINER`. If the registered app ID differs, also set `PRODUCT_BUNDLE_IDENTIFIER`. Changing the bundle identifier gives the sandbox a different local archive; it does not migrate existing documents.

   The override uses `Config/StowKitCloud-Info.plist` for custom bundle keys; `INFOPLIST_KEY_` overrides alone did not emit these keys on Xcode 27. After changing the Info.plist source, use a fresh derived-data directory or clean build and inspect the resulting bundle.

4. Build the app target with the local override and allow Xcode to obtain signing assets:

```sh
xcodebuild -project StowKit.xcodeproj -scheme StowKit \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/StowKitCloud \
  -xcconfig Config/iCloud.local.xcconfig -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration build
```

5. Inspect the app's embedded provisioning profile and actual signed entitlements. The app ID, team, container, CloudKit service, and `Development` environment must match. The environment in Info.plist must match the signed entitlement. Do not add an entitlement by ad-hoc resigning an unprovisioned app.
6. Sign into iCloud in macOS System Settings. This is separate from Xcode's developer account. Launch the signed app, open Settings, and choose Enable iCloud after reviewing which archive will upload.

Use a separate macOS test user containing only generated fictional documents for acceptance. Keep an offline backup of any existing archive before migration. Enabling iCloud uploads the entire active archive, including Trash and saved extracted text. Sharing grants access to the entire household zone, not selected collections.

The override is applied by the command above; copying the file alone does not configure Xcode's Run action. To use Run with cloud signing, assign the local configuration file to the app configuration in Xcode and confirm the resolved signing settings. Keep personal team settings out of the shared project.

## Development schema

The explicit transport uses these record types in a custom `StowKit-<archive UUID>` zone:

| Type | Fields |
| --- | --- |
| `StowMetadata` | encrypted `metadata` bytes; encrypted `operationID` string |
| `StowChunk` | `asset` CKAsset; encrypted `digest` string |
| `StowOriginal` | encrypted `manifest` bytes |
| `StowText` | encrypted `textHead` bytes |
| System zone-wide share | invitation-only CKShare |

Exercise every type in Development and inspect the resulting schema in CloudKit Console. Encrypted fields must be created as encrypted fields from the start; an existing ordinary field cannot simply be made encrypted later. See [Apple's encryption sample](https://github.com/apple/sample-cloudkit-encryption). The app uses zone changes and exact record IDs; no application record-query indexes are required by the present transport. Metadata change requests deliberately exclude `asset` and `manifest`.

Keep schema experiments in Development. Before distributing a Production build, review and deploy the schema explicitly; changing the configuration's environment string alone does not deploy it. [Apple's schema deployment guide](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema).

## Required live acceptance record

Record app commit, macOS/Xcode versions, signing team, container/environment, test account roles, and results. Do not record passwords, keys, invitation URLs, or real document contents in Git.

- Owner uploads generated PDF and image fixtures, including an original larger than 8 MiB. Cloud manifests appear only after all chunks exist. Independently download and compare SHA-256 and size with the source.
- A second Mac on the same account discovers and opens the archive. Its local library and search receive metadata/text while its Originals folder remains empty. Measure actual network asset traffic on initial fetch, normal refresh, and token reset; source-code projection alone is not acceptance evidence.
- Download explicitly from the viewer, Quick Look, and Open Copy; verify identical bytes. Concurrent requests share one download. Stop the app/network partway through a large transfer, restart, and verify retained chunks resume safely.
- With the importing Mac offline, the second Mac can still fetch the uploaded original from iCloud.
- Create an invitation-only household share using the native panel. The owner chooses the recipient and sends the invitation. Accept on a different iCloud account and verify archive discovery, metadata/text catch-up, and explicit original retrieval.
- Verify read-only participants cannot publish changes, and read-write participants can. Edit separate fields offline on both Macs, then the same manually protected field. Confirm convergence and visible conflict alternatives with the correct document title. Repeat for Trash/Restore and membership removal.
- Import identical bytes under different filenames simultaneously. Verify one cloud document and retained local identity/path on each Mac. Independently create same-name collections and verify separate identities.
- Change account, revoke a participant, and remove the test zone. Confirm synchronization stops, pending local edits survive, and already downloaded originals are preserved. Revocation cannot recall copies a recipient already possesses.
- Exercise offline retries, retry-after/quota failures, and a lost save response. Confirm exact acknowledgments cannot clear newer edits and no error advances the incoming cursor past an unapplied page.
- Reopen a populated older archive after migration; verify original hashes, Trash, protected empty metadata, OCR checkpoints, text, and search. Verify the default unconfigured build still works locally without a network entitlement.

Do not call iCloud ready until these checks pass. Production rollout, a 50,000-document live CloudKit performance run, push delivery, cloud thumbnails, cache eviction/pinning UI, and permanent deletion are separate outstanding work. Locally retained originals currently consume disk space indefinitely.

## Repeatable private-cloud smoke test

The manual runner is excluded from normal builds. To compile it explicitly, use a separate derived-data directory:

```sh
xcodebuild -project StowKit.xcodeproj -scheme StowKit -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/StowKitCloudSmoke \
  -xcconfig Config/iCloud.local.xcconfig -allowProvisioningUpdates \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=STOWKIT_LIVE_VERIFICATION build
/tmp/StowKitCloudSmoke/Build/Products/Debug/StowKit.app/Contents/MacOS/StowKit
```

This special build runs automatically at launch, requires the Development environment, and exits after reporting `STOWKIT_LIVE: SUCCESS` or `FAIL`. It creates a fresh isolated archive and CloudKit zone, uploads 8 MiB + 137 generated bytes plus fictional text, and exercises the real transport with two local stores. The transfer fixture uses the PDF document type but is synthetic bytes; this verifies transport, not PDF rendering or OCR. It never starts the normal library or reads its documents. It leaves its test zone and records in Development for inspection; it does not purge them. Do not distribute this special build. Build normally without the compilation condition for everyday use.

For an explicit Production smoke test, use a separate signing configuration with the installed Developer ID profile, Production environment, and both `STOWKIT_LIVE_VERIFICATION STOWKIT_PRODUCTION_VERIFICATION` compilation conditions. The second flag changes the environment guard to require Production. The runner still uses only generated fictional data and retains its isolated test zone. Never distribute this build. The distribution script clears both flags.

A successful run proves the tested private-cloud flow, not cross-account sharing, off-device availability, measured network-asset exclusion, or all interruption/quota cases in the acceptance checklist.
