# MusePocket

Native iPhone companion for Moe on the Waveshare ESP32-S3 Touch AMOLED 1.75C.
SwiftUI owns the interface. CoreBluetooth, AccessorySetupKit, EventKit, Speech,
AVFoundation, Foundation Models and Keychain provide native services; UIKit
handles image conversion and the share sheet. Firmware framing is portable C++;
board/audio integrations remain alongside the SDK's existing C drivers.

## Open and run

Open `MusePocket.xcodeproj`, select the MusePocket scheme and an iPhone simulator.
For a physical iPhone, select your Apple development team in Signing & Capabilities,
use a unique bundle identifier if necessary, then run. No development team or
signing secrets are committed. Minimum iOS 18; Xcode 26 or newer enables compiling
Apple Foundation Models support. The project was validated with Xcode 27.

The checked-in project is generated from `project.yml`:

```sh
brew install xcodegen
xcodegen generate --spec ios/project.yml
swift test --package-path ios/MusePocketCore
xcodebuild -project ios/MusePocket.xcodeproj -scheme MusePocket \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For app/unit/UI tests, replace the destination with an installed iPhone simulator
and the final `build` action with `test`. UI tests launch with `--preview`; that
explicitly labelled mode uses sample device state and sends no Bluetooth commands.
Ordinary launches require a real Moe. It does not substitute preview state when a
connection or transfer fails.

## Connect Moe

1. Build the fork's Waveshare 1.75C firmware using ESP-IDF **6.0.1** and the existing
   [board instructions](../esp32/devices/AGENTS.md). Keep
   `CONFIG_MUSE_OPTIMIZED_EXPERIENCE=y` for the MusePocket service.
2. Enable Phone setup in Moe's settings (the optional BOOT shortcut can open it).
3. In MusePocket choose Pair Moe, or scan nearby devices. Confirm the six-digit
   passkey shown on Moe. The service requires encryption and authenticated bonding.
4. Refresh the dashboard, sync the clock, customize settings, then Apply settings.
   Saved device state is read back after changes. A disconnect during a transfer
   requires reconnecting and refreshing before retrying.

## Included features

- Dashboard: battery, Wi-Fi state, firmware, connection, secure pairing, automatic
  reconnect and CoreBluetooth state restoration.
- Clock: phone time, POSIX timezone choices, 12/24-hour format, dim minute clock,
  pixel shifting and overnight screen-off. Wake remains available from buttons,
  active touch scanning, optional enclosure tap and optional tilt from flat rest.
- Controls: BOOT double-tap shortcut, tap threshold, audio/display/idle settings,
  Wi-Fi and Muse service setup, native audio loopback request.
- Tools: eight editable timers/recipes, synchronized to NVS on Moe; start, pause,
  resume and reset, plus optional iPhone timer alerts. Built-in device tools remain.
- Cards: eight saved notes/checklists, selected calendar events and reminders,
  and an expiring Open-Meteo weather card for entered coordinates. Expiring cards
  require synchronized device time. Moe defers cards while voice is active.
- Personality: name, accent, Orbit/Pixel cat avatars or a 64×64 RGB565 image from
  PhotosPicker. Voice and speech-rate choices apply to iPhone-generated replies.
- Find Moe: wake its display and queue a chirp when audio is idle.
- Firmware: HTTPS update manifest, iPhone checksum check, actual device-download
  checksum check, existing image/signature verification and version gate. Firmware
  redirects are refused. An accepted request is not proof of installation; reconnect
  and check the reported firmware version. No eFuse or secure-boot setting changes.
- Diagnostics: share firmware, free memory, uptime and operation labels via UIKit.
  Wi-Fi passwords, tokens, transcripts, cards and raw audio are excluded.
- iPhone notifications: opt-in ANCS on the firmware. Enable the system's notification
  sharing permission when iOS requests it. Notification contents are transient,
  displayed on Moe, and not logged or persisted. Pre-existing notifications are
  skipped. Busy/overlapping notifications may be skipped rather than buffered
  without bounds. Turning it off stops display of notification content.
- Phone-assisted voice: hold Moe's microphone button with relay enabled to send
  up to 15 seconds of IMA ADPCM. iPhone saves the WAV in a protected, five-note inbox,
  transcribes locally, and generates an Apple on-device reply, or calls your HTTPS
  relay. Text plus compressed speech return to Moe; button input interrupts playback.

## Native platform limits

Apple's on-device reply model needs an Apple Intelligence-capable iPhone, iOS 26+
with the model available, and on-device Speech recognition for voice input. The
app reports availability errors and retains a voice note if processing fails.
HTTPS mode needs your own functioning endpoint; MusePocket does not deploy one or
invent replies when a provider is unavailable.

CoreBluetooth restoration/background mode lets eligible Bluetooth events wake the
app; iOS does not guarantee continuous execution. Notes received while the app is
inactive are saved for processing when it is opened. Force-quitting, lost radio
coverage or a suspended app can prevent delivery. Moe reports transfer failure;
there is no guarantee that a note survives loss of device power during transfer.
Bluetooth on this ESP32-S3 is BLE, not an iPhone Bluetooth headset or call-audio
profile. Voice transfers use this custom protocol, not system audio routing.

Moe's clock standby uses CPU light sleep between wake checks; its AMOLED panel and
required wake circuitry remain powered. Screen-off saves more power. Dimming,
pixel shifting and night-time screen-off reduce static exposure, but cannot promise
an AMOLED lifespan. Tap/tilt wake, ANCS, physical BLE/audio throughput, OTA reboot,
and battery consumption require testing on your assembled device and real iPhone.
No connected physical device was available for this implementation's validation.

## HTTPS relay contract

Configure the final HTTPS URL in Assistant and optionally save its bearer token
in the iPhone Keychain. Redirects are refused so tokens stay on the configured
endpoint. Request timeout is 60 seconds, response limit 64 KiB:

```json
{"v":1,"inputText":"Give me a short plan","voice":""}
```

For a voice note, `inputText` is replaced by:

```json
{"v":1,"audio":{"encoding":"wav","sampleRate":16000,"data":"BASE64_MONO_16BIT_WAV"},"voice":""}
```

Return HTTP 2xx and `{"reply":"A concise answer for Moe"}`. The phone renders the
selected native voice and caps playback at 15 seconds. The endpoint must implement
its own authentication, transcription/model call and retention policy. Requests
are sent only when the user chooses HTTPS mode and processes a note or sends text.

The update manifest is `{"board":"waveshare_s3_175c","version":"VERSION",
"url":"https://YOUR_FINAL_IMAGE_URL","sha256":"64_HEX_CHARACTERS"}`. Use a trusted
manifest for the matching board and a correctly signed application image, not a
merged flash dump. Maximum image download is 4 MiB; the existing OTA partition and
image verifier may impose a smaller limit. Never point at a different board image.

See [the wire protocol](../docs/musepocket-protocol.md) and
[upstream maintenance](../docs/waveshare-experience.md) for firmware boundaries.

Software test results and reproduction commands are recorded in
[the validation report](../docs/musepocket-validation.md).
