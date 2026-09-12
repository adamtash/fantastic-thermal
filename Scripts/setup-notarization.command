#!/bin/zsh
set -euo pipefail
printf '%s\n' 'Create an app-specific password at https://account.apple.com → Sign-In and Security → App-Specific Passwords.'
printf '%s\n' 'Name it Fantastic Thermal notarization. Enter it only at the hidden password prompt below.'
read 'thermal_apple_id?Apple Account email: '
read 'thermal_team_id?Developer Team ID [3F8WPY8D9V]: '
thermal_team_id="${thermal_team_id:-3F8WPY8D9V}"
xcrun notarytool store-credentials thermalbar-notary --apple-id "$thermal_apple_id" --team-id "$thermal_team_id"
printf '%s\n' 'Saved and validated Keychain profile: thermalbar-notary. Tell Codex that setup is complete.'
read 'thermal_done?Press Return to close.'
