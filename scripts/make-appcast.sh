#!/bin/bash
# Writes the Sparkle appcast for one release, signed with StowKit's EdDSA key (Keychain account
# "stowkit"). Upload the result to the GitHub release as `appcast.xml`: the app's feed is
# https://github.com/cpkess/StowKit/releases/latest/download/appcast.xml, so every release needs one.
# Usage: scripts/make-appcast.sh <notarized, stapled DMG> <version> <build> [output]
set -euo pipefail
dmg="$1"; version="$2"; build="$3"; output="${4:-$(dirname "$dmg")/appcast.xml}"
sign_update="${SPARKLE_BIN:-}"
if [[ -z "$sign_update" ]]; then
    sign_update="$(find build /tmp/StowKitDerived -path '*artifacts/sparkle/Sparkle/bin/sign_update' -type f 2>/dev/null | head -1)"
else
    sign_update="$sign_update/sign_update"
fi
[[ -x "$sign_update" ]] || { echo "sign_update not found; build once or set SPARKLE_BIN" >&2; exit 1; }
xcrun stapler validate "$dmg" >/dev/null || { echo "Refusing an unstapled DMG: notarize it first" >&2; exit 1; }
signature="$("$sign_update" --account stowkit "$dmg")"
[[ "$signature" == *'sparkle:edSignature='* ]] || { echo "Signing failed" >&2; exit 1; }
name="$(basename "$dmg")"
cat > "$output" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>StowKit</title>
    <item>
      <title>StowKit $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/cpkess/StowKit/releases/tag/v$version</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/cpkess/StowKit/releases/download/v$version/$name" type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$output"
echo "Wrote $output"
