#!/bin/bash
# Create a production-CloudKit Developer ID export. Credentials remain in Xcode/Keychain.
set -euo pipefail
if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "Usage: $0 TEAM_ID /path/to/iCloud.local.xcconfig /path/to/output-directory [PROFILE_UUID]" >&2
    exit 2
fi
team_id="$1"
cloud_config="$2"
output_dir="$3"
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || { echo "Invalid team ID" >&2; exit 2; }
[[ -f "$cloud_config" ]] || { echo "Cloud configuration not found" >&2; exit 2; }
[[ ! -e "$output_dir" ]] || { echo "Use a new output directory" >&2; exit 2; }
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
profile_uuid="${4:-}"
signing_style=automatic
profile_options=""
export_flags=(-exportArchive -allowProvisioningUpdates)
if [[ -n "$profile_uuid" ]]; then
    [[ "$profile_uuid" =~ ^[A-Fa-f0-9-]{36}$ ]] || { echo "Invalid profile UUID" >&2; exit 2; }
    signing_style=manual
    profile_options="<key>provisioningProfiles</key><dict><key>com.stowkit.app</key><string>$profile_uuid</string></dict><key>signingCertificate</key><string>Developer ID Application</string>"
    export_flags=(-exportArchive)
fi
cat > "$output_dir/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>$team_id</string>
<key>signingStyle</key><string>$signing_style</string>
$profile_options
<key>iCloudContainerEnvironment</key><string>Production</string>
</dict></plist>
PLIST
cloud_config="$(cd "$(dirname "$cloud_config")" && pwd)/$(basename "$cloud_config")"
cat > "$output_dir/Distribution.xcconfig" <<CONFIG
#include "$cloud_config"
DEVELOPMENT_TEAM = $team_id
ENABLE_HARDENED_RUNTIME = YES
STOWKIT_CLOUD_ENVIRONMENT = Production
SWIFT_ACTIVE_COMPILATION_CONDITIONS =
CONFIG
xcodebuild -project StowKit.xcodeproj -scheme StowKit -configuration Release \
    -destination 'generic/platform=macOS' -xcconfig "$output_dir/Distribution.xcconfig" \
    -archivePath "$output_dir/StowKit.xcarchive" -derivedDataPath "$output_dir/DerivedData" \
    DEVELOPMENT_TEAM="$team_id" ENABLE_HARDENED_RUNTIME=YES STOWKIT_CLOUD_ENVIRONMENT=Production \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS= -allowProvisioningUpdates archive
xcodebuild -archivePath "$output_dir/StowKit.xcarchive" \
    -exportPath "$output_dir/export" -exportOptionsPlist "$output_dir/ExportOptions.plist" \
    "${export_flags[@]}"
app_path="$output_dir/export/StowKit.app"
codesign --verify --deep --strict "$app_path"
codesign -d --entitlements - --xml "$app_path" > "$output_dir/entitlements.plist"
security cms -D -i "$app_path/Contents/embedded.provisionprofile" > "$output_dir/profile.plist"
/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$output_dir/entitlements.plist" | /usr/bin/grep -qx Production
/usr/bin/plutil -extract StowKitCloudEnvironment raw "$app_path/Contents/Info.plist" | /usr/bin/grep -qx Production
if /usr/bin/plutil -extract ProvisionedDevices xml1 -o - "$output_dir/profile.plist" >/dev/null 2>&1; then
    echo "Refusing a device-restricted provisioning profile" >&2; exit 1
fi
codesign -d --verbose=4 "$app_path" 2>&1 | /usr/bin/grep 'Authority=Developer ID Application:' >/dev/null
codesign -d --verbose=4 "$app_path" 2>&1 | /usr/bin/grep 'flags=.*runtime' >/dev/null
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$output_dir/entitlements.plist" 2>/dev/null || true)" == true ]]; then
    echo "Refusing an app with debugging entitlement enabled" >&2; exit 1
fi
echo "Developer ID export verified: $app_path"
echo "Notarize and staple the app before creating its distribution DMG."
