# Waveshare 1.75C companion

This fork keeps `main` identical to `facebookincubator/muse-gadget-sdk`.
Custom work lives on `feature/waveshare-experience`, with the six requested
features implemented as separate commits in their requested order.

## Behavior

1. **Local feedback:** a successfully queued talk press shows PREPARING MIC
   before recording starts. Release or a one-second timeout clears it. It
   does not claim that speech was captured or delivered.
2. **Focused pages:** swipe left through Companion → Tools → Settings.
   Tools presents one value, an action, and Next Tool. Settings subpages keep
   their existing gesture behavior.
3. **Audio priority:** avatar work drops to at most one frame per 120 ms during
   recording/playback. Captions, meters, input and navigation still poll at the
   normal 40 ms UI rate. Existing higher-priority audio tasks, 20 ms chunks,
   bounded recordings, PSRAM storage, and asynchronous network workers remain.
4. **Rendering:** idle avatar cadence is 80 ms on USB and 200 ms on battery;
   state transitions render immediately. Existing black backgrounds, cached
   avatar cells, changed-area invalidation, and fixed internal DMA buffers
   remain. Tool labels change only when their text changes.
5. **Power:** after 20 idle seconds on battery, brightness caps at 30% without
   changing the saved preference. Input, voice activity, USB power, and opening
   settings restore the preference. Battery auto-sleep caps the saved timeout
   at 60 seconds; Never and shorter choices are respected. Audio, PSRAM, and upstream light-sleep tuning remain. Optional clock standby
   keeps the panel and touch awake, as described below.
6. **Offline tools:** brightness/speaker controls, a 25-minute focus timer,
   and two example brew recipes work locally. Recipes are stored in flash;
   the selected tool is saved in a separate NVS namespace. One timer runs at a
   time, supports pause/resume/reset, and wakes the display on expiry. A visual
   DONE card waits until voice is idle; no sound interrupts recording/playback.
   Timers survive display sleep but **not reboot or power-off**. Voice notes
   retain upstream's bounded RAM queue and retry behavior, not durable storage.
   Wi-Fi being connected does not imply Muse is reachable: the UI distinguishes
   MUSE OFFLINE from READY.

Software validation: 207 host tests passed without skips; 412×412 and 466×466
simulator scenarios passed, including ASan/UBSan on the Waveshare preview.
ESP-IDF 6.0.1 firmware builds passed for Waveshare 1.75C, AIPI, and the default C5.

These are scheduling choices, not measured battery-life or latency claims.
The simulator exercises production UI code but does not simulate I2S, QSPI,
radio, physical touch, NVS persistence, or battery current.

## Clock standby and button gestures

After the idle timeout (or one short BOOT press), a black clock screen remains
at at most 8% brightness. Its large 24-hour time changes once per minute and
moves slightly each minute. Dimming and movement reduce static exposure but
cannot eliminate uneven AMOLED wear; changing the minute alone does not remove
that risk. Brightness percentage is a panel command, not a measured wear rate. On battery, LVGL pauses after a 250 ms flush window
and resumes when the wall-clock minute changes. The panel retains the image;
touch continues scanning. Input checks touch at most every 100 ms. CPU light
sleep and Wi-Fi nap can continue between refreshes. This is **standby with an
illuminated panel**, not deep sleep. USB retains upstream's full-speed behavior.

Settings → Sleep offers Dim clock On/Off. Off uses upstream's fully dark panel
and sleeping touch controller, so either button wakes. The clock uses SNTP
(`pool.ntp.org`), shows `--:--` until time is available, and keeps system time
through light sleep and network loss. It requires a fresh sync after power-off.
`CONFIG_MUSE_CLOCK_TIMEZONE` defaults to Arizona (`MST7`); change the POSIX TZ
string in menuconfig for another timezone. No seconds animation is drawn.

The top PWR button keeps push-to-talk. The bottom BOOT button supports:

- One short press: enter standby after the 350 ms double-press window.
- Double press: open Tools (default), toggle speaker mute, or toggle phone setup,
  selected in Settings → Sleep → Double BOOT.
- Hold 1.5 seconds: existing power-off action, with the existing hold hint.
- Either button while asleep: wake and consume that press.

Tap wake (trial) is **off by default**. Enabling it uses the QMI8658A
accelerometer's hardware tap engine, not gyro polling. Vendor schematic INT1
is wired to GPIO21; the sensor lives at I2C address 0x6B. The gyro stays off;
500 Hz accelerometer sampling is active only while asleep. An interrupt
latches a possible tap, and STATUS1 confirms it before waking. Missing sensor,
I2C errors, and handshake timeouts disable tap wake for that boot while leaving
button wake available. Screen tap in clock standby consumes the waking touch.

