# Release validation

Release: Fantastic Thermal 1.0.1 (2). Measured on 12 September 2026 on an Apple M3 Max running macOS 26.6.2. This is an arm64 build with a macOS 14 deployment target; Intel and older macOS releases have not been validated on hardware.

## Performance and size

The read-only `thermalbar-probe --benchmark` measures one cold discovery and 100 subsequent snapshots in the same process. The baseline binary was built from the pre-optimization source with the same benchmark harness. Baseline and candidate were run sequentially on the same machine. Both found 44 temperature sensors and two fans.

| Measurement | Baseline | Candidate |
| --- | ---: | ---: |
| Cold discovery | 897.43 ms | 407.97 ms |
| Warm snapshot median | 7.50 ms | 7.51 ms |
| Warm snapshot p95 | 8.36 ms | 8.23 ms |
| App bundle allocated size (`du -sk`) | 2,560 KiB | 2,148 KiB |
| ICNS file | 1,534,245 bytes | 1,039,008 bytes |

This run shows about 55% less cold-discovery time and 16% less allocated bundle size. Warm snapshot time is essentially unchanged in this run; earlier runs varied with system load. These are local measurements, not guarantees for every Mac. App launch latency and sustained energy use have not been measured in a controlled benchmark. No RAM reduction is claimed.

The app links only Apple system frameworks and libraries. The former Swift Charts dependency is absent. Sensor work runs every two seconds on the hardware actor, independently of serialized control requests. Hidden SwiftUI panel content is removed, history is bounded to 10,800 samples, and Canvas renders at most 600 points per series. Unchanged targets use a helper lease rather than repeated RPM writes. Service registration status is checked at most every 30 seconds when enabled, or every 10 seconds otherwise.

## Completed checks

- `swift test -c release`: 22 tests passed, zero failures on the current source.
- Release builds of both app and helper passed. Hardened-runtime Developer ID signatures passed strict, deep verification.
- Tests cover trigger behavior, configuration persistence/normalization, malformed numeric decoding, chart extrema and slice indices, stable targets, firmware target drift, automatic release, partial failures, restore retries, and ownership-journal recovery.
- All eight embedded icon PNGs decode to identical pixels compared with the original icon. Compression preserves PNG metadata and verifies CRCs and decompressed bytes.
- Native preview interactions exercised mode selection and slider changes. Slider and chart accessibility descriptions are present. The live history menu opens and dismisses without closing the panel.
- Production menu-bar artwork was rendered separately for CPU, battery, and the widest fan value (100%). The 34 × 18 pt canvas fits the larger fan and two text rows without changing width between metrics. macOS controls the surrounding status-item spacing.
- Private-key patterns are ignored. No `auth/`, `.p8`, or `.p12` files are present in the app release directory. Ignore behavior was verified in the initialized repository; the private key is untracked.

## Apple distribution checks

`Scripts/release.sh` completed successfully on 12 September 2026. Apple accepted both submissions:

- App: `755043e3-9b63-41d7-8e73-14438cde7e0d`.
- DMG: `4aebb745-6c26-4246-ada7-f2cd8aab7b54`.

Both artifacts passed ticket stapling/validation and Gatekeeper assessment as Notarized Developer ID. The DMG occupies approximately 1.7 MiB. Notarization does not replace live hardware validation.

## Hardware checks and scope

- The approved helper runs as root and authenticated live control succeeded for both fans. Selecting Auto returned both mode bytes and the force-control flag to zero. The current Auto+ profile resumed successfully. Firmware mode and target writes now verify read-back with bounded settling time instead of treating an immediate stale value as a rejected write.
- Validate additional hardware and OS versions before claiming support beyond the tested machine. Live lease recovery passed: after a 22-second SIGSTOP of the app, both fans returned to automatic with the force flag cleared; within ten seconds of SIGCONT, Auto+ control resumed. A privileged-helper crash has not been induced on hardware; crash-journal behavior is covered by tests.

The source is MIT licensed. Private signing credentials and generated artifacts are excluded from Git.
