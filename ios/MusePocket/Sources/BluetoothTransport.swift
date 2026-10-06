import AccessorySetupKit
import CoreBluetooth
import Foundation
import MusePocketCore
import Observation
import UIKit

struct NearbyMoe: Identifiable {
  let id: UUID, name: String
  var rssi: Int
}
@MainActor @Observable
final class BluetoothTransport: NSObject, @preconcurrency CBCentralManagerDelegate,
  @preconcurrency CBPeripheralDelegate
{
  private(set) var state = "Not connected"
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
  @ObservationIgnored private var secureRead = false
  override init() {
    super.init()
    central = CBCentralManager(
      delegate: self, queue: .main,
      options: [CBCentralManagerOptionRestoreIdentifierKey: "MusePocket.central.v1"])
  }
  func scan() {
    guard central.state == .poweredOn else {
      state = "Turn Bluetooth on to find Moe."
      return
    }
    nearby.removeAll()
    state = "Looking for Moe…"
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
  func pairWithSystemPicker() {
    guard !accessoryActive else {
      presentPicker()
      return
    }
    accessoryActive = true
    accessorySession.activate(on: .main) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self else { return }
        if event.eventType == .activated {
          self.presentPicker()
        } else if event.eventType == .accessoryAdded, let id = event.accessory?.bluetoothIdentifier
        {
          self.connect(id)
        } else if event.eventType == .pickerDidDismiss, self.desired == nil {
          self.state = "Choose Moe or scan nearby devices."
        }
        if let error = event.error { self.state = error.localizedDescription }
      }
    }
  }
  private func presentPicker() {
    let descriptor = ASDiscoveryDescriptor()
    descriptor.bluetoothServiceUUID = CBUUID(string: PocketUUID.advertisedService)
    let image = UIImage(systemName: "circle.inset.filled") ?? UIImage()
    let item = ASPickerDisplayItem(
      name: "Pocket Muse Moe", productImage: image, descriptor: descriptor)
    accessorySession.showPicker(for: [item]) { [weak self] error in
      MainActor.assumeIsolated { if let error { self?.state = error.localizedDescription } }
    }
  }
  func connect(_ id: UUID) {
    retry?.cancel()
    desired = id
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
    retry?.cancel()
    if let peripheral { central.cancelPeripheralConnection(peripheral) }
    clear(PocketError.disconnected)
    state = "Not connected"
  }
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state != .poweredOn {
      clear(PocketError.disconnected)
      state =
        central.state == .unauthorized ? "Allow Bluetooth in iPhone Settings." : "Bluetooth is off."
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
    clear(error ?? PocketError.disconnected)
    state = "Connection lost. Moe’s local tools keep working."
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
    for c in service.characteristics ?? [] {
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
