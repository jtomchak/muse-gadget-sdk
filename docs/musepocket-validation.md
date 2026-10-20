# MusePocket validation

## 2026-10-20 connected-device diagnostics

- Physical iPhone 16 Pro Max: Debug 0.1.0 (8) discovered and connected to the
  Waveshare using direct CoreBluetooth discovery. A protected GATT read and
  response subscription completed; the app reported `Connected securely`, and
  the user confirmed it worked. The AccessorySetupKit picker remained unable
  to discover it, so this remains a diagnostic configuration.
- The user reported saved cards absent from the gadget and a frozen display.
  Serial heartbeats continued with Wi-Fi/Muse connected. The first JTAG program
  counter mapped to LVGL's flush wait; a subsequent debugger attach reset the
  target, so its stack dump cannot establish the original cause. A no-flash
  JTAG attach after recovery showed normal LVGL and LCD task waits.
- The LCD completion path now retains a completed DMA band in a semaphore,
  using LVGL's flush-wait callback rather than spinning the UI core. The
  regression harness covers early/late callbacks, failed chunks and successive
  bands. This is a candidate fix; a sustained physical freeze retest is pending.
- The gadget now has a Cards page between Tools and Settings. It reads saved
  NVS cards, offers previous/next and scrollable text, refreshes expiry state,
  and defers phone-requested navigation until voice is idle. The previous code
  rendered cards only in the avatar caption. Imported iPhone cards now request
  display after saving as well.
- Fresh automated checks: 10 native XCTest cases and the simulator UI flow
  passed. The 22 optimized Swift package tests, including 12 independent SDK
  WebSocket scenarios, passed. The firmware suite ran 229 tests: 228 passed and one crypto-vector
  test skipped under system Python; rerunning its two-test module with the
  ESP-IDF Python passed both. The shared Noise core test also passed with the
  Homebrew MbedTLS pkg-config path. The desktop LVGL suite passed, including
  empty/populated Cards and voice taking priority, on both 412×412 and
  466×466 builds (the latter with ASan/UBSan). The Waveshare build fits its app
  slot with 45% free, was flashed with hash verification and preserved NVS.
- Physical serial exercise: Moe answered status requests before and after eight
  idle/thinking transitions and a sleep/wake cycle. It remained paired with
  Wi-Fi connected; no panic marker was captured. A final no-flash JTAG sample
  showed LVGL sleeping normally in its worker, rather than spinning in flush
  wait. These observations don't prove sustained touch responsiveness.

Physical card display/navigation, settings persistence, timer controls, battery
and motion behavior, ANCS permission, and live Muse voice over phone cellular
remain separate acceptance checks. A successful build or cloud fixture is not
evidence of those results. Debug 0.1.0 (9) installed, but iOS initially blocked
launch while the phone was locked.

## Initial validation — 2026-10-05

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

## Muse phone relay verification

The Muse engine now compiles the upstream C++ Noise transport into MusePocket with
an Apple CryptoKit backend. Voice notes and typed requests use the SDK's VM
credential discovery, `/v1/noise`, `/chat/subscribe` and `/chat/stream` contracts.
No hosted relay service is required. The independent fixture uses the Python SDK
as its responder, fake account/VM tokens, and loopback WebSockets; it does not
contact a live Muse account or generate an AI answer.

| Check | Result | Scope |
| --- | --- | --- |
| Swift package + independent SDK fixture | 22 tests passed, including 12 WebSocket scenarios | Voice/text request contracts, 15-second recording, VM-token discovery bypass, early replies, unrelated/replayed message isolation, auth rejection, redirect refusal, ciphertext tampering, resets, disconnects, cancellation and deadline |
| Native XCTest | 8 passed on iPhone 17 Pro simulator, iOS 26.1 | Includes decoded BLE note → real loopback Noise connection → native TTS → reply delivery; forced delivery failure persists a completed reply across service restart and retries without a second Muse request |
| Native UI | 1 passed | Existing preview navigation, cards, presets and Assistant screen |
| Shared firmware Noise core host test | 1 passed | Existing C++ core compiles and links with PSA crypto |
| Waveshare firmware | Build succeeded | Apple bridge is outside ESP-IDF's explicit source list; existing board integration remains intact |
| Physical iPhone | Development build 0.1.0 (2) installed and launched | Muse Assistant settings available on Jesse's iPhone 12; no cloud response or physical BLE/speaker result implied |

Reproduce the independent fixture and native suite using
[`ios/tools/test-muse-relay.sh`](../ios/tools/test-muse-relay.sh); examples are in
[`ios/README.md`](../ios/README.md#muse-voice-through-iphone). CI now includes both
fixture runs and triggers on shared C++ transport or Python Noise changes.

**Live acceptance remains pending:** no Waveshare USB serial device was connected
and no live Muse credentials were configured for this run. Real cloud
transcription/model inference, iPhone cellular routing, physical BLE throughput,
and Moe speaker completion have not been verified. For acceptance, turn board
Wi-Fi off, keep phone internet and Bluetooth on, configure Muse credentials in
Assistant, enable the phone relay, record a distinct phrase, and verify both the
correct Muse reply and `reply.played`. Repeat over phone Wi-Fi, then with phone
internet off (saved-note retention), and after a disconnect/reconnect (cached
reply delivery). Do not label the fixture response as a live Muse result.

This work did not export or upload to TestFlight; the user's exact release
provider verification requirement remains in force.