Mock I2C tests cover both configuration phases, every write-failure exit, an
absent sensor, and a bounded command timeout. They do not establish enclosure
sensitivity, false-wake rate, or current consumption. Test those on the device
before enabling tap wake for daily use. The settings use a separate NVS namespace.

## Build and test

Use the upstream-supported **ESP-IDF 6.0.1**. From `esp32/`:

```sh
tools/muse/board.sh build s3
idf.py -B build-muse-waveshare-s3-175c -DIDF_TARGET=esp32s3 \
  -DSDKCONFIG=build-muse-waveshare-s3-175c/sdkconfig \
  -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;devices/sdkconfig.muse;devices/sdkconfig.muse-waveshare-s3-175c" reconfigure
CC=clang CXX=clang++ python3 -m unittest discover -s tests -p 'test_*.py' -v
```

The reconfigure restores managed components cleaned by the build helper;
the complete host suite needs cJSON from them. Provision your SDK token locally via menuconfig
before pairing; do not commit it. Compilation can run without a token.

From the repository root, preview the actual 466×466 geometry:

```sh
cmake -S esp32/simulator -B build/simulator-waveshare \
  -DMUSE_SIM_WAVESHARE_175C=ON -DMUSE_SIM_WARNINGS_AS_ERRORS=ON
cmake --build build/simulator-waveshare --parallel
ctest --test-dir build/simulator-waveshare --output-on-failure
build/simulator-waveshare/muse_simulator
```

Disable `CONFIG_MUSE_OPTIMIZED_EXPERIENCE` in menuconfig for the original
two-page behavior. This option defaults on only for the Waveshare 1.75C;
other firmware boards retain upstream behavior.

## Sync upstream

Commit or stash changes, then from your feature branch:

```sh
tools/sync-upstream.sh
```

This fetches both remotes, fast-forwards GitHub fork `main`, and merges
`upstream/main` into the current branch. It rejects dirty worktrees and a
diverged fork `main`, and never force-pushes. Resolve conflicts normally,
rerun host/simulator/firmware checks, then push the feature branch.
`git merge --abort` cancels an unresolved local merge.

For a server-side-only fast-forward, use `gh repo sync
jtomchak/muse-gadget-sdk --source facebookincubator/muse-gadget-sdk --branch
main`, then run the local script to integrate those changes. There is no
automatic merge into custom firmware and no automatic device flash.

Keep upstream integration changes small: new policy and tools modules contain
the fork behavior, with Kconfig-gated hooks in input/UI and source registration
in CMake. The board driver adds optional standby/tap hooks; SDK transport APIs remain unchanged. Keep
pairing data and partition offsets unchanged when resolving future conflicts.

## Physical acceptance checks

- Identify the board and back up original flash before the first custom flash.
- Configure the SDK token locally, pair in Muse, and capture a healthy boot.
- Check button-to-feedback latency, short taps, wake presses, and barge-in.
- Record/play audio while touching/swiping; inspect underruns and heap/DMA
  headroom while Wi-Fi/BLE reconnect. Compare against upstream firmware.
- Verify the circular screen edges, settings swipes, and readable reply cards.
- On battery, verify dim/sleep/wake, timer expiry while asleep and Wi-Fi napping,
  and recipe selection across reboot. Timer state intentionally resets.
- Verify the clock minute boundary, timezone, unset time before SNTP, and offline
  timekeeping; compare clock standby with full screen-off current.
- Test single/double BOOT and hold independently, including wake presses. Confirm
  the configured double action and persisted settings after reboot.
- Try enclosure taps from different directions; log missed taps, desk movement
  false wakes, and current with Tap wake enabled/disabled.
- Measure current in active, dim, clock standby, and dark sleep before claiming runtime.

Vendor reference used for power behavior:
`waveshareteam/ESP32-S3-Touch-AMOLED-1.75C`,
`examples/esp-idf/01_AXP2101/main/port_axp2101.cpp`.
Existing Muse BSP and power-rail choices were preserved.

Tap reference: vendor schematic and SensorLib QMI8658A datasheet Rev A,
sections 5.3 and 10, with the vendor tap-example thresholds. Physical tap wake
and battery runtime have not been verified: no board was connected during this build.

## MusePocket companion

The native SwiftUI iPhone app manages these device preferences over authenticated
Bluetooth. See [MusePocket setup and features](../ios/README.md) and the
[versioned protocol](musepocket-protocol.md). The companion remains in this fork;
upstream SDK fixes can be merged using the workflow above.
