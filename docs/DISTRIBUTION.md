# Distribution outside the Mac App Store

A development-signed app only runs on provisioned devices. For deployment to other Macs, export with **Developer ID Application**, enable hardened runtime, use a Developer ID provisioning profile for iCloud, then notarize and staple. Signing alone is not a successful distribution check.

## Build and export

Sign into the owning team in Xcode → Settings → Apple Accounts. Keep the team/container in the ignored `Config/iCloud.local.xcconfig`, as described in [iCloud setup](ICLOUD_SETUP.md). From the repository root:

```sh
scripts/build-distribution.sh YOURTEAMID Config/iCloud.local.xcconfig build/distribution
```

Use an unused output directory. The script creates a derived xcconfig that overrides the local Development environment, archives the normal Release app, explicitly disables the live-verification compilation condition, exports using `developer-id`, and checks production environment consistency, Developer ID authority, hardened runtime, and absence of a device list in the profile. Xcode needs a valid account session to obtain a Developer ID profile; a cached development profile does not substitute for it.

If automatic export cannot refresh an Xcode account, download a Developer ID profile for the same app and signing certificate from Apple Developer, install it in Xcode’s provisioning-profile directory, and pass its UUID as the optional fourth argument. This selects manual export with the installed profile and does not require an account refresh.

## Production iCloud

Developer ID exports use the Production CloudKit environment. Review the schema diff in CloudKit Console for the correct team and `iCloud.com.stowkit.app`, and deploy the Development schema before validating Production sync. This deploys schema, not test records. Development and Production archives are separate; an existing Development binding must not be silently redirected to Production. The app preserves that binding and reports a configuration mismatch.

Before claiming production iCloud readiness, validate an isolated fictional archive against Production and perform the two-account acceptance checks in [iCloud setup](ICLOUD_SETUP.md). Publishing an installable signed binary does not establish household-sharing correctness.

## Notarize, package, and verify

Use an existing notarytool Keychain profile authorized for the signing team. Never place credentials in the repository or shell command history. Apple's Xcode Organizer workflow is also available if no command-line profile is configured.

```sh
scripts/notarize.sh build/distribution/export/StowKit.app YOUR_NOTARY_PROFILE
scripts/package-dmg.sh build/distribution/export/StowKit.app VERSION build/releases
codesign --sign 'Developer ID Application: YOUR COMPANY (YOURTEAMID)' \
  --timestamp build/releases/StowKit-VERSION.dmg
scripts/notarize.sh build/releases/StowKit-VERSION.dmg YOUR_NOTARY_PROFILE
(cd build/releases && shasum -a 256 StowKit-VERSION.dmg > StowKit-VERSION.dmg.sha256)
```

Then write the Sparkle appcast and attach it to the release as `appcast.xml` with the DMG and checksum. The app's feed is `https://github.com/cpkess/StowKit/releases/latest/download/appcast.xml`, so every release must carry one:

```sh
scripts/make-appcast.sh build/releases/StowKit-VERSION.dmg VERSION BUILD
```

It refuses an unstapled DMG and signs with the EdDSA key in the Keychain (account `stowkit`).

The final checksum must be generated **after** signing and stapling the DMG. Preserve the notarization result JSON with local build evidence. Mount the final image read-only, verify the contained app signature and staple, and assess it with Gatekeeper before uploading the DMG and checksum to GitHub. Do not replace a published artifact with an unnotarized build or ask users to bypass Gatekeeper.

References: [Apple Developer ID](https://developer.apple.com/developer-id/), [notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Xcode Developer ID export](https://help.apple.com/xcode/mac/current/en.lproj/dev88332a81e.html).
