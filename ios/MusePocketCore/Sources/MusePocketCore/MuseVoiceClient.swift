import Foundation

public struct MuseConnection: Sendable {
  public let host: String, vm: String, token: String
  public let directVMToken: Bool
  public init(
    host: String = "hatch.metaaivm.com", vm: String = "", token: String, directVMToken: Bool = false
  ) throws {
    guard !token.isEmpty, token.utf8.count <= 16384,
      !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      vm.utf8.count <= 128,
      !host.isEmpty, host.utf8.count <= 255,
      host.split(separator: ".").count >= 2,
      host.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
          || $0 == 46
      })
    else { throw PocketError.rejected("Enter a Muse device/account token and a valid Muse host.") }
    guard !directVMToken || !vm.isEmpty else {
      throw PocketError.rejected("A VM token requires its VM ID.")
    }
    self.host = host
    self.vm = vm
    self.token = token
    self.directVMToken = directVMToken
  }
  public func websocketRequest(vm: String, token: String) throws -> URLRequest {
    var url = URLComponents()
    url.scheme = "wss"
    url.host = host
    url.path = "/v1/noise"
    url.queryItems = [URLQueryItem(name: "vm_id", value: vm)]
    guard let target = url.url else { throw PocketError.malformed }
    var request = URLRequest(url: target)
    request.timeoutInterval = 20
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    return request
  }
  /// Same /fetch_vms selection as firmware, without silently choosing another Muse.
  public func selectedVM(_ data: Data) throws -> (id: String, token: String) {
    guard data.count <= 32768,
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let list = root["vm_list"] as? [[String: Any]]
    else { throw PocketError.malformed }
    var pick: (id: String, token: String)?
    for item in list {
      guard let token = item["vm_auth_token"] as? String, !token.isEmpty else { continue }
      let address = (item["vm_ws_url"] ?? item["vm_url"]) as? String
      let id =
        (item["vm_id"] as? String)
        ?? address.flatMap { URL(string: $0)?.host?.components(separatedBy: ".").first }
      guard let id, !id.isEmpty, id.utf8.count <= 128 else { continue }
      if vm.isEmpty ? (pick == nil || item["default"] as? Bool == true) : id == vm {
        pick = (id, token)
      }
    }
    guard let pick else {
      throw PocketError.rejected(
        "No matching Muse was returned. Check the VM ID and account token.")
    }
    // Validate service-provided tokens too, before installing an HTTP header.
    _ = try MuseConnection(host: host, vm: pick.id, token: pick.token)
    return pick
  }
}

public protocol MuseSocket: Sendable {
  func send(_ data: Data) async throws
  func receive() async throws -> Data
  func close() async
}
private final class MuseNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
public actor MuseWebSocket: MuseSocket {
  private let session: URLSession
  private let task: URLSessionWebSocketTask
  public init(request: URLRequest) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    session = URLSession(
      configuration: configuration, delegate: MuseNoRedirect(), delegateQueue: nil)
    task = session.webSocketTask(with: request)
    task.maximumMessageSize = 65535
    task.resume()
  }
  public func send(_ data: Data) async throws { try await task.send(.data(data)) }
  public func receive() async throws -> Data {
    switch try await task.receive() {
    case .data(let data): return data
    case .string: throw PocketError.rejected("Muse sent an unexpected text WebSocket frame.")
    @unknown default: throw PocketError.malformed
    }
  }
  public func close() {
    task.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
  }
}

