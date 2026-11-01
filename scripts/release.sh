#!/bin/bash
# Developer ID release of the SwiftPM app (the WidgetKit build is separate).
set -euo pipefail

cd "$(dirname "$0")/.."

case "${SIGN:-}" in
    "Developer ID Application: "*) ;;
    *) echo 'Set SIGN="Developer ID Application: Name (TEAMID)" for a public release.' >&2; exit 1 ;;
esac
if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo 'Set NOTARY_PROFILE to a notarytool Keychain profile (see README.md).' >&2
    exit 1
fi

# Check credentials before rebuilding or replacing any release artifacts.
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null

staging=$(mktemp -d "${TMPDIR:-/tmp}/barttery-release.XXXXXX")
trap 'rm -rf "$staging"' EXIT

${MAKE:-make} build SIGN="$SIGN" SIGN_FLAGS="--options runtime --timestamp"
codesign --verify --deep --strict --verbose=2 Barttery.app

# Notarize and staple the app itself so it also works when copied out of the DMG.
ditto -c -k --keepParent Barttery.app "$staging/Barttery.zip"
notarize() {
    local result="$staging/notary-result.plist"
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format plist > "$result"
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$result")" != Accepted ]; then
        cat "$result" >&2
        echo 'Notarization failed. Use notarytool log with the submission ID above.' >&2
        exit 1
    fi
}
notarize "$staging/Barttery.zip"
xcrun stapler staple Barttery.app
xcrun stapler validate Barttery.app
spctl --assess --type execute --verbose=2 Barttery.app

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
case "$version" in
    ''|*[!0-9.]*) echo "Invalid release version: $version" >&2; exit 1 ;;
esac
dmg="Barttery-$version.dmg"
mkdir "$staging/image"
ditto Barttery.app "$staging/image/Barttery.app"
ln -s /Applications "$staging/image/Applications"
hdiutil create -volname Barttery -srcfolder "$staging/image" -format UDZO "$staging/$dmg"
codesign --force --sign "$SIGN" --timestamp "$staging/$dmg"
codesign --verify --strict --verbose=2 "$staging/$dmg"
notarize "$staging/$dmg"
xcrun stapler staple "$staging/$dmg"
xcrun stapler validate "$staging/$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$staging/$dmg"

# Only replace a previous DMG once the new release passes every check.
mv -f "$staging/$dmg" "$dmg"
echo "=> Signed and notarized $dmg"
