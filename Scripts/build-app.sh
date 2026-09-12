#!/bin/zsh
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
# --show-bin-path only prints a path; it does not compile the app.
(cd "$root_dir" && swift build -c release --product ThermalBar -Xlinker -dead_strip)
bin_dir="$(cd "$root_dir" && swift build -c release --show-bin-path)"
(cd "$root_dir" && swift build -c release --product ThermalBarHelper -Xlinker -dead_strip)
package_dir="$(mktemp -d "$root_dir/.build/package.XXXXXX")"
app_dir="$package_dir/Fantastic Thermal.app"
mkdir -p "$root_dir/dist" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Library/LaunchDaemons"
# The prebuilt ICNS is pixel-verified against the source artwork. Packaging
# does not invoke Xcode's pngcrush, which crashes intermittently on macOS 26.
cp "$root_dir/Resources/ThermalBar.icns" "$app_dir/Contents/Resources/ThermalBar.icns"

cp "$bin_dir/ThermalBar" "$app_dir/Contents/MacOS/ThermalBar"
cp "$bin_dir/ThermalBarHelper" "$app_dir/Contents/MacOS/ThermalBarHelper"
cp "$root_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$root_dir/Resources/com.thermalbar.app.helper.plist" \
    "$app_dir/Contents/Library/LaunchDaemons/com.thermalbar.app.helper.plist"

# SwiftPM's release configuration enables -O, but it intentionally leaves
# symbols in the executable. Remove debug and local symbols before signing;
# this keeps the distributed bundle small without weakening optimization.
strip -Sx "$app_dir/Contents/MacOS/ThermalBar"
strip -Sx "$app_dir/Contents/MacOS/ThermalBarHelper"

preferred_identity="${THERMALBAR_SIGNING_IDENTITY:-Developer ID Application: ADEM TAS (3F8WPY8D9V)}"
if security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"$preferred_identity\""; then
    echo "Signing with $preferred_identity"
    codesign --force --options runtime --timestamp \
        --sign "$preferred_identity" --identifier com.thermalbar.app.helper \
        "$app_dir/Contents/MacOS/ThermalBarHelper"
    codesign --force --options runtime --timestamp \
        --sign "$preferred_identity" --identifier com.thermalbar.app "$app_dir"
else
    if [[ "${THERMALBAR_RELEASE:-0}" == "1" ]]; then
        echo "Release requires a valid Developer ID Application signing identity." >&2
        exit 1
    fi
    echo "Developer ID certificate not found; using an ad-hoc signature (monitoring only)"
    codesign --force --sign - --identifier com.thermalbar.app.helper \
        "$app_dir/Contents/MacOS/ThermalBarHelper"
    codesign --force --sign - --identifier com.thermalbar.app "$app_dir"
fi

codesign --verify --strict --deep --verbose=2 "$app_dir"
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_dir/Contents/Info.plist" >/dev/null
destination="$root_dir/dist/Fantastic Thermal.app"
if [[ -d "$destination" ]]; then
    backup_dir="$(mktemp -d "$root_dir/.build/previous-app.XXXXXX")"
    mv "$destination" "$backup_dir/Fantastic Thermal.app"
fi
mv "$app_dir" "$destination"
rmdir "$package_dir"
echo "Built $destination"
du -sh "$destination"