/// Turn-local, bounded SDK event reducer; only descendants of the acknowledged
/// user request can become a spoken reply. Pre-ack events are buffered separately.
public struct MuseReplyCollector: Sendable {
  private var ids = Set<String>(), rejected = Set<String>()
  private var messages: [String: String] = [:], order: [String] = []
  private var done = Set<String>(), pending: [[String: JSONValue]] = []
  private var seq: Double = 0
  private var acknowledged = false
  public private(set) var agentBusy = false
  public init() {}
  public mutating func acknowledge(_ data: Data) throws {
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    let object = root["result"].museObject ?? root.museObject ?? [:]
    ids = Set(
      [object["message_id"]?.string, object["reply_to_message_id"]?.string].compactMap { $0 }.filter
      { !$0.isEmpty })
    guard !ids.isEmpty else {
      throw PocketError.rejected("Muse did not acknowledge this request with a message ID.")
    }
    acknowledged = true
    let early = pending
    pending.removeAll()
    for event in early { try consume(event) }
  }
  public mutating func event(_ data: Data) throws {
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    guard let object = value.museObject, value["type"].string == "event" else { return }
    if !acknowledged {
      guard pending.count < 128 else { throw PocketError.tooLarge }
      pending.append(object)
      return
    }
    try consume(object)
  }
  private mutating func consume(_ object: [String: JSONValue]) throws {
    let value = JSONValue.object(object)
    if let incoming = value["seq"].number, incoming > 0 {
      if incoming <= seq { return }
      seq = incoming
    }
    let event = value["event"].string ?? ""
    let payload = value["payload"]
    if event == "agent.status" || event == "task.status" {
      if let code = payload["activity_code"].string {
        agentBusy = !["", "online", "idle"].contains(code)
      } else if let status = payload["status"].string {
        agentBusy = !["", "completed", "failed"].contains(status)
      }
      return
    }
    guard
      ["delta.message_start", "delta.text_append", "delta.message_done", "message.assistant"]
        .contains(event),
      let id = payload["message_id"].string ?? value["message_id"].string ?? payload["id"].string,
      !id.isEmpty, id.utf8.count <= 128, !rejected.contains(id)
    else { return }
    if messages[id] == nil {
      let parent = payload["reply_to_message_id"].string ?? payload["parent_message_id"].string
      guard let parent, ids.contains(parent) || messages[parent] != nil else {
        guard rejected.count < 128 else { throw PocketError.tooLarge }
        rejected.insert(id)
        return
      }
      guard order.count < 8 else { throw PocketError.tooLarge }
      order.append(id)
      messages[id] = ""
    }
    if event == "delta.text_append", !done.contains(id), let text = payload["text"].string {
      messages[id, default: ""] += text
    }
    if event == "delta.message_done"
      || (event == "message.assistant" && payload["display_text_ready"].bool != false)
    {
      if let final = payload["display_text"].string ?? payload["content"].string, !final.isEmpty {
        messages[id] = final
      }
      done.insert(id)
    }
    guard messages.values.reduce(0, { $0 + $1.utf8.count }) <= 32768 else {
      throw PocketError.tooLarge
    }
  }
  public var finished: Bool {
    acknowledged && !agentBusy && !order.isEmpty && order.allSatisfy { done.contains($0) }
      && !reply.isEmpty
  }
  public var reply: String {
    order.compactMap { messages[$0] }.filter { !$0.isEmpty }.joined(separator: "\n\n")
  }
}

struct MuseLines {
  var pending = Data()
  mutating func add(_ data: Data, end: Bool) throws -> [Data] {
    pending.append(data)
    guard pending.count <= 256 * 1024 else { throw PocketError.tooLarge }
    var lines: [Data] = []
    while let newline = pending.firstIndex(of: 10) {
      let line = Data(pending[..<newline])
      pending.removeSubrange(...newline)
      if !line.isEmpty { lines.append(line) }
    }
    if end && !pending.isEmpty {
      lines.append(pending)
      pending.removeAll()
    }
    return lines
  }
}

