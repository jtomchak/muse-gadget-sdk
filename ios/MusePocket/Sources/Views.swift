import AVFoundation
import MusePocketCore
import PhotosUI
import SwiftUI
import UIKit

extension Color {
  static let pocketPurple = Color(red: 0.73, green: 0.65, blue: 1),
    pocketInk = Color(red: 0.055, green: 0.05, blue: 0.09),
    pocketSurface = Color(red: 0.11, green: 0.10, blue: 0.16)
}
struct PocketRootView: View {
  @Environment(PocketStore.self) private var store
  @State private var tab = 0
  var body: some View {
    @Bindable var store = store
    VStack(spacing: 0) {
      if store.preview {
        Text("PREVIEW · no Bluetooth commands are sent")
          .font(.caption2.weight(.semibold)).frame(maxWidth: .infinity).padding(8)
          .background(Color.pocketPurple.opacity(0.18)).accessibilityIdentifier("preview.banner")
      }
      TabView(selection: $tab) {
        NavigationStack { PocketDashboard() }.tabItem {
          Label("Pocket", systemImage: "circle.inset.filled")
        }.tag(0)
        NavigationStack { ToolsView() }.tabItem { Label("Tools", systemImage: "timer") }.tag(1)
        NavigationStack { CardsView() }.tabItem { Label("Cards", systemImage: "rectangle.stack") }
          .tag(2)
        NavigationStack { AssistantView() }.tabItem { Label("Assistant", systemImage: "waveform") }
          .tag(3)
        NavigationStack { PocketSettingsView() }.tabItem {
          Label("Settings", systemImage: "slider.horizontal.3")
        }.tag(4)
      }.tint(.pocketPurple)
      Group {
        if store.busy {
          ProgressView("Waiting for Moe’s acknowledgement…")
        } else if let notice = store.notice {
          Text(notice).foregroundStyle(.secondary)
        }
      }.font(.caption).padding(.horizontal, 12).frame(minHeight: 24)
    }.background(Color.pocketInk)
      .alert(
        "MusePocket",
        isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.dismissError() } })
      ) {
        Button("OK") { store.dismissError() }
      } message: {
        Text(store.error ?? "")
      }
  }
}
struct PocketDashboard: View {
  @Environment(PocketStore.self) private var store
  @State private var devices = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack {
          VStack(alignment: .leading, spacing: 5) {
            Text("YOUR POCKET COMPANION").font(.caption.weight(.semibold)).tracking(2)
              .foregroundStyle(Color.pocketPurple)
            Text(store.settings.name).font(.largeTitle.bold())
          }
          Spacer()
          Image(systemName: "sparkles").foregroundStyle(Color.pocketPurple)
        }
        VStack(spacing: 18) {
          MoeFace(
            avatar: store.settings.avatar,
            accent: Color(
              red: Double((store.settings.accent >> 16) & 255) / 255,
              green: Double((store.settings.accent >> 8) & 255) / 255,
              blue: Double(store.settings.accent & 255) / 255)
          ).frame(width: 220, height: 220).padding(.top, 12)
          HStack(spacing: 6) {
            Circle().fill(store.ready ? .green : .orange).frame(width: 6, height: 6)
            Text(store.preview ? "Connected · preview" : store.bluetooth.state).font(.subheadline)
              .multilineTextAlignment(.center)
          }
          HStack {
            Metric(title: "BATTERY", value: store.battery)
            Divider().frame(height: 34)
            Metric(
              title: "WI-FI",
              value: store.snapshot?.device["wifi"]["state"].string?.capitalized ?? "—")
            Divider().frame(height: 34)
            Metric(title: "CLOCK", value: store.settings.clock ? "Standby" : "Off")
          }
        }.frame(maxWidth: .infinity).padding(20).background(
          Color.pocketSurface, in: RoundedRectangle(cornerRadius: 32))
        if !store.ready {
          VStack(alignment: .leading, spacing: 12) {
            Text("Bring Moe closer").font(.title3.bold())
            Text(
              "Enable Phone setup in Moe’s Bluetooth settings. Pair with the six-digit code on its screen."
            ).foregroundStyle(.secondary)
            Button("Pair Moe", systemImage: "antenna.radiowaves.left.and.right") {
              store.bluetooth.pairWithSystemPicker()
            }.buttonStyle(.borderedProminent)
            Button("Scan nearby devices") {
              store.bluetooth.scan()
              devices = true
            }
          }
          .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(
            Color.pocketSurface, in: RoundedRectangle(cornerRadius: 24))
        }
        HStack {
          ActionTile(title: "Find Moe", icon: "speaker.wave.2") { await store.find() }
          ActionTile(title: "Standby", icon: "moon") { await store.sleep() }
          ActionTile(title: "Sync clock", icon: "clock.arrow.circlepath") { await store.syncTime() }
        }.disabled(!store.ready || store.busy)
        VStack(alignment: .leading, spacing: 8) {
          Text("A little more useful, every day.").font(.title3.weight(.semibold))
          Text("Timers and saved cards stay on Moe. Your iPhone makes them easier to organize.")
            .foregroundStyle(.secondary).font(.subheadline)
        }
        if let timer = store.snapshot?.timer, timer["running"].bool == true {
          Label(
            "\(timer["title"].string ?? "Timer") · \(timer["remaining"].integer(in: 0...86400) ?? 0) seconds left",
            systemImage: "timer"
          ).padding().background(Color.pocketSurface, in: RoundedRectangle(cornerRadius: 18))
        }
      }.padding(24)
    }.background(Color.pocketInk).navigationTitle("MusePocket").navigationBarTitleDisplayMode(
      .inline
    )
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
          .disabled(!store.ready || store.busy)
      }
    }
    .sheet(isPresented: $devices) {
      NavigationStack {
        List {
          ForEach(store.bluetooth.nearby) { device in
            Button {
              store.bluetooth.connect(device.id)
              devices = false
            } label: {
              HStack {
                Text(device.name)
                Spacer()
                Text("\(device.rssi) dBm").foregroundStyle(.secondary)
              }
            }
          }
          Text(store.bluetooth.state).font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Nearby Moe").toolbar { Button("Done") { devices = false } }
      }
    }
  }
}
struct Metric: View {
  let title: String, value: String
  var body: some View {
    VStack(spacing: 6) {
      Text(title).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
      Text(value).font(.subheadline.weight(.semibold))
    }.frame(maxWidth: .infinity)
  }
}
struct ActionTile: View {
  let title: String, icon: String, action: () async -> Void
  var body: some View {
    Button {
      Task { await action() }
    } label: {
      VStack(spacing: 10) {
        Image(systemName: icon).font(.title3)
        Text(title).font(.caption.weight(.medium))
      }.frame(maxWidth: .infinity).padding(.vertical, 18).background(
        Color.pocketSurface, in: RoundedRectangle(cornerRadius: 20))
    }
  }
}
struct MoeFace: View {
  var avatar = 0
  var accent = Color.pocketPurple
  var body: some View {
    ZStack {
      Circle().fill(
        LinearGradient(
          colors: [Color.gray.opacity(0.8), .black, .gray.opacity(0.6)], startPoint: .topLeading,
          endPoint: .bottomTrailing))
      Circle().fill(.black).padding(9)
      Circle().stroke(.white.opacity(0.12), lineWidth: 1).padding(13)
      if avatar == 1 {
        Circle().fill(accent.opacity(0.7)).frame(width: 95, height: 95).blur(radius: 2)
      } else {
        VStack(spacing: 16) {
          HStack(spacing: 24) {
            RoundedRectangle(cornerRadius: 6).fill(accent).frame(width: 15, height: 26)
            RoundedRectangle(cornerRadius: 6).fill(accent).frame(width: 15, height: 26)
          }
          RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.8)).frame(
            width: 28, height: 5)
        }.padding(26).background(
          accent.opacity(0.08),
          in: RoundedRectangle(cornerRadius: avatar == 2 ? 12 : 35))
      }
      Circle().fill(.white.opacity(0.05)).frame(width: 65, height: 65).offset(x: -50, y: -56)
    }
  }
}
struct ToolsView: View {
  @Environment(PocketStore.self) private var store
  @State private var editing: PocketPreset?
  @State private var newPreset = false
  var body: some View {
    List {
      Section("On Moe") { timerControls }
      Section("Timers & recipes") {
        ForEach(store.snapshot?.presets ?? []) { preset in
          PresetRow(preset: preset, edit: { editing = preset })
        }
        .onDelete { indices in
          let items = store.snapshot?.presets ?? []
          Task { for i in indices { await store.removePreset(items[i].id) } }
        }
        Button("Add timer or recipe", systemImage: "plus") { newPreset = true }
          .accessibilityIdentifier("tools.add")
      }.disabled(!store.ready || store.busy)
      Section {
        Button("Enable iPhone timer alerts", systemImage: "bell") {
          Task {
            await store.run("Timer alert permission updated") {
              guard try await store.alerts.authorize() else {
                throw PocketError.rejected(
                  "Allow notifications in iPhone Settings to receive timer alerts.")
              }
            }
          }
        }
        Text(
          "Moe keeps counting without your phone. iPhone alerts are a backup; reconnect to refresh a timer changed on the device."
        ).font(.footnote).foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Tools").scrollContentBackground(.hidden).background(Color.pocketInk)
    .sheet(isPresented: $newPreset) {
      PresetEditor(preset: .init(title: "", detail: "", seconds: 1500))
    }
    .sheet(item: $editing) { PresetEditor(preset: $0) }
  }
  @ViewBuilder private var timerControls: some View {
    if let timer = store.snapshot?.timer {
      HStack {
        Text(timer["title"].string ?? "Timer")
        Spacer()
        Text("\(timer["remaining"].integer(in: 0...86400) ?? 0)s").monospacedDigit()
      }
      HStack {
        Button("Pause") { Task { await store.timer("pause") } }
        Spacer()
        Button("Resume") { Task { await store.timer("resume") } }
        Spacer()
        Button("Reset") { Task { await store.timer("reset") } }
      }.disabled(!store.ready || store.busy)
    }
  }
}
struct PresetRow: View {
  @Environment(PocketStore.self) private var store
  let preset: PocketPreset
  let edit: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(preset.title).font(.headline)
        Spacer()
        Text("\(preset.seconds / 60)m \(preset.seconds % 60)s").foregroundStyle(.secondary)
      }
      Text(preset.detail).font(.subheadline).foregroundStyle(.secondary)
      HStack {
        Button("Start", systemImage: "play.fill") {
          Task { await store.timer("start", preset: preset) }
        }.buttonStyle(.bordered)
        Spacer()
        Button("Edit", action: edit)
      }
    }.padding(.vertical, 5)
  }
}
struct PresetEditor: View {
  @Environment(PocketStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State var preset: PocketPreset
  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $preset.title).accessibilityIdentifier("preset.title")
        TextField("Instructions", text: $preset.detail, axis: .vertical).lineLimit(3...6)
        Stepper(
          "Duration: \(preset.seconds) seconds", value: $preset.seconds, in: 1...86400, step: 30)
        Text(
          "Up to eight presets are stored on Moe. Editing a running timer’s presets requires resetting it first."
        ).font(.footnote).foregroundStyle(.secondary)
      }.navigationTitle("Timer or recipe").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            Task {
              await store.preset(preset)
              if store.error == nil { dismiss() }
            }
          }.disabled(preset.title.isEmpty || store.busy).accessibilityIdentifier("preset.save")
        }
      }
    }
  }
}
struct CardsView: View {
  @Environment(PocketStore.self) private var store
  @State private var newCard = false
  @State private var latitude = "33.45"
  @State private var longitude = "-112.07"
  var body: some View {
    List {
      Section("On Moe") {
        ForEach(store.snapshot?.cards ?? []) { card in
          Button {
            Task { await store.showCard(card) }
          } label: {
            VStack(alignment: .leading, spacing: 5) {
              Text(card.title).font(.headline)
              Text(card.body).font(.subheadline).foregroundStyle(.secondary)
              Text(card.source).font(.caption2).foregroundStyle(Color.pocketPurple)
            }
          }
        }.onDelete { indices in
          for i in indices {
            if let card = store.snapshot?.cards[i] { Task { await store.removeCard(card.id) } }
          }
        }
        Button("New pocket card", systemImage: "plus") { newCard = true }.accessibilityIdentifier(
          "cards.add")
      }.disabled(!store.ready || store.busy)
      Section("From your iPhone") {
        Button("Choose calendar cards", systemImage: "calendar") {
          Task { await store.importCalendar() }
        }
        Button("Choose reminder cards", systemImage: "checklist") {
          Task { await store.importReminders() }
        }
        HStack {
          TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
          TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
        }
        Button("Get weather card", systemImage: "cloud.sun") {
          Task {
            await store.weather(
              latitude: Double(latitude) ?? 999, longitude: Double(longitude) ?? 999)
          }
        }
        Link("Weather data: Open-Meteo", destination: URL(string: "https://open-meteo.com/")!).font(
          .caption)
      }.disabled(store.busy)
      if !store.importedCards.isEmpty {
        Section("Choose what Moe receives") {
          ForEach(store.importedCards) { card in
            VStack(alignment: .leading) {
              Text(card.title).font(.headline)
              Text(card.body).foregroundStyle(.secondary)
              Button("Send to Moe") { Task { await store.card(card) } }.disabled(
                !store.ready || store.busy)
            }
          }
        }
      }
      Section {
        Text(
          "Eight cards fit on Moe. Expiring calendar and weather cards are checked against its synchronized clock. A card never replaces a voice reply while audio is active."
        ).font(.footnote).foregroundStyle(.secondary)
      }
    }.navigationTitle("Cards").scrollContentBackground(.hidden).background(Color.pocketInk).sheet(
      isPresented: $newCard
    ) { CardEditor() }
  }
}
struct CardEditor: View {
  @Environment(PocketStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var bodyText = ""
  @State private var expire = false
  @State private var expiry = Date().addingTimeInterval(86400)
  var body: some View {
    NavigationStack {
      Form {
        TextField("Title", text: $title).accessibilityIdentifier("card.title")
        TextField("A short note or checklist", text: $bodyText, axis: .vertical).lineLimit(3...8)
          .accessibilityIdentifier("card.body")
        Toggle("Expire this card", isOn: $expire)
        if expire { DatePicker("Expires", selection: $expiry, in: Date()...) }
        Text("Up to 32 bytes for the title and 160 bytes for the card body.").font(.footnote)
          .foregroundStyle(.secondary)
      }.navigationTitle("New pocket card").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Send") {
            Task {
              await store.card(
                .init(
                  title: title, body: bodyText,
                  expires: expire ? Int64(expiry.timeIntervalSince1970) : 0), show: true)
              if store.error == nil { dismiss() }
            }
          }.disabled(title.isEmpty || store.busy).accessibilityIdentifier("card.send")
        }
      }
    }
  }
}
struct AssistantView: View {
  @Environment(PocketStore.self) private var store
  @State private var prompt = ""
  @State private var token = ""
  var body: some View {
    @Bindable var assistant = store.assistant
    List {
      Section("Phone-assisted Moe") {
        Picker("Reply engine", selection: $assistant.engine) {
          Text("On iPhone").tag("iphone")
          Text("HTTPS relay").tag("https")
        }
        if assistant.engine == "https" {
          TextField("https://your-relay.example/relay", text: $assistant.endpoint)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          SecureField("Relay access token", text: $token)
          Button("Save relay settings") {
            Task {
              await store.run("Relay settings saved securely") {
                if let url = URL(string: assistant.endpoint) {
                  try EndpointPolicy.validate(url)
                } else {
                  throw PocketError.malformed
                }
                guard let url = URL(string: assistant.endpoint) else { throw PocketError.malformed }
                try PocketKeychain.save(token, name: PocketKeychain.relayAccount(url))
                assistant.savePreferences()
                token = ""
              }
            }
          }
          Text(
            "In relay mode, requests and voice recordings are sent to this endpoint. Saving replaces this endpoint’s token; leave empty for no bearer token. Tokens stay in the iPhone Keychain."
          ).font(.footnote).foregroundStyle(.secondary)
        } else {
          Text(
            "Uses Apple’s on-device model on supported iPhones with iOS 26 or later. Voice notes also need on-device speech recognition."
          ).font(.footnote).foregroundStyle(.secondary)
        }
        TextField("Ask Moe something…", text: $prompt, axis: .vertical).lineLimit(2...6)
          .accessibilityIdentifier("assistant.prompt")
        Button("Send request", systemImage: "arrow.up.circle.fill") {
          Task {
            if store.preview {
              assistant.lastReply =
                "Preview: replies are generated by your selected engine on a real iPhone."
              assistant.status = "Preview only"
            } else {
              await assistant.ask(prompt)
            }
          }
        }.disabled(!store.ready || assistant.busy || store.busy || prompt.isEmpty)
        Text(assistant.status).font(.caption).foregroundStyle(.secondary)
        if !assistant.lastReply.isEmpty { Text(assistant.lastReply).textSelection(.enabled) }
      }
      Section("Voice inbox") {
        if assistant.inbox.isEmpty {
          Text(
            "Hold Moe’s microphone button with phone relay enabled. A saved voice note appears here."
          ).foregroundStyle(.secondary)
        }
        ForEach(assistant.inbox) { note in
          VStack(alignment: .leading) {
            Text(note.date.formatted()).font(.caption)
            if let transcript = note.transcript { Text(transcript) }
            HStack {
              Button("Process") { Task { await assistant.process(note) } }.disabled(
                !store.ready || assistant.busy || store.busy)
              Spacer()
              Button("Delete", role: .destructive) { assistant.delete(note) }
            }
          }
        }
      }
      Section("Reply voice") {
        Picker("Voice", selection: $assistant.voiceIdentifier) {
          Text("System voice").tag("")
          ForEach(AVSpeechSynthesisVoice.speechVoices(), id: \.identifier) {
            Text($0.name + " · " + $0.language).tag($0.identifier)
          }
        }
        Slider(value: $assistant.voiceRate, in: 0.35...0.6)
        Toggle("Also speak on iPhone", isOn: $assistant.speakOnPhone)
        Text(
          "Replies are sent to Moe as text and compressed audio. Longer generated speech is capped at 15 seconds."
        ).font(.footnote).foregroundStyle(.secondary)
      }
    }.navigationTitle("Assistant").scrollContentBackground(.hidden).background(Color.pocketInk)
      .onChange(of: assistant.engine) { assistant.savePreferences() }.onChange(
        of: assistant.voiceIdentifier
      ) { assistant.savePreferences() }
      .onChange(of: assistant.voiceRate) { assistant.savePreferences() }
      .onChange(of: assistant.speakOnPhone) { assistant.savePreferences() }
  }
}
struct PocketSettingsView: View {
  @Environment(PocketStore.self) private var store
  @State private var photo: PhotosPickerItem?
  @State private var ssid = ""
  @State private var password = ""
  @State private var host = ""
  @State private var vm = ""
  @State private var museToken = ""
  @State private var brightness = 80.0
  @State private var volume = 60.0
  @State private var micGain = 24.0
  @State private var sleepSeconds = 120.0
  @State private var showManifest = false
  @State private var manifest: UpdateManifest?
  @State private var shareURL: URL?
  @State private var showShare = false
  @State private var accent = Color.pocketPurple
  var body: some View {
    @Bindable var store = store
    Form {
      Section("Moe") {
        TextField("Name", text: $store.settings.name)
        Picker("Avatar", selection: $store.settings.avatar) {
          Text("Muse").tag(0)
          Text("Orbit").tag(1)
          Text("Pixel cat").tag(2)
          Text("Uploaded image").tag(3)
        }
        ColorPicker("Accent", selection: $accent, supportsOpacity: false).onChange(of: accent) {
          var r: CGFloat = 0
          var g: CGFloat = 0
          var b: CGFloat = 0
          var a: CGFloat = 0
          UIColor(accent).getRed(&r, green: &g, blue: &b, alpha: &a)
          store.settings.accent = (Int(r * 255) << 16) | (Int(g * 255) << 8) | Int(b * 255)
        }
        Text("Accent colors Orbit and Pixel cat; uploaded images keep their colors.").font(.caption)
          .foregroundStyle(.secondary)
        PhotosPicker("Upload an avatar", selection: $photo, matching: .images).disabled(
          !store.ready || store.busy)
      }
      Section("Clock & display care") {
        Toggle("Dim clock in standby", isOn: $store.settings.clock)
        Toggle("24-hour clock", isOn: $store.settings.clock24)
        Picker("Timezone", selection: $store.settings.timezone) {
          Text("Arizona").tag("MST7")
          Text("UTC").tag("UTC0")
          Text("Pacific").tag("PST8PDT,M3.2.0,M11.1.0")
          Text("Eastern").tag("EST5EDT,M3.2.0,M11.1.0")
          Text("UK").tag("GMT0BST,M3.5.0/1,M10.5.0")
        }
        Toggle("Screen off overnight", isOn: $store.settings.night)
        if store.settings.night {
          Stepper(
            "From \(clockMinute(store.settings.nightStart))", value: $store.settings.nightStart,
            in: 0...1439, step: 30)
          Stepper(
            "Until \(clockMinute(store.settings.nightEnd))", value: $store.settings.nightEnd,
            in: 0...1439, step: 30)
        }
        Text(
          "The clock stays dim and moves each minute. These reduce static exposure; AMOLED wear is still possible. Overnight screen-off also reduces battery use."
        ).font(.footnote).foregroundStyle(.secondary)
      }
      Section("Buttons & motion") {
        Picker("Double BOOT", selection: $store.settings.shortcut) {
          Text("Open Tools").tag(0)
          Text("Speaker mute").tag(1)
          Text("Phone setup").tag(2)
        }
        Toggle("Enclosure tap wake", isOn: $store.settings.tap)
        Stepper(
          "Tap threshold: \(store.settings.tapThreshold) mg²", value: $store.settings.tapThreshold,
          in: 400...2000, step: 100)
        Toggle("Tilt to wake", isOn: $store.settings.tilt)
        Text(
          "Single BOOT enters standby. Holding it powers off. Motion wake is experimental until tested in your enclosure."
        ).font(.footnote).foregroundStyle(.secondary)
      }
      Section("Phone connection") {
        Toggle("iPhone notification cards", isOn: $store.settings.notifications)
        Toggle("Route Moe’s voice through iPhone", isOn: $store.settings.relay)
        Text(
          "Notification sharing uses Apple ANCS and needs system permission. Open MusePocket to process voice notes if iOS has suspended the app."
        ).font(.footnote).foregroundStyle(.secondary)
      }
      Section {
        Button("Apply settings to Moe") { Task { await store.applySettings() } }.disabled(
          !store.ready || store.busy
        ).accessibilityIdentifier("settings.apply")
        Button("Sync time now") { Task { await store.syncTime() } }.disabled(
          !store.ready || store.busy)
        Text(
          "Apply waits for Moe’s acknowledgement. Reconnect and refresh to verify changes after a transfer fails."
        ).font(.footnote).foregroundStyle(.secondary)
      }
      Section("Display & audio") {
        Slider(value: $brightness, in: 10...100, step: 10) { Text("Brightness") }
        Button("Set brightness: \(Int(brightness))%") {
          Task { await store.legacy("brightness", value: String(Int(brightness))) }
        }
        Slider(value: $volume, in: 0...100, step: 5)
        Button("Set volume: \(Int(volume))%") {
          Task { await store.legacy("volume", value: String(Int(volume))) }
        }
        Slider(value: $micGain, in: 0...33, step: 3)
        Button("Set microphone gain: \(Int(micGain)) dB") {
          Task { await store.legacy("mic_gain", value: String(Int(micGain))) }
        }
        Slider(value: $sleepSeconds, in: 0...600, step: 30)
        Button("Set idle timeout: \(Int(sleepSeconds))s") {
          Task { await store.legacy("sleep", value: String(Int(sleepSeconds))) }
        }
        Button("Run audio loopback test") { Task { await store.audioTest() } }
      }.disabled(!store.ready || store.busy)
      Section("Wi-Fi setup") {
        TextField("Network name", text: $ssid).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        SecureField("Password", text: $password)
        Button("Send Wi-Fi settings") {
          Task {
            await store.wifi(ssid: ssid, password: password)
            if store.error == nil { password = "" }
          }
        }.disabled((!store.bluetooth.connected && !store.preview) || store.busy || ssid.isEmpty)
      }
      Section("Muse service") {
        TextField("Muse host", text: $host).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("VM ID", text: $vm).textInputAutocapitalization(.never).autocorrectionDisabled()
        SecureField("Device token", text: $museToken)
        Button("Configure & test Muse") {
          Task {
            await store.configureMuse(host: host, vm: vm, token: museToken)
            if store.error == nil { museToken = "" }
          }
        }.disabled(!store.ready || store.busy || host.isEmpty)
      }
      Section("Firmware & diagnostics") {
        LabeledContent("Firmware", value: store.snapshot?.device["fw"].string ?? "Not connected")
        Button("Choose update manifest", systemImage: "square.and.arrow.down") {
          showManifest = true
        }
        if let manifest {
          Text("\(manifest.board) · \(manifest.version)").font(.caption)
          Button("Verify & install firmware", role: .destructive) {
            Task { await store.install(manifest) }
          }.disabled(!store.ready || store.busy)
        }
        Button("Share diagnostic report", systemImage: "square.and.arrow.up") {
          do {
            shareURL = try store.exportDiagnostics()
            showShare = true
          } catch { store.report(error) }
        }
        Text(
          "Updates require Moe’s Wi-Fi connection and its existing firmware verification. A request acknowledgement is not an installed update; refresh after it reconnects."
        ).font(.footnote).foregroundStyle(.secondary)
      }
      Section {
        if !store.preview {
          Button("Disconnect", role: .destructive) { store.bluetooth.disconnect() }
        }
        LabeledContent("App", value: "MusePocket 0.1")
      }
    }.navigationTitle("Settings").scrollContentBackground(.hidden).background(Color.pocketInk)
      .fileImporter(isPresented: $showManifest, allowedContentTypes: [.json]) { result in
        do {
          let url = try result.get()
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(contentsOf: url))
            .validated()
        } catch {
          store.report(error)
          manifest = nil
        }
      }
      .sheet(isPresented: $showShare) { if let shareURL { ShareSheet(items: [shareURL]) } }
      .onChange(of: photo) {
        Task {
          do {
            if let data = try await photo?.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
            {
              let pixels = try AvatarPixels.encode(image)
              await store.uploadAvatar(pixels)
            }
          } catch { store.report(error) }
        }
      }
  }
  private func clockMinute(_ minute: Int) -> String {
    String(format: "%02d:%02d", minute / 60, minute % 60)
  }
}
