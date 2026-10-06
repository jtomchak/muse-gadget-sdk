# MusePocket validation — 2026-10-05

These are local results for the MusePocket implementation, using ESP-IDF 6.0.1,
Xcode 27 and Swift 6.4. CI configuration is included; remote CI results are separate.

| Check | Result | Scope |
| --- | --- | --- |
| ESP32 host suite | 227 tests passed, no skips | SDK regressions; production framing/model/codec, initialization/authentication gate, ANCS parsing, tilt and streamed OTA checksums |
| Swift package | 13 tests passed, including parameterized cases | Wire fixtures, MTU fragmentation, CRC/order/expiry limits, settings and ADPCM/WAV |
| Native iOS unit tests | 6 passed | Preview state/persistence, timer/card flow, settings rejection, UIKit RGB565 conversion, streamed HTTP limits and endpoint-bound Keychain accounts |
| Native UI test | 1 passed on iPhone 17 Pro, iOS 26.1 | Navigation and preset/card editing, explicitly labelled preview mode |
| iPhone target | Build succeeded, unsigned arm64 | Actual device architecture; no signing, installation or physical execution claimed |
| Waveshare 1.75C firmware | Build succeeded; 45% OTA partition free | Optimized experience, phone BLE service, ANCS client and board integration |
| AIPI firmware | Build succeeded; 48% OTA partition free | Other full-UI board with companion feature disabled |
| Default ESP32-C5 firmware | Build succeeded; 19% OTA partition free | SDK without Muse UI |
| LVGL simulators | Both passed: 412×412 and 466×466 | Production screens/tools/clock; 466 build includes ASan/UBSan |
| Patch whitespace | Passed | `git diff --check` |

The original six optimizations were implemented in order in earlier commits.
This change retains them and adds the native companion, phone controls, gesture
preferences, cards, notification mirroring and voice assistance.

## Reproduce software checks

From the repository root:

```sh
swift test --package-path ios/MusePocketCore
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/MusePocket.xcodeproj -scheme MusePocket \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.1' \
  -derivedDataPath build/MusePocket CODE_SIGNING_ALLOWED=NO test
xcodebuild -project ios/MusePocket.xcodeproj -scheme MusePocket \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/MusePocketDevice CODE_SIGNING_ALLOWED=NO build
```

Use an installed simulator if its name or OS differs. For firmware builds, use
the existing [board setup instructions](../esp32/AGENTS.md) with ESP-IDF 6.0.1.
The host suite runs from `esp32` with:

```sh
python -m unittest discover -s tests -p 'test_*.py' -v
```

On this Mac the suite used `/usr/bin/clang` and `/usr/bin/clang++` through `CC`
and `CXX`, plus Homebrew's MbedTLS pkg-config paths. cJSON comes from the SDK's
managed dependencies. The workflows fetch dependencies before testing.

## Evidence boundary

Initial validation used no physical ESP32 or iPhone. Secure pairing, background restoration,
ANCS permission behavior, native Speech/Foundation Models, real relay responses,
voice/audio timing, NVS power-cycle persistence, OTA boot and battery/panel
measurements remain the [physical acceptance checklist](musepocket-protocol.md#physical-acceptance-still-required).
No hardware was flashed, no eFuses changed, and no hosted assistant was deployed.

## Connected iPhone development test

A development-signed Debug build of MusePocket 0.1.0 (1) was subsequently
installed and launched on Jesse's physical iPhone 12 running iOS 26.1. CoreDevice
confirmed the installed bundle `com.jtomchak.musepocket` and a running process.
All six native XCTest cases passed on this phone.

The UI test runner timed out while enabling device automation before its test
could start. This is not a passed physical UI test; the app was relaunched in
normal mode for manual testing. The simulator UI flow remains separately verified.
No BLE pairing, speech/model, relay response or ANCS acceptance result is implied.

This was direct development installation, with no TestFlight export or upload.
The requested App Store Connect provider remains subject to explicit verification
before any release operation.

During this check, GitHub's Linux jobs exposed two portability issues: POSIX
time declarations in the standby simulator and an omitted math-library link in
the initialization test. The patch adds the POSIX feature declaration and `-lm`.
After these fixes, all 227 host tests passed without skips, the Waveshare
firmware rebuilt successfully, and the ASan/UBSan simulator passed. GitHub
MusePocket iPhone CI passed for commit `4ca6739`; the corrected Linux jobs
require a fresh run.