public struct MuseVoiceClient: Sendable {
  public typealias FetchVMs = @Sendable (String) async throws -> Data
  public typealias SocketFactory = @Sendable (URLRequest) -> any MuseSocket
  private let fetch: FetchVMs, socketFactory: SocketFactory
  private let deadline: Duration, settle: Duration
  public init(
    fetch: @escaping FetchVMs,
    socketFactory: @escaping SocketFactory = { MuseWebSocket(request: $0) },
    deadline: Duration = .seconds(90), settle: Duration = .seconds(3)
  ) {
    self.fetch = fetch
    self.socketFactory = socketFactory
    self.deadline = deadline
    self.settle = settle
  }
  public static func voiceBody(_ wav: Data) throws -> Data {
    // The existing inbox always supplies mono PCM16 / 16 kHz WAV. Reject malformed
    // or unbounded notes before network activity; the VM handles transcription.
    guard wav.count >= 44, wav.count <= 480044,
      wav.prefix(4) == Data("RIFF".utf8), wav.subdata(in: 8..<16) == Data("WAVEfmt ".utf8),
      wav[20] == 1, wav[21] == 0, wav[22] == 1, wav[23] == 0,
      wav.subdata(in: 24..<28) == Data([0x80, 0x3e, 0, 0]), wav[34] == 16, wav[35] == 0,
      wav.subdata(in: 36..<40) == Data("data".utf8), (wav.count - 44) % 2 == 0,
      wav.count - 44 >= 9600
    else {
      throw PocketError.rejected("Muse voice notes must be 0.3–15 seconds of mono 16 kHz PCM WAV.")
    }
    func u32(_ offset: Int) -> UInt32 {
      (0..<4).reduce(0) { $0 | UInt32(wav[offset + $1]) << ($1 * 8) }
    }
    guard u32(4) == wav.count - 8, u32(16) == 16, u32(40) == wav.count - 44,
      u32(28) == 32000, wav[32] == 2, wav[33] == 0
    else { throw PocketError.malformed }
    return try JSONSerialization.data(withJSONObject: [
      "message": "", "output_modality": "text",
      "items": [
        [
          "type": "file", "mime_type": "audio/wav", "filename": "voice_note.wav",
          "data_base64": wav.base64EncodedString(),
        ]
      ],
    ])
  }
  public func reply(connection: MuseConnection, text: String? = nil, wav: Data? = nil) async throws
    -> String
  {
    let body: Data
    if let wav {
      body = try Self.voiceBody(wav)
    } else if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 16384
    {
      body = try JSONSerialization.data(withJSONObject: [
        "message": text, "output_modality": "text",
      ])
    } else {
      throw PocketError.malformed
    }
    return try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask { try await self.perform(connection, body: body) }
      group.addTask {
        try await Task.sleep(for: self.deadline)
        throw PocketError.timeout
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
  }
  private func perform(_ configuration: MuseConnection, body: Data) async throws -> String {
    let vm =
      configuration.directVMToken
      ? (id: configuration.vm, token: configuration.token)
      : try configuration.selectedVM(try await fetch(configuration.token))
    try Task.checkCancellation()
    let socket = socketFactory(try configuration.websocketRequest(vm: vm.id, token: vm.token))
    return try await withTaskCancellationHandler {
      do {
        let result = try await turn(socket, body: body)
        await socket.close()
        return result
      } catch {
        await socket.close()
        throw error
      }
    } onCancel: {
      Task { await socket.close() }
    }
  }
  private func send(_ frames: [Data], to socket: any MuseSocket) async throws {
    for frame in frames {
      try Task.checkCancellation()
      try await socket.send(frame)
    }
  }
  private func next(_ socket: any MuseSocket, settling: Bool) async throws -> Data? {
    if !settling { return try await socket.receive() }
    return try await withThrowingTaskGroup(of: Data?.self) { group in
      group.addTask { try await socket.receive() }
      group.addTask {
        try await Task.sleep(for: self.settle)
        return nil
      }
      defer { group.cancelAll() }
      let result = try await group.next()!
      // URLSession receive must be explicitly cancelled to release the losing task.
      if result == nil { await socket.close() }
      return result
    }
  }
  private func turn(_ socket: any MuseSocket, body: Data) async throws -> String {
    let noise = try MuseNoiseSession()
    try await socket.send(noise.handshake(1))
    _ = try noise.handshake(2, input: await socket.receive())
    try await socket.send(noise.handshake(3))
    try await send(
      noise.request(stream: 1, path: "/chat/subscribe", body: Data("{}".utf8)), to: socket)
    // Establish the subscription before posting a request, so fast replies aren't lost.
    while true {
      guard let frame = try noise.receive(await socket.receive()) else { continue }
      if frame.kind == 3 { throw PocketError.rejected("Muse subscription was reset.") }
      if frame.stream == 1 && frame.kind == 1 {
        guard (200...299).contains(frame.status) else {
          throw PocketError.rejected("Muse refused the reply subscription (\(frame.status)).")
        }
        break
      }
    }
    try await send(noise.request(stream: 2, path: "/chat/stream", end: false), to: socket)
    for offset in stride(from: 0, to: body.count, by: 16384) {
      let end = min(offset + 16384, body.count)
      try await send(
        noise.chunk(stream: 2, body: body.subdata(in: offset..<end), end: end == body.count),
        to: socket)
    }
    var collector = MuseReplyCollector()
    var lines = MuseLines()
    var ack = Data()
    while true {
      guard let payload = try await next(socket, settling: collector.finished) else {
        return collector.reply
      }
      guard let frame = try noise.receive(payload) else { continue }
      if frame.kind == 3 { throw PocketError.rejected("Muse reset the active voice request.") }
      if frame.kind == 1 && !(200...299).contains(frame.status) {
        throw PocketError.rejected("Muse rejected the request (\(frame.status)).")
      }
      if frame.stream == 2 {
        ack.append(frame.body)
        guard ack.count <= 16384 else { throw PocketError.tooLarge }
        if frame.end { try collector.acknowledge(ack) }
      } else if frame.stream == 1 {
        for line in try lines.add(frame.body, end: frame.end) { try collector.event(line) }
        if frame.end {
          if collector.finished { return collector.reply }
          throw PocketError.rejected("Muse disconnected before completing the reply.")
        }
      }
    }
  }
}

extension JSONValue {
  fileprivate var museObject: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }
}
