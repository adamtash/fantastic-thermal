#!/bin/zsh
# Build, notarize, and validate a release locally. Does not publish or upload to a website.
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
: "${THERMALBAR_NOTARY_PROFILE:?Set THERMALBAR_NOTARY_PROFILE to an existing notarytool Keychain profile}"
export THERMALBAR_RELEASE=1
(cd "$root_dir" && swift test -c release)
"$root_dir/Scripts/build-app.sh"
app_dir="$root_dir/dist/Fantastic Thermal.app"
zip_path="$root_dir/.build/Fantastic-Thermal-notarization.zip"
ditto -c -k --keepParent "$app_dir" "$zip_path"
xcrun notarytool submit "$zip_path" --keychain-profile "$THERMALBAR_NOTARY_PROFILE" --wait
xcrun stapler staple "$app_dir"
xcrun stapler validate "$app_dir"
THERMALBAR_SKIP_BUILD=1 "$root_dir/Scripts/build-dmg.sh"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
dmg_path="$root_dir/dist/Fantastic-Thermal-$version.dmg"
identity="${THERMALBAR_SIGNING_IDENTITY:-Developer ID Application: ADEM TAS (3F8WPY8D9V)}"
codesign --force --timestamp --sign "$identity" "$dmg_path"
xcrun notarytool submit "$dmg_path" --keychain-profile "$THERMALBAR_NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type execute --verbose=2 "$app_dir"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"
shasum -a 256 "$dmg_path" > "$dmg_path.sha256"
echo "Validated release: $dmg_path"
