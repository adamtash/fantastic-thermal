# Fantastic Thermal

A small, native macOS menu-bar utility for temperatures and fan control. Requires macOS 14 or later. No third-party runtime, network telemetry, or background rendering loop.

## Use

Open the app, then click its fan/temperature item in the menu bar. Right-click the item for Open and Quit. Reopening the app restores a menu-bar item that was removed.

- **Auto** stops this app's custom control and returns its claimed fans to macOS.
- **Fixed** requests a percentage of each fan's firmware range. 0% is the firmware minimum, not necessarily a stopped fan.
- **Auto+** combines linear or parabolic temperature curves with the last observed automatic target as a floor. The strongest rule wins; percentages are not added together. This floor is a historical observation, not a continuously updated macOS thermal recommendation.
- **Auto+ gradual cooldown** raises the target immediately when more cooling is requested. Lower demand must persist for 20 seconds before ramp-down is allowed; the first decrease follows after a five-second ramp interval. Targets then decrease by at most five percentage points of the firmware range per step, with steps at least five seconds apart. Downward changes below one percentage point are ignored. A rebound of one point from the lowest recent demand restarts the cooling hold, even if the fan target is still higher. Updates more than ten seconds apart restart the hold and never accumulate a large drop. Firmware limits and the Auto floor still apply. Explicit profile edits, mode switches, and control recovery start a new response session; Fixed speed and handing control back to Auto remain immediate.
- **Separate power profiles** lets laptops use one Auto, Fixed, or Auto+ configuration on the power adapter and another on battery. A common setup is custom control while plugged in and macOS Auto on battery. Power changes are detected without battery polling, briefly debounced for docks, and rechecked after wake.
- Trigger fan ranges now start at **0%**. As with Fixed mode, 0% means the fan's firmware-reported minimum RPM; the app never writes a target below that limit.
- A bounded six-hour history offers 10m, 30m, 1h, 3h, and 6h windows. Each plot preserves short peaks while rendering at most 600 points per series. Changing the primary sensor starts a new history so two sensors are not joined as one line.
- Fanless and unsupported machines provide monitoring where sensors are available. Missing data is shown as unavailable, never as a fabricated RPM.

The first custom-control request registers a privileged helper. If macOS asks, approve it in System Settings → General → Login Items & Extensions. Older installed helpers may require **Reinstall** after an upgrade. Monitoring works without helper approval.

## Performance

Sensor reads run off the main actor every two seconds. Hardware metadata is cached, unrelated SMC keys are skipped during metadata discovery, and numerical readings decode directly from the fixed SMC response buffer. Control requests run separately and serially: rapid edits replace queued settings without delaying sensor updates, and slider drags apply only after the drag ends. Preference writes are debounced and flushed on normal quit. Legacy settings migrate to the adapter profile automatically; undecodable settings are preserved in a recovery copy instead of being silently discarded.

The closed panel has no SwiftUI content tree to redraw. Its menu-bar image only changes when the displayed metric changes; metric cycling uses a single three-second timer. The chart uses Canvas paths with common coordinates for both scales. There are no continuously animated fans, third-party chart dependencies, or bundled Swift runtime copies.

See [validation results](../VALIDATION.md) for measurements, test coverage, and platform limitations.

## Build and test

```sh
swift test -c release
Scripts/build-app.sh
open "dist/Fantastic Thermal.app"
```

The packaging script explicitly builds both executables with release optimization and dead stripping, strips debug/local symbols, includes a pixel-verified, losslessly compressed icon, signs the helper separately, then signs and verifies the outer bundle. By default it builds only the host architecture to keep downloads small. The app is not sandboxed because it uses the private AppleSMC IOKit interface; distribution is through Developer ID, outside the Mac App Store.

```sh
# Read-only hardware measurement; never writes a fan target.
swift run -c release thermalbar-probe --benchmark

# Isolated UI demo: sample data; does not persist control settings or contact the helper.
open -n "dist/Fantastic Thermal.app" --args --preview

# Local disk image (not a public release until notarized).
Scripts/build-dmg.sh
```

## Public release

Set `THERMALBAR_SIGNING_IDENTITY` to your Developer ID Application identity if different from the default. Configure a notarytool Keychain profile using an App Store Connect API key, or run `Scripts/setup-notarization.command` for interactive app-specific-password setup. Private keys belong outside source control; `auth/` and `*.p8` are ignored and never copied into the app or DMG.

```sh
THERMALBAR_NOTARY_PROFILE=thermalbar-notary Scripts/release.sh
```

This runs release tests, requires Developer ID signing, notarizes and staples the app, creates and notarizes/staples the DMG, checks Gatekeeper acceptance, and writes a SHA-256 checksum. It does not publish the build to a website. Do not distribute a candidate until all release checks have passed.

## Control recovery

The helper authenticates XPC peers using the same Developer ID team and the expected identifier. Each fan target is independently validated against firmware limits. Requests are serialized, partial failures attempt to release claimed fans, and unchanged targets renew a lease without repeated RPM writes. A lost connection releases claimed fans; a stalled app's lease expires after 15 seconds (checked every five seconds). An ownership journal under `/var/run` allows a launchd-restarted helper to release fans claimed before a crash. Journal writes occur only when ownership changes.

Firmware behavior differs by Mac model. Automatic release is best effort when hardware or the OS is unavailable; the app cannot guarantee recovery during power loss or an OS failure. Test the intended hardware and macOS versions before expanding the supported-device claims. Keep other fan-control utilities stopped while using custom control.
