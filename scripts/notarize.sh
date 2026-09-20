#!/bin/bash
# Submit a signed app or DMG using an existing notarytool Keychain profile.
set -euo pipefail
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 /path/to/StowKit.app-or.dmg KEYCHAIN_PROFILE" >&2
    exit 2
fi
artifact_path="$1"
notary_profile="$2"
[[ -e "$artifact_path" ]] || { echo "Artifact not found" >&2; exit 2; }
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/StowKit-notary.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
case "$artifact_path" in
    *.app)
        codesign --verify --deep --strict "$artifact_path"
        codesign -d --verbose=4 "$artifact_path" 2>&1 | /usr/bin/grep 'Authority=Developer ID Application:' >/dev/null
        codesign -d --verbose=4 "$artifact_path" 2>&1 | /usr/bin/grep 'flags=.*runtime' >/dev/null
        ditto -c -k --keepParent "$artifact_path" "$work_dir/StowKit.zip"
        submission_path="$work_dir/StowKit.zip"
        ;;
    *.dmg)
        codesign --verify --strict "$artifact_path"
        submission_path="$artifact_path"
        ;;
    *) echo "Expected a signed .app or .dmg" >&2; exit 2 ;;
esac
result_path="${artifact_path}.notarization.json"
xcrun notarytool submit "$submission_path" --keychain-profile "$notary_profile" \
    --wait --output-format json > "$result_path"
status="$(/usr/bin/plutil -extract status raw "$result_path")"
if [[ "$status" != Accepted ]]; then
    echo "Notarization was not accepted. See $result_path" >&2
    exit 1
fi
xcrun stapler staple "$artifact_path"
xcrun stapler validate "$artifact_path"
case "$artifact_path" in
    *.app) spctl --assess --type execute --verbose=2 "$artifact_path" ;;
    *.dmg) spctl --assess --type open --context context:primary-signature --verbose=2 "$artifact_path" ;;
esac
echo "Notarized, stapled, and accepted by Gatekeeper: $artifact_path"
