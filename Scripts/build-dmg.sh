#!/bin/zsh
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$root_dir/dist/Fantastic Thermal.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root_dir/Resources/Info.plist")"
dmg_path="$root_dir/dist/Fantastic-Thermal-$version.dmg"
staging_dir="$root_dir/.build/Fantastic-Thermal-DMG"

if [[ "${THERMALBAR_SKIP_BUILD:-0}" != "1" ]]; then
    "$root_dir/Scripts/build-app.sh"
fi

rm -rf "$staging_dir" "$dmg_path"
mkdir -p "$staging_dir"
cp -R "$app_dir" "$staging_dir/Fantastic Thermal.app"
ln -s /Applications "$staging_dir/Applications"

hdiutil create \
    -volname "Fantastic Thermal" \
    -srcfolder "$staging_dir" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$dmg_path"

rm -rf "$staging_dir"
echo "Built $dmg_path"
