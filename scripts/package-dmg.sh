#!/bin/bash
# Package an already signed app without altering its signature or entitlements.
set -euo pipefail
if [[ $# -ne 3 ]]; then
    echo "Usage: $0 /path/to/StowKit.app version /path/to/output-directory" >&2
    exit 2
fi
app_path="$1"
release_version="$2"
output_dir="$3"
[[ "$release_version" =~ ^[0-9A-Za-z.-]+$ ]] || { echo "Invalid version" >&2; exit 2; }
[[ -d "$app_path/Contents" ]] || { echo "App bundle not found" >&2; exit 2; }
/usr/bin/codesign --verify --deep --strict "$app_path"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
dmg_path="$output_dir/StowKit-$release_version.dmg"
[[ ! -e "$dmg_path" ]] || { echo "Output already exists: $dmg_path" >&2; exit 2; }
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/StowKit-dmg.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
/usr/bin/ditto "$app_path" "$staging_dir/StowKit.app"
ln -s /Applications "$staging_dir/Applications"
/usr/bin/hdiutil create -volname "StowKit $release_version" -srcfolder "$staging_dir" -format UDZO "$dmg_path"
/usr/bin/hdiutil verify "$dmg_path"
(cd "$output_dir" && /usr/bin/shasum -a 256 "StowKit-$release_version.dmg" > "StowKit-$release_version.dmg.sha256")
echo "$dmg_path"
