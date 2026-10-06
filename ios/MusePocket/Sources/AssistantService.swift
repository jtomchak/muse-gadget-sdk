import AVFoundation
import Foundation
import MusePocketCore
import Observation
import Speech
import UIKit

#if canImport(FoundationModels)
  import FoundationModels
#endif

struct VoiceNote: Codable, Identifiable {
  var id: UUID, date: Date, filename: String, transcript: String?
  var reply: String? = nil
}
@MainActor @Observable final class AssistantService {
  var engine = "muse"
  var museHost = "hatch.metaaivm.com"
  var museVM = ""
  var museDirectVMToken = false
  var endpoint = ""
  var status = "Ready when you are"
  var busy = false
  var speakOnPhone = false
  var voiceIdentifier = ""
  var voiceRate: Double = 0.5
  var lastReply = ""
  private(set) var inbox: [VoiceNote] = []
  @ObservationIgnored private var speechTask: SFSpeechRecognitionTask?
  @ObservationIgnored private var recognizer: SFSpeechRecognizer?
  @ObservationIgnored private var speechContinuation: CheckedContinuation<String, Error>?
  @ObservationIgnored private var speechDeadline: Task<Void, Never>?
  @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
  @ObservationIgnored private var audioSamples: [Float] = []
  @ObservationIgnored private var sampleRate: Double = 22050
  @ObservationIgnored private var audioContinuation: CheckedContinuation<[Int16], Error>?
  @ObservationIgnored private var audioDeadline: Task<Void, Never>?
  @ObservationIgnored private let preferences: UserDefaults
  @ObservationIgnored private let inboxDirectory: URL?
  @ObservationIgnored private let museClient: MuseVoiceClient?
  @ObservationIgnored private let museCredential: ((String) -> String?)?
  @ObservationIgnored private var activeMuseTask: Task<String, Error>?
  @ObservationIgnored var deliver: ((String, [Int16]?) async throws -> Void)?
  init(
    preferences: UserDefaults = .standard, inboxDirectory: URL? = nil,
    museClient: MuseVoiceClient? = nil, museCredential: ((String) -> String?)? = nil
  ) {
    self.preferences = preferences
    self.inboxDirectory = inboxDirectory
    self.museClient = museClient
    self.museCredential = museCredential
    engine = preferences.string(forKey: "assistant.engine") ?? "muse"
    museHost = preferences.string(forKey: "assistant.muse.host") ?? "hatch.metaaivm.com"
    museVM = preferences.string(forKey: "assistant.muse.vm") ?? ""
    museDirectVMToken = preferences.bool(forKey: "assistant.muse.direct")
    endpoint = preferences.string(forKey: "assistant.endpoint") ?? ""
    voiceIdentifier = preferences.string(forKey: "assistant.voice") ?? ""
    voiceRate = preferences.object(forKey: "assistant.voiceRate") as? Double ?? 0.5
    speakOnPhone = preferences.bool(forKey: "assistant.speakOnPhone")
    if let data = preferences.data(forKey: "voice.inbox"),
      let notes = try? JSONDecoder().decode([VoiceNote].self, from: data)
    {
      inbox = notes
    }
  }
  func savePreferences() {
    preferences.set(museHost, forKey: "assistant.muse.host")
    preferences.set(museVM, forKey: "assistant.muse.vm")
    preferences.set(museDirectVMToken, forKey: "assistant.muse.direct")
    preferences.set(voiceRate, forKey: "assistant.voiceRate")
    preferences.set(speakOnPhone, forKey: "assistant.speakOnPhone")
    preferences.set(engine, forKey: "assistant.engine")
    preferences.set(endpoint, forKey: "assistant.endpoint")
    preferences.set(voiceIdentifier, forKey: "assistant.voice")
  }
  private var directory: URL {
    let root =
      inboxDirectory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("VoiceInbox", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    return root
  }
  private func saveInbox() {
    if let data = try? JSONEncoder().encode(inbox) {
      preferences.set(data, forKey: "voice.inbox")
    }
  }
  func receive(_ samples: [Int16]) async {
    let id = UUID()
    let filename = id.uuidString + ".wav"
    do {
      guard inbox.count < 5 else {
        throw PocketError.rejected(
          "The voice inbox is full. Process or delete a note before recording more.")
      }
      try IMAAudio.wav(samples).write(
        to: directory.appendingPathComponent(filename),
        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      let note = VoiceNote(id: id, date: Date(), filename: filename, transcript: nil)
      inbox.append(note)
      saveInbox()
      status = "Voice note saved on iPhone"
      if UIApplication.shared.applicationState == .active {
        await process(note)
      } else {
        status = "Open MusePocket to process the saved voice note."
      }
    } catch { status = error.localizedDescription }
  }
  func delete(_ note: VoiceNote) {
    try? FileManager.default.removeItem(at: directory.appendingPathComponent(note.filename))
    inbox.removeAll { $0.id == note.id }
    saveInbox()
  }
  func process(_ note: VoiceNote) async {
    guard !busy, inbox.contains(where: { $0.id == note.id }) else { return }
    busy = true
    defer { busy = false }
    do {
      let url = directory.appendingPathComponent(note.filename)
      let reply: String
      if let savedReply = inbox.first(where: { $0.id == note.id })?.reply {
        status = "Delivering the saved reply to Moe…"
        reply = savedReply
      } else if engine == "muse" {
        status = "Sending your voice note to Muse through iPhone…"
        reply = try await muse(text: nil, audio: Data(contentsOf: url))
      } else if engine == "https" {
        status = "Sending the note to your configured relay…"
        reply = try await remote(text: nil, audio: Data(contentsOf: url))
      } else {
        status = "Transcribing on iPhone…"
        let text = try await transcribe(url)
        if let i = inbox.firstIndex(where: { $0.id == note.id }) {
          inbox[i].transcript = text
          saveInbox()
        }
        reply = try await local(text)
      }
      if let i = inbox.firstIndex(where: { $0.id == note.id }) {
        inbox[i].reply = reply
        saveInbox()
      }
      try await finish(reply)
      delete(note)
    } catch { status = error.localizedDescription + " The note remains in your inbox." }
  }
  func ask(_ text: String) async {
    guard !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    busy = true
    defer { busy = false }
    do {
      status = "Thinking…"
      let reply: String
      if engine == "muse" {
        reply = try await muse(text: text, audio: nil)
      } else if engine == "https" {
        reply = try await remote(text: text, audio: nil)
      } else {
        reply = try await local(text)
      }
      try await finish(reply)
    } catch { status = error.localizedDescription }
  }
  private func local(_ text: String) async throws -> String {
    #if canImport(FoundationModels)
      if #available(iOS 26.0, *) {
        guard SystemLanguageModel.default.availability == .available else {
          throw PocketError.rejected(
            "Apple Intelligence’s on-device model is unavailable. Enable it on a supported iPhone, or configure an HTTPS relay."
          )
        }
        let session = LanguageModelSession(
          instructions:
            "You are Moe, a helpful pocket companion. Give a short, concrete reply that fits a small screen. Do not claim you changed device settings or executed actions."
        )
        return try await session.respond(to: text).content
      }
    #endif
    throw PocketError.rejected(
      "On-device replies require iOS 26 and an Apple Intelligence-capable iPhone. Choose HTTPS relay on other devices."
    )
  }
  func saveMuseToken(_ token: String) throws {
    let host = museHost.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if !token.isEmpty {
      _ = try MuseConnection(host: host, vm: museVM, token: token, directVMToken: museDirectVMToken)
      try PocketKeychain.save(token, name: PocketKeychain.museAccount(host))
    } else if PocketKeychain.read(PocketKeychain.museAccount(host)) == nil {
      throw PocketError.rejected(
        "Enter a Muse account/device token. The gadget SDK token is only for gadget registration.")
    }
    museHost = host
    savePreferences()
  }
  func clearMuseToken() {
    PocketKeychain.delete(PocketKeychain.museAccount(museHost))
    status = "Muse voice credentials removed from iPhone"
  }
  private func muse(text: String?, audio: Data?) async throws -> String {
    let credential =
      museCredential?(museHost) ?? PocketKeychain.read(PocketKeychain.museAccount(museHost))
    guard let token = credential else {
      throw PocketError.rejected(
        "Configure Muse voice credentials in Assistant first. A gadget SDK token cannot authorize voice requests."
      )
    }
    let connection = try MuseConnection(
      host: museHost, vm: museVM, token: token, directVMToken: museDirectVMToken)
    let client =
      museClient
      ?? MuseVoiceClient(fetch: { token in
        var request = URLRequest(url: URL(string: "https://api.muse.ai/fetch_vms")!)
        request.timeoutInterval = 20
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("1.0.0", forHTTPHeaderField: "X-API-Version")
        let (data, _) = try await PocketHTTP.data(for: request, limit: 32768)
        return data
      })
    let task = Task { try await client.reply(connection: connection, text: text, wav: audio) }
    activeMuseTask = task
    defer { activeMuseTask = nil }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
  func cancelMuseRequest() { activeMuseTask?.cancel() }
  private func remote(text: String?, audio: Data?) async throws -> String {
    guard let url = URL(string: endpoint) else {
      throw PocketError.rejected("Configure your HTTPS relay URL first.")
    }
    try EndpointPolicy.validate(url)
    var payload: [String: JSONValue] = ["v": .number(1), "voice": .string(voiceIdentifier)]
    if let text { payload["inputText"] = .string(text) }
    if let audio {
      payload["audio"] = .object([
        "encoding": .string("wav"), "sampleRate": .number(16000),
        "data": .string(audio.base64EncodedString()),
      ])
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token = PocketKeychain.read(PocketKeychain.relayAccount(url)), !token.isEmpty {
      request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONEncoder().encode(JSONValue.object(payload))
    let (data, response) = try await PocketHTTP.data(for: request, limit: 65536)
    guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
      data.count <= 65536
    else { throw PocketError.rejected("The relay could not complete this request.") }
    let result = try JSONDecoder().decode(JSONValue.self, from: data)
    guard let reply = result["reply"].string, !reply.isEmpty else { throw PocketError.malformed }
    return reply
  }
  private func finish(_ reply: String) async throws {
    lastReply = reply
    guard let deliver else { throw PocketError.disconnected }
    let trimmed = reply.pocketPrefix(maxBytes: 360)
    let pcm = try await renderSpeech(trimmed)
    try await deliver(trimmed, pcm)
    status = "Reply queued on Moe"
    if speakOnPhone {
      let utterance = AVSpeechUtterance(string: reply)
      utterance.voice = selectedVoice
      synthesizer.speak(utterance)
    }
  }
  private var selectedVoice: AVSpeechSynthesisVoice? {
    voiceIdentifier.isEmpty
      ? AVSpeechSynthesisVoice(
        language: Locale.current.language.languageCode?.identifier ?? "en-US")
      : AVSpeechSynthesisVoice(identifier: voiceIdentifier)
  }
  private func transcribe(_ url: URL) async throws -> String {
    let authorized = await withCheckedContinuation { c in
      SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
    }
    guard authorized, let recognizer = SFSpeechRecognizer(locale: Locale.current),
      recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
    else {
      throw PocketError.rejected(
        "On-device speech recognition is unavailable. Enable Speech Recognition access or choose your HTTPS relay."
      )
    }
    self.recognizer = recognizer
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false
    return try await withCheckedThrowingContinuation { c in
      speechContinuation = c
      speechDeadline = Task {
        try? await Task.sleep(for: .seconds(45))
        if !Task.isCancelled { self.finishTranscription(.failure(PocketError.timeout)) }
      }
      speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
        let text = result?.bestTranscription.formattedString
        let final = result?.isFinal ?? false
        Task { @MainActor in
          if let error {
            self?.finishTranscription(.failure(error))
          } else if final, let text {
            self?.finishTranscription(.success(text))
          }
        }
      }
    }
  }
  private func finishTranscription(_ result: Result<String, Error>) {
    guard let c = speechContinuation else { return }
    speechContinuation = nil
    speechDeadline?.cancel()
    speechTask?.cancel()
    speechTask = nil
    c.resume(with: result)
  }
  private func renderSpeech(_ text: String) async throws -> [Int16] {
    audioSamples.removeAll()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = selectedVoice
    utterance.rate = Float(voiceRate)
    return try await withCheckedThrowingContinuation { c in
      audioContinuation = c
      audioDeadline = Task {
        try? await Task.sleep(for: .seconds(30))
        if !Task.isCancelled { self.finishSpeech(error: PocketError.timeout) }
      }
      synthesizer.write(utterance) { [weak self] buffer in
        guard let buffer = buffer as? AVAudioPCMBuffer else { return }
        let rate = buffer.format.sampleRate
        let done = buffer.frameLength == 0
        var samples: [Float] = []
        if let channels = buffer.floatChannelData {
          for i in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for ch in 0..<Int(buffer.format.channelCount) { sum += channels[ch][i] }
            samples.append(sum / Float(buffer.format.channelCount))
          }
        }
        Task { @MainActor in
          guard let self, self.audioContinuation != nil else { return }
          self.sampleRate = rate
          let available = max(0, Int(rate * 15) - self.audioSamples.count)
          self.audioSamples.append(contentsOf: samples.prefix(available))
          if done { self.finishSpeech(error: nil) }
        }
      }
    }
  }
  private func finishSpeech(error: Error?) {
    guard let c = audioContinuation else { return }
    audioContinuation = nil
    audioDeadline?.cancel()
    if let error {
      synthesizer.stopSpeaking(at: .immediate)
      c.resume(throwing: error)
      return
    }
    guard !audioSamples.isEmpty, sampleRate > 0 else {
      c.resume(throwing: PocketError.rejected("The selected voice could not generate audio."))
      return
    }
    let count = min(240000, Int(Double(audioSamples.count) * 16000 / sampleRate))
    var pcm = [Int16]()
    pcm.reserveCapacity(count)
    for n in 0..<count {
      let at = Double(n) * sampleRate / 16000
      let low = min(audioSamples.count - 1, Int(at))
      let high = min(audioSamples.count - 1, low + 1)
      let value =
        audioSamples[low] + Float(at - Double(low)) * (audioSamples[high] - audioSamples[low])
      pcm.append(Int16(max(-32768, min(32767, Int(value * 32767)))))
    }
    c.resume(returning: pcm)
    audioSamples.removeAll()
  }
}
