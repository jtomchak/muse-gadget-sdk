import AccessorySetupKit
import CoreBluetooth
import Foundation
import MusePocketCore
import Observation
import UIKit

struct NearbyMoe: Identifiable {
  let id: UUID, name: String
  var rssi: Int?
}
@MainActor @Observable
final class BluetoothTransport: NSObject, @preconcurrency CBCentralManagerDelegate,
  @preconcurrency CBPeripheralDelegate
{
  private(set) var state = "Not connected" {
    didSet { trace("state: " + state) }
  }
  private(set) var nearby: [NearbyMoe] = []
  private(set) var connected = false
  private(set) var protocolReady = false
  var onReady: (() -> Void)?
  var onEvent: ((JSONValue) -> Void)?
  var onDisconnect: (() -> Void)?
  @ObservationIgnored private var central: CBCentralManager!
  @ObservationIgnored private var peripheral: CBPeripheral?
  @ObservationIgnored private var found: [UUID: CBPeripheral] = [:]
  @ObservationIgnored private var command: CBCharacteristic?
  @ObservationIgnored private var response: CBCharacteristic?
  @ObservationIgnored private var legacy: CBCharacteristic?
  @ObservationIgnored private var assembler = FrameAssembler()
  @ObservationIgnored private var transfer: UInt16 = 0
  @ObservationIgnored private var frames: [Data] = []
  @ObservationIgnored private var writeIndex = 0
  @ObservationIgnored private var pending:
    (id: String, continuation: CheckedContinuation<JSONValue, Error>)?
  @ObservationIgnored private var writeContinuation: CheckedContinuation<Void, Error>?
  @ObservationIgnored private var timeout: Task<Void, Never>?
  @ObservationIgnored private var retry: Task<Void, Never>?
  @ObservationIgnored private var desired: UUID?
  @ObservationIgnored private var retryCount = 0
  @ObservationIgnored private let accessorySession = ASAccessorySession()
  @ObservationIgnored private var accessoryActive = false
  @ObservationIgnored private var accessoryActivated = false
  @ObservationIgnored private var pickerRequested = false
  @ObservationIgnored private var pickerShowing = false
  @ObservationIgnored private var pickedAccessory: UUID?
  @ObservationIgnored private var scanPending = false
  @ObservationIgnored private var secureRead = false
  override init() {
    super.init()
    central = CBCentralManager(
      delegate: self, queue: .main,
      options: [CBCentralManagerOptionRestoreIdentifierKey: "MusePocket.central.v1"])
    activateAccessorySession()
  }
  private func trace(_ message: String) {
    #if DEBUG
      print("[MusePocket BLE] " + message)
      fflush(nil)
    #endif
  }
  private func traceError(_ stage: String, _ error: Error?) {
    if let error {
      let error = error as NSError
      trace("\(stage): \(error.domain) code=\(error.code)")
    }
  }
  func scan() {
    trace(
      "scan requested; central=\(central.state.rawValue) authorization=\(CBManager.authorization.rawValue)"
    )
    guard accessoryActivated else {
      scanPending = true
      state = "Preparing accessory discovery…"
      activateAccessorySession()
      return
    }
    // ASK-scoped apps get poweredOff until an accessory is authorized. An
    // ordinary CoreBluetooth scan cannot bootstrap this authorization.
    guard accessorySession.accessories.contains(where: { $0.bluetoothIdentifier != nil }) else {
      scanPending = false
      pairWithSystemPicker()
      return
    }
    guard central.state == .poweredOn else {
      scanPending = true
      state = "Waiting for Bluetooth. Check iPhone Bluetooth settings."
      return
    }
    scanPending = false
    nearby.removeAll()
    state = "Looking for Moe…"
    // iOS can share a peripheral connection between apps. It may no longer
    // advertise while Muse owns that physical link, so include connected peers.
    let connectedPeers = central.retrieveConnectedPeripherals(withServices: [
      CBUUID(string: PocketUUID.advertisedService), CBUUID(string: PocketUUID.service),
    ])
    for peripheral in connectedPeers {
      found[peripheral.identifier] = peripheral
      nearby.append(NearbyMoe(id: peripheral.identifier, name: peripheral.name ?? "Moe", rssi: nil))
    }
    trace("already-connected matching peripherals=\(connectedPeers.count)")
    central.scanForPeripherals(
      withServices: [CBUUID(string: PocketUUID.advertisedService)],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    Task {
      try? await Task.sleep(for: .seconds(12))
      self.central.stopScan()
      if !self.connected {
        self.state =
          self.nearby.isEmpty
          ? "No Moe nearby. Enable Phone setup on the device." : "Choose your Moe."
      }
    }
  }
  private func activateAccessorySession() {
    guard !accessoryActive else { return }
    accessoryActive = true
    accessorySession.activate(on: .main) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.trace("accessory event=\(event.eventType.rawValue)")
        self.traceError("accessory event", event.error)
        switch event.eventType {
        case .activated:
          self.accessoryActivated = true
          self.trace("authorized accessories=\(self.accessorySession.accessories.count)")
          if self.pickerRequested {
            self.presentPicker()
          } else if self.scanPending {
            self.scan()
          } else if self.accessorySession.accessories.isEmpty {
            self.state = "Pair Moe to authorize MusePocket. Keep its Muse pairing."
          }
        case .accessoryAdded:
          self.pickedAccessory = event.accessory?.bluetoothIdentifier
        case .pickerDidPresent:
          self.pickerShowing = true
        case .pickerDidDismiss:
          self.pickerShowing = false
          self.pickerRequested = false
          if let id = self.pickedAccessory {
            self.pickedAccessory = nil
            self.connect(id)
          } else if self.desired == nil {
            self.state = "Keep Phone setup on Moe enabled, then choose Pair Moe."
          }
        case .invalidated:
          self.accessoryActivated = false
          self.pickerRequested = false
          self.pickerShowing = false
          self.state = "Accessory setup is unavailable. Reopen MusePocket to retry."
        default: break
        }
        if let error = event.error { self.state = error.localizedDescription }
      }
    }
  }
  func pairWithSystemPicker() {
    trace("system accessory picker requested")
    pickerRequested = true
    activateAccessorySession()
    if accessoryActivated { presentPicker() } else { state = "Preparing accessory picker…" }
  }
  private func presentPicker() {
    guard accessoryActivated, !pickerShowing else { return }
    pickerShowing = true
    state = "Choose Moe in the iPhone accessory picker."
    let descriptor = ASDiscoveryDescriptor()
    descriptor.bluetoothServiceUUID = CBUUID(string: PocketUUID.advertisedService)
    // ASK also requires an accessory identifier alongside the service UUID.
    // Match the firmware's scan-response name; keep this declared in Info.plist.
    descriptor.bluetoothNameSubstring = "MuseGadget-"
    descriptor.supportedOptions = [.bluetoothPairingLE]
    let image = UIImage(systemName: "circle.inset.filled") ?? UIImage()
    let item = ASPickerDisplayItem(
      name: "Pocket Muse Moe", productImage: image, descriptor: descriptor)
    accessorySession.showPicker(for: [item]) { [weak self] error in
      MainActor.assumeIsolated {
        if let error {
          self?.pickerShowing = false
          self?.pickerRequested = false
          self?.traceError("show picker", error)
          self?.state = error.localizedDescription
        }
      }
    }
  }
  func connect(_ id: UUID) {
    trace("connect requested")
    retry?.cancel()
    desired = id
    guard central.state == .poweredOn else {
      state = "Waiting for iPhone accessory authorization…"
      return
    }
    central.stopScan()
    let target = found[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
    guard let target else {
      state = "Moe is unavailable. Try scanning again."
      return
    }
    if let previous = peripheral, previous.identifier != target.identifier {
      central.cancelPeripheralConnection(previous)
      clear(PocketError.disconnected)
    }
    peripheral = target
    target.delegate = self
    state = "Connecting…"
    central.connect(target)
  }
  func disconnect() {
    desired = nil
    pickedAccessory = nil
    scanPending = false
    retry?.cancel()
    if let peripheral { central.cancelPeripheralConnection(peripheral) }
    clear(PocketError.disconnected)
    state = "Not connected"
  }
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    trace(
      "central state=\(central.state.rawValue) authorization=\(CBManager.authorization.rawValue)")
    if central.state == .poweredOn {
      if let desired, !connected { connect(desired) } else if scanPending { scan() }
    } else {
      clear(PocketError.disconnected)
      if !accessoryActivated || accessorySession.accessories.isEmpty {
        state = "Pair Moe to authorize MusePocket. Keep its Muse pairing."
      } else {
        switch central.state {
        case .unauthorized: state = "Allow MusePocket accessory access in iPhone Settings."
        case .poweredOff: state = "Turn Bluetooth on in iPhone Settings."
        case .unsupported: state = "Bluetooth is unavailable on this device."
        default: state = "Waiting for Bluetooth…"
        }
      }
    }
  }
  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    guard
      let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
    else { return }
    peripheral = restored
    desired = restored.identifier
    restored.delegate = self
    if restored.state == .connected {
      restored.discoverServices([CBUUID(string: PocketUUID.service)])
    } else {
      central.connect(restored)
    }
  }
  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    trace("advertisement discovered; rssi=\(RSSI.intValue)")
    found[peripheral.identifier] = peripheral
    let item = NearbyMoe(
      id: peripheral.identifier, name: peripheral.name ?? "Moe", rssi: RSSI.intValue)
    if let i = nearby.firstIndex(where: { $0.id == item.id }) {
      nearby[i] = item
    } else {
      nearby.append(item)
    }
  }
  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard desired == peripheral.identifier else {
      central.cancelPeripheralConnection(peripheral)
      return
    }
    self.peripheral = peripheral
    connected = true
    trace("CoreBluetooth connected; discovering companion service")
    retryCount = 0
    state = "Pairing securely. Enter the code shown on Moe."
    peripheral.discoverServices([CBUUID(string: PocketUUID.service)])
  }
  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) { disconnected(peripheral, error: error) }
  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) { disconnected(peripheral, error: error) }
  private func disconnected(_ p: CBPeripheral, error: Error?) {
    guard desired == p.identifier else { return }
    traceError("disconnected", error)
    clear(error ?? PocketError.disconnected)
    state =
      error.map { "Connection lost: " + $0.localizedDescription }
      ?? "Connection lost. Check Phone setup on Moe."
    onDisconnect?()
    guard desired == p.identifier else { return }
    retryCount += 1
    let delay = min(30, 1 << min(5, retryCount))
    retry = Task {
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, self.central.state == .poweredOn, self.desired == p.identifier else {
        return
      }
      self.central.connect(p)
    }
  }
  private func clear(_ error: Error) {
    connected = false
    protocolReady = false
    secureRead = false
    command = nil
    response = nil
    legacy = nil
    assembler.reset()
    frames.removeAll()
    timeout?.cancel()
    pending?.continuation.resume(throwing: error)
    pending = nil
    writeContinuation?.resume(throwing: error)
    writeContinuation = nil
  }
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    traceError("service discovery", error)
    trace("discovered companion services=\(peripheral.services?.count ?? 0)")
    guard desired == peripheral.identifier else { return }
    guard error == nil,
      let service = peripheral.services?.first(where: {
        $0.uuid == CBUUID(string: PocketUUID.service)
      })
    else {
      state = "This device does not expose Muse phone setup."
      return
    }
    peripheral.discoverCharacteristics(nil, for: service)
  }
  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    guard desired == peripheral.identifier else { return }
    guard error == nil else {
      state = error!.localizedDescription
      return
    }
    trace("companion characteristics=\(service.characteristics?.count ?? 0)")
    for c in service.characteristics ?? [] {
      trace("characteristic \(c.uuid.uuidString) properties=\(c.properties.rawValue)")
      switch c.uuid.uuidString.uppercased() {
      case PocketUUID.command: command = c
      case PocketUUID.response: response = c
      case PocketUUID.legacyCommand: legacy = c
      default: break
      }
    }
    guard let response, command != nil else {
      state = "Update Moe to firmware with MusePocket v1. Wi-Fi setup is still available."
      return
    }
    peripheral.setNotifyValue(true, for: response)
    peripheral.readValue(for: response)
  }
  func peripheral(
    _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard desired == peripheral.identifier else { return }
    traceError("subscription", error)
    trace("response notifying=\(characteristic.isNotifying)")
    if let error { state = error.localizedDescription } else { becomeReady() }
  }
  private func becomeReady() {
    guard secureRead, response?.isNotifying == true, !protocolReady else { return }
    protocolReady = true
    state = "Connected securely"
    onReady?()
  }
  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard desired == peripheral.identifier else { return }
    if !protocolReady || error != nil {
      traceError("secure response read", error)
      trace("handshake read bytes=\(characteristic.value?.count ?? 0)")
    }
    guard let data = characteristic.value, error == nil else {
      if let error { state = error.localizedDescription }
      return
    }
    if let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      value["ready"].bool == true
    {
      guard value["v"].number == 1 else {
        state = "Unsupported MusePocket protocol."
        return
      }
      secureRead = true
      becomeReady()
      return
    }
    do {
      guard
        let (kind, message) = try assembler.consume(data, now: ProcessInfo.processInfo.systemUptime)
      else { return }
      if kind == .event {
        onEvent?(try JSONDecoder().decode(JSONValue.self, from: message))
        return
      }
      guard kind == .response else { throw PocketError.malformed }
      let reply = try JSONDecoder().decode(PocketResponse.self, from: message)
      guard reply.v == 1, let request = pending, request.id == reply.id else { return }
      pending = nil
      timeout?.cancel()
      frames.removeAll()
      if reply.ok {
        request.continuation.resume(returning: reply.result ?? .null)
      } else {
        request.continuation.resume(
          throwing: PocketError.rejected(reply.error ?? "Moe rejected the request."))
      }
    } catch {
      pending?.continuation.resume(throwing: error)
      pending = nil
      frames.removeAll()
      timeout?.cancel()
      state = error.localizedDescription
    }
  }
  func request(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
    guard protocolReady, let command, let peripheral else { throw PocketError.disconnected }
    guard pending == nil, writeContinuation == nil else {
      throw PocketError.rejected("Wait for the current Bluetooth transfer.")
    }
    let envelope = PocketRequest(method: method, params: params)
    let data = try JSONEncoder().encode(envelope)
    transfer &+= 1
    frames = try PocketFrame.encode(
      data, transfer: transfer,
      mtu: min(512, peripheral.maximumWriteValueLength(for: .withResponse)))
    writeIndex = 0
    return try await withCheckedThrowingContinuation { continuation in
      pending = (envelope.id, continuation)
      timeout = Task {
        try? await Task.sleep(for: .seconds(35))
        guard !Task.isCancelled, self.pending?.id == envelope.id else { return }
        self.pending?.continuation.resume(throwing: PocketError.timeout)
        self.pending = nil
        self.frames.removeAll()
      }
      peripheral.writeValue(frames[0], for: command, type: .withResponse)
    }
  }
  func sendLegacy(_ text: String) async throws {
    guard connected, let legacy, let peripheral else { throw PocketError.disconnected }
    guard pending == nil, writeContinuation == nil else {
      throw PocketError.rejected("Wait for the current Bluetooth transfer.")
    }
    let data = Data(text.utf8)
    guard data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
      throw PocketError.tooLarge
    }
    try await withCheckedThrowingContinuation { continuation in
      writeContinuation = continuation
      timeout = Task {
        try? await Task.sleep(for: .seconds(35))
        guard !Task.isCancelled, let c = self.writeContinuation else { return }
        self.writeContinuation = nil
        c.resume(throwing: PocketError.timeout)
      }
      peripheral.writeValue(data, for: legacy, type: .withResponse)
    }
  }
  func peripheral(
    _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard desired == peripheral.identifier else { return }
    if characteristic.uuid == CBUUID(string: PocketUUID.legacyCommand) {
      let c = writeContinuation
      writeContinuation = nil
      timeout?.cancel()
      if let error { c?.resume(throwing: error) } else { c?.resume() }
      return
    }
    if let error {
      pending?.continuation.resume(throwing: error)
      pending = nil
      frames.removeAll()
      timeout?.cancel()
      return
    }
    writeIndex += 1
    if writeIndex < frames.count, let command {
      peripheral.writeValue(frames[writeIndex], for: command, type: .withResponse)
    }
  }
}
