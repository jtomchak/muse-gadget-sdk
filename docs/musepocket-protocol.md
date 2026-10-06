# MusePocket protocol v1

This fork adds two encrypted, authenticated characteristics inside the existing
Muse GATT service, leaving SDK setup and its advertisement UUID intact. The
feature is gated to `CONFIG_MUSE_OPTIMIZED_EXPERIENCE` on Waveshare 1.75C.

| Purpose | UUID |
|---|---|
| SDK advertised service | `7FDD3D1C-38EA-46CF-8B46-314ECF5F240C` |
| Muse service | `4D757365-0001-4000-8000-6A6F6C6C7900` |
| SDK command/status | `…0002…` / `…0003…` |
| Pocket command, write with response | `4D757365-0004-4000-8000-6A6F6C6C7900` |
| Pocket response/event, read + notify | `4D757365-0005-4000-8000-6A6F6C6C7900` |

Read Pocket response to trigger passkey pairing and receive unframed
`{"v":1,"ready":true}`. Subscribe before requesting `hello`. MusePocket waits for
both the secured read and confirmed subscription. A restored bond still needs
service/characteristic discovery. Other SDK clients can continue using legacy
setup. Incoming reads/writes require encryption plus MITM authentication;
notifications additionally check the authenticated connection and subscription.

## Framing

Each characteristic value contains a 12-byte header plus nonempty UTF-8 JSON data.
All integer header fields use little endian:

| Offset | Size | Meaning |
|---|---|---|
| 0 | 1 | `A1` request, `A2` response, `A3` event |
| 1 | 1 | version `01` |
| 2 | 2 | transfer identifier |
| 4 | 2 | zero-based chunk index |
| 6 | 2 | total chunks, 1–4096 |
| 8 | 4 | IEEE CRC32 of the complete JSON message |

Maximum message: 24,576 bytes. Assembly expires 30 seconds from the first chunk,
including uptime wrap on firmware. A first chunk replaces an incomplete transfer;
a bad order, mismatched header, overflow or checksum resets it. Firmware accepts
only requests. Native Swift accepts only response/event directions. Notifications
use negotiated ATT MTU minus three bytes, capped at 512; writes use CoreBluetooth's
reported maximum for writes with response. Only one native RPC is pending at once.
BLE callbacks copy into an eight-packet queue; a lower-priority worker validates,
persists and executes commands. JSON nesting is capped at 16 before recursive
parsing. Invalid envelopes without a usable request ID are dropped; the native
request then times out instead of claiming success.

The fixture for request `hello`, transfer `0x1234`, at a 20-byte characteristic
value is `a10134120000010086a6103668656c6c6f` (payload is the plain test string
`hello`, used for framing tests; a production payload must be a JSON envelope).
Both C++ and Swift assert this exact fixture.

## Envelopes and methods

Request: `{"v":1,"id":"UUID","method":"hello","params":{}}`.
Response: `{"v":1,"id":"UUID","ok":true,"result":{...}}`, or `ok:false` with a
safe `error` string. Queries return a full snapshot; mutations return
`{"accepted":true}`. The native app queries `hello` after persistent changes.
A disconnect can leave an acknowledged mutation applied but its response lost;
refresh before retrying. Requests are not a transaction across multiple RPCs.

Snapshot: `settings`, `presets`, `cards`, `capabilities`, `device` (existing SDK
status), `timer`, and `diagnostics`. Credentials themselves are never included.

| Method | Parameters / result |
|---|---|
| `hello`, `status`, `diagnostics` | full snapshot |
| `settings.set` | complete `PocketSettings`; typed values, not a patch |
| `preset.put` / `preset.delete` | preset DTO / `{id}` |
| `card.put` / `card.delete` / `card.show` | card DTO / `{id}` |
| `timer.start` | `{id}` of a saved preset; reset any previous timer first |
| `timer.pause`, `timer.resume`, `timer.reset` | `{}` |
| `time.set` | integral Unix `{epoch,timezone}`; accepted years 2024–2100 |
| `find`, `sleep` | `{}`; standby rejected during voice |
| `avatar.upload` | `{data,crc}`: base64 64×64 little-endian RGB565, 8192 bytes |
| `ota` | `{board,version,url,sha256}`; matching board, final HTTPS URL, 64 hex chars |
| `reply.text` | `{text}`: up to 360 UTF-8 bytes |
| `reply.begin` | `{turn,frames,crc}` |
| `reply.part` | `{turn,offset,data}`: base64, up to 2048 bytes per RPC |
| `reply.end` | `{turn}`; queued only after full size + CRC verification |
| `notification.action` | `{uid,action}`; ANCS 0 positive / 1 negative; queue acceptance, not proof the phone action completed |

