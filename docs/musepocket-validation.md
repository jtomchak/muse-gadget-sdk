# MusePocket validation

## 2026-10-20 iPhone transcription and text requests

At the user's request, Muse-mode processing now transcribes the saved recording
on iPhone with the existing on-device Speech recognizer and sends only its text
to Muse. The transcript is persisted before network activity, displayed as
**You said**, and reused for network retries. Empty recognition retains the
recording and produces an explicit error. Credentials are checked before asking
for Speech permission. Saved replies still bypass transcription and network
requests when retrying Bluetooth delivery.

Five native MuseAssistantTests pass against the independent SDK fixture. The
fixture validates the exact text request and returns its text-specific reply;
these tests cover native speech rendering/cached delivery, saved transcript reuse
after network failure, empty transcription without a Muse request, missing
credentials, and paired-gadget authorization. The tests inject transcript text;
they do not claim live Apple Speech recognition or a real Muse cloud reply.
All 22 optimized core tests also passed, including 12 SDK WebSocket scenarios.

Processing status now distinguishes local transcription, Muse text submission,
reply speech generation and Bluetooth delivery. Opt-in logs contain stage names
only, not transcripts or audio. Cancellation includes transcription and native
reply speech; operation identities reject callbacks from earlier cancelled
recognition/rendering tasks. On-device recognition has a 45-second deadline and
reply speech rendering a 30-second deadline. Debug 0.1.0 (15) was built for the
personal team, installed and launched on MeowSuperMax. Live recognition and
text-request acceptance remain pending.

## 2026-10-20 authorization from the paired gadget

Added explicit **Use Moe’s Muse connection** in Assistant. Its protected
`muse.authorize` RPC uses the SDK's existing paired-device VM lookup/refresh,
selects Moe's preferred/default VM, and returns only that VM credential with
the paired Noise host. Device account/refresh credentials remain on Moe. The
connection must still be secure and have the same generation after the lookup;
serialized buffers and temporary token copies are cleared. No token is added to
snapshots or diagnostics. Native validation precedes host-scoped Keychain writes
and preference changes. The existing voice inbox is retained for retry.

The production-body C regression covers missing pairing/Wi-Fi, insecure/stale
connections, lookup failure, absent VM/token, disconnect/generation changes
during lookup, explicit RPC dispatch, secret clearing, and a normal snapshot
without credentials under ASan/UBSan. All three native MuseAssistantTests passed,
including exact VM/host Keychain handoff, invalid handoff leaving prior state
intact, missing-credential reporting, and SDK fixture voice/cached retry.
All 232 firmware host tests passed with no skips. The Waveshare build and
app-only flash passed with hash verification and a healthy post-flash heartbeat.
Debug 0.1.0 (14) was installed/launched on MeowSuperMax under personal team
NSLC4354J7. Physical authorization and a subsequent live Muse
voice reply with board Wi-Fi off remain pending. This flow requires temporary
board Wi-Fi for authorization and later renewal; it is not an automatic,
permanent cellular login. No additional official Muse pairing is required.

## 2026-10-20 received voice and authentication blocker

After the Base64 fix, the physical iPhone capture received all fragments and
assembled the complete 32,000-byte recording through `voice.end`, with contiguous
chunk offsets and no packet error. The user confirmed the recording appeared
with a Process button, then reported the status `Configure Muse voice credentials
in Assistant first`. This verifies the board-to-phone BLE audio path. It does
not verify cloud transcription or reply delivery: the companion has no configured
Muse account/device credential, and official Muse gadget pairing does not
currently provision the companion's Keychain.

Voice processing failures now propagate to the app's existing alert, and a
persistent transfer-status button opens Assistant from any tab while a recording
is queued or processing. Missing credentials leave the recording intact. The two
native MuseAssistantTests passed, including independent SDK fixture reply/audio
and cached retry, and an assertion that a missing credential reports the failure.
These fixture results are separate from the still-blocked live Muse request.

## 2026-10-20 Bluetooth voice chunk encoding

With Moe's Wi-Fi off, the user reported `A Bluetooth packet was missing` while
sending a voice request to MusePocket. Release 11's opt-in metadata capture
showed every GATT fragment in order, including `voice.begin`, every audio offset
and `voice.end`. The phone's accumulated audio stayed at zero from the first
chunk. This was an audio-content error rather than an observed BLE packet gap.

The firmware passed capacity 1368 for a 1369-byte Base64 buffer. A full 1024-byte
chunk needs 1368 encoded characters plus the terminating NUL; Mbed TLS rejected
the call and returned required capacity 1369. The ignored return code then led
to `text[1369] = 0`, a stack-buffer overflow, and invalid chunk contents.
The sender now passes the full capacity and checks both the return code and
written length before using the output. Encoding failure aborts the transfer.

The new production-body test links real Mbed TLS and cJSON, decodes and compares
all emitted audio bytes, and runs with ASan/UBSan. It covers odd sample counts,
full 1024-byte chunks, tail chunks, the 15-second maximum, encoding failure and
send failure. The old code fails this test with a stack-buffer overflow; the
fixed code passes. All 231 firmware host tests passed with no skips. The
Waveshare build passed with 45% app-slot space free; the app-only flash was
hash-verified, preserved NVS, and the post-flash heartbeat showed no panic marker.

Debug 0.1.0 (12) was signed with personal team NSLC4354J7 and installed on
MeowSuperMax as requested. Packet diagnostics require the explicit launch
environment `MUSE_BLE_DIAGNOSTICS=1`; they log indexes, counts and offsets,
never audio contents or credentials. Physical board-to-phone retry succeeded as
recorded above; complete cellular Muse voice acceptance awaits authentication.

## 2026-10-20 Release install and bonded reconnect

Release 0.1.0 (10) was development-signed under the verified personal team,
installed on MeowSuperMax and launched; CoreDevice separately confirmed its
process remained running. It uses the working direct CoreBluetooth configuration.
No TestFlight upload was performed.

The user then saw `Resources are insufficient` immediately after connection.
A live, no-flash JTAG capture showed the companion initialized with an empty
command queue, but both cached security flags were false. The current NimBLE
descriptor for that same connection was encrypted, authenticated and bonded
with a 16-byte key. Protected readiness reads succeeded, while the worker
rejected the first command; the generic GATT error mapping hid this distinction.

Protected companion reads/writes now check the exact active connection's current
encrypted/authenticated state and synchronize both caches before readiness or
queue admission. A bond alone never grants access; missing encryption,
authentication, a wrong handle or failed descriptor lookup remains rejected.
The regression test covers these states plus an actually full queue. All 230
firmware host tests passed with no skips, and the Waveshare build and app-only
flash passed with hash verification and NVS preserved. After enabling Phone
setup and reconnecting, the user confirmed the Release dashboard loaded its
device values without the resource error. This verifies the attended reconnect
and initial request/readback path.

The display freeze remains unresolved: after the user's repeat report, a fresh
capture showed LVGL and LCD/input tasks running normally, no DMA chunks pending,
and the screen state awake. The user rebooted with the physical buttons. This
does not establish the panel/touch fault's cause or prove it is fixed.

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