Settings: `clock,tap,tilt,night,clock24,notifications,relay` booleans;
`shortcut` 0 Tools / 1 mute / 2 Phone setup; `tapThreshold` 400–2000;
`nightStart,nightEnd` minute-of-day 0–1439; `accent` 24-bit RGB; `avatar` 0 Muse /
1 Orbit / 2 Pixel cat / 3 uploaded; `name` up to 24 UTF-8 bytes; `timezone` a
POSIX TZ string up to 63 bytes. Equal night start/end disables the night interval.
Clock/tap/shortcut changes made on Moe remain authoritative across reboots.

Eight presets: `id` <=36 bytes, `title` <=32, `detail` <=160, `seconds` 1–86400.
Eight cards: `id` <=36, `title` <=32, `body` <=160, `source` <=32, `expires`
Unix seconds (0 means no expiry). Validation happens on a copy before persistent
state changes. Preset editing is rejected until an existing timer is reset,
including paused timers. Timers are RAM state and reset on a power cycle; their
presets and cards are NVS state. AOD clock moves each minute and uses the SDK's
light-sleep tuning; night-time screen-off can turn the panel fully off.

## Voice and events

Event: `{"v":1,"event":"voice.chunk","data":{...}}`.
`voice.begin` carries `turn`; `voice.chunk` carries `turn,offset,data`;
`voice.end` carries `turn,frames,crc`. ADPCM is mono 16 kHz, standard IMA, low nibble
first, predictor/index initially zero per turn. The final unused nibble for odd
frame counts is ignored. Maximum 240,000 frames / 120,000 compressed bytes. C and
Swift share the fixture PCM `[-32768,-12000,-1000,0,1000,12000,32767,0]` → `ff5f77d7`.

Firmware owns only one queued outbound note and one queued incoming reply, with
PSRAM buffers. Incoming audio expires after 120 seconds and is reset when the
secured connection changes. Outbound voice retains the connection generation it
was authorized for and cannot transfer to a subsequently connected phone. BLE
transmission happens after capture on the worker; playback happens on the existing
voice task and can be interrupted by a microphone press.

Other events include `timer.done`, `reply.played`, `reply.interrupted`,
`ota.applied`, `ota.skipped`, `ota.failed`, with `{detail}` in `data`.
`ota.applied` precedes reboot; the reconnected firmware version provides the useful
confirmation. Phone reply text and a queued audio acknowledgement do not mean
playback finished; `reply.played` reports completion.

ANCS discovery and callbacks run on NimBLE's host event queue. Attribute assembly
is bounded to 256 bytes, with requested title/message limits of 32/160 bytes.
Only one attribute request is outstanding; new overlapping notifications and
pre-existing notifications are skipped. Notifications never interrupt active
voice. Native iPhone notification APIs are used for timer alerts; other apps'
notification mirroring comes from ANCS on the device.

## Upstream and validation

New modules are `muse_pocket`, `muse_pocket_ancs`, `pocket_frame`, `pocket_model`, and
`muse_tilt`. Integrations into app/BLE/UI/input/audio are guarded by the optimized
board feature; OTA checksum verification is optional and preserves the SDK's
normal signature/version checks. No flash-security/eFuse policy changes.

Host tests execute production framing/model/codec, ANCS attribute parser, tilt
state and OTA streaming hash gates. Swift package tests execute independent native
implementations using the same wire fixtures. Native unit/UI tests use explicit
preview mode. The existing LVGL simulator tests cover original screens and clock
behavior, but do not emulate Bluetooth, iPhone services or physical sensors.


### Physical acceptance still required

With a signed MusePocket install and the Waveshare connected, check:

1. Passkey rejection/acceptance, bonding, reconnect and restoration; switching
   devices must not accept an old connection's callbacks or audio.
2. Apply settings, presets, cards and an avatar; power-cycle and compare readback.
   Confirm timers reset on reboot while their presets remain saved.
3. Measure USB and battery current during normal idle, clock standby, night-off,
   optional tap and tilt. Verify minute clock movement, touch/button wake and
   BOOT single/double/hold behavior. Observe the panel over longer operation.
4. Record and interrupt replies while using timers; verify no audio underruns,
   timer completion and card deferral. Suspend the iPhone app, reconnect, deny
   Speech/model availability and confirm saved notes can be processed later.
5. Allow/deny ANCS sharing; disable mirroring and confirm content stops appearing.
   Test fragmented and overlapping notifications without retaining their content.
6. Use a matching signed OTA image and trusted manifest. Verify success after
   reboot, wrong hash/board/version rejection and disconnect recovery. Do not
   change flash-security or eFuse configuration for these tests.

No physical device, current consumption, iPhone background lifecycle or panel
wear result is implied by the software tests.
