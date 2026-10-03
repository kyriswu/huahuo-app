#if (DEBUG && targetEnvironment(simulator)) || BLE_PROXY_TESTING
import CoreBluetooth
import Foundation
import Network

protocol SimulatorBleCentralDelegate: AnyObject {
  func centralManagerDidUpdateState(_ central: SimulatorBleCentral)
  func centralManager(_ central: SimulatorBleCentral, didDiscover peripheral: SimulatorBlePeripheral,
                      advertisementData: [String: Any], rssi: NSNumber)
  func centralManager(_ central: SimulatorBleCentral, didConnect peripheral: SimulatorBlePeripheral)
  func centralManager(_ central: SimulatorBleCentral, didFailToConnect peripheral: SimulatorBlePeripheral, error: Error?)
  func centralManager(_ central: SimulatorBleCentral, didDisconnectPeripheral peripheral: SimulatorBlePeripheral, error: Error?)
}

protocol SimulatorBlePeripheralDelegate: AnyObject {
  func peripheral(_ peripheral: SimulatorBlePeripheral, didDiscoverServices error: Error?)
  func peripheral(_ peripheral: SimulatorBlePeripheral, didDiscoverCharacteristicsFor service: SimulatorBleService, error: Error?)
  func peripheral(_ peripheral: SimulatorBlePeripheral, didUpdateNotificationStateFor characteristic: SimulatorBleCharacteristic, error: Error?)
  func peripheral(_ peripheral: SimulatorBlePeripheral, didUpdateValueFor characteristic: SimulatorBleCharacteristic, error: Error?)
  func peripheral(_ peripheral: SimulatorBlePeripheral, didWriteValueFor characteristic: SimulatorBleCharacteristic, error: Error?)
  func peripheralIsReady(toSendWriteWithoutResponse peripheral: SimulatorBlePeripheral)
}

final class SimulatorBleCharacteristic {
  let handle: String
  let uuid: CBUUID
  let properties: CBCharacteristicProperties
  var isNotifying = false
  var value: Data?
  init(handle: String, uuid: String, properties: UInt) {
    self.handle = handle
    self.uuid = CBUUID(string: uuid)
    self.properties = CBCharacteristicProperties(rawValue: properties)
  }
}

final class SimulatorBleService {
  let handle: String
  let uuid: CBUUID
  var characteristics: [SimulatorBleCharacteristic]?
  init(handle: String, uuid: String) {
    self.handle = handle
    self.uuid = CBUUID(string: uuid)
  }
}

final class SimulatorBlePeripheral {
  let identifier: UUID
  weak var delegate: SimulatorBlePeripheralDelegate?
  weak var central: SimulatorBleCentral?
  var name: String?
  var state: CBPeripheralState = .disconnected
  var services: [SimulatorBleService]?
  var hostReady = false
  var outstandingWrite: Int?
  var maxWithResponse = 20
  var maxWithoutResponse = 20
  var canSendWriteWithoutResponse: Bool {
    state == .connected && hostReady && outstandingWrite == nil
  }

  init(identifier: UUID, central: SimulatorBleCentral) {
    self.identifier = identifier
    self.central = central
  }

  func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
    type == .withoutResponse ? maxWithoutResponse : maxWithResponse
  }
  func discoverServices(_ uuids: [CBUUID]?) {
    send("services", ["uuids": uuids?.map(\.uuidString) ?? []])
  }
  func discoverCharacteristics(_ uuids: [CBUUID]?, for service: SimulatorBleService) {
    send("characteristics", ["service": service.handle, "uuids": uuids?.map(\.uuidString) ?? []])
  }
  func setNotifyValue(_ enabled: Bool, for characteristic: SimulatorBleCharacteristic) {
    send("notify", ["characteristic": characteristic.handle, "enabled": enabled])
  }
  func writeValue(_ data: Data, for characteristic: SimulatorBleCharacteristic, type: CBCharacteristicWriteType) {
    guard let central else { return }
    if type == .withoutResponse && !canSendWriteWithoutResponse {
      central.fail(); return
    }
    let sequence = central.nextSequence
    if type == .withoutResponse { outstandingWrite = sequence }
    send("write", ["characteristic": characteristic.handle, "data": data.base64EncodedString(),
                   "response": type == .withResponse])
  }
  private func send(_ op: String, _ fields: [String: Any]) {
    var fields = fields
    fields["peripheral"] = identifier.uuidString
    central?.send(op, fields)
  }
}

final class SimulatorBleCentral {
  weak var delegate: SimulatorBleCentralDelegate?
  private(set) var state: CBManagerState = .unknown
  private(set) var isScanning = false
  private var socket: BleRelaySocket?
  private var peripherals: [UUID: SimulatorBlePeripheral] = [:]
  private var sequence = 0
  private var heartbeat: Timer?
  private var lastMessage = ProcessInfo.processInfo.systemUptime
  private var authenticated = false
  private(set) var failureCode: String?
  var nextSequence: Int { sequence + 1 }

  init(delegate: SimulatorBleCentralDelegate, queue: DispatchQueue?, options: [String: Any]?) {
    self.delegate = delegate
    // Never resolve arbitrary hostnames: only the same Mac can own the radio.
    let environment = ProcessInfo.processInfo.environment
    guard let rawPort = environment["HUAHUO_BLE_PROXY_PORT"],
          let port = UInt16(rawPort), port > 0,
          let token = environment["HUAHUO_BLE_PROXY_TOKEN"], token.count >= 32 else {
      state = .unsupported
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }; self.delegate?.centralManagerDidUpdateState(self)
      }
      return
    }
    let socket = BleRelaySocket(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp))
    self.socket = socket
    socket.onReady = { [weak self] in self?.send("hello", ["token": token]) }
    socket.onMessage = { [weak self] message in self?.receive(message) }
    socket.onClose = { [weak self] in self?.fail() }
    socket.start()
    heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      guard let self else { return }
      if ProcessInfo.processInfo.systemUptime - self.lastMessage > 6 { self.fail(); return }
      if self.authenticated { self.send("ping") }
    }
  }

  deinit { heartbeat?.invalidate(); socket?.close() }

  func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Any]?) {
    guard state == .poweredOn else { delegate?.centralManagerDidUpdateState(self); return }
    isScanning = true
    send("scan", ["uuids": services?.map(\.uuidString) ?? [], "duplicates": true])
  }
  func stopScan() { isScanning = false; send("stopScan") }
  func connect(_ peripheral: SimulatorBlePeripheral, options: [String: Any]?) {
    peripheral.state = .connecting
    send("connect", ["peripheral": peripheral.identifier.uuidString])
  }
  func cancelPeripheralConnection(_ peripheral: SimulatorBlePeripheral) {
    peripheral.state = .disconnecting
    send("disconnect", ["peripheral": peripheral.identifier.uuidString])
  }
  func send(_ operation: String, _ fields: [String: Any] = [:]) {
    guard let socket else { return }
    sequence += 1
    var message = fields
    message["v"] = 1; message["seq"] = sequence; message["op"] = operation
    socket.send(message)
  }

  func fail() {
    guard socket != nil else { return }
    let previous = socket
    socket = nil
    previous?.close()
    heartbeat?.invalidate(); heartbeat = nil
    authenticated = false; isScanning = false
    failureCode = "RECORDING_CARD_BLE_PROXY_DISCONNECTED"
    state = .poweredOff
    let error = NSError(domain: "HuahuoBleRelay", code: 1)
    for peripheral in Array(peripherals.values) where peripheral.state != .disconnected {
      let connecting = peripheral.state == .connecting
      peripheral.state = .disconnected
      peripheral.hostReady = false; peripheral.outstandingWrite = nil
      if connecting { delegate?.centralManager(self, didFailToConnect: peripheral, error: error) }
      else { delegate?.centralManager(self, didDisconnectPeripheral: peripheral, error: error) }
    }
    peripherals.removeAll()
    delegate?.centralManagerDidUpdateState(self)
  }

  private func receive(_ message: [String: Any]) {
    guard socket != nil, let event = message["event"] as? String else { fail(); return }
    lastMessage = ProcessInfo.processInfo.systemUptime
    if event == "hello" { authenticated = true; return }
    guard authenticated else { fail(); return }
    if event == "pong" { return }
    if event == "failure" { fail(); return }
    if event == "state" {
      guard let raw = message["state"] as? Int, let next = CBManagerState(rawValue: raw) else { fail(); return }
      state = next
      if state != .poweredOn { isScanning = false }
      delegate?.centralManagerDidUpdateState(self)
      return
    }
    guard let id = message["peripheral"] as? String, let uuid = UUID(uuidString: id) else { fail(); return }
    let peripheral: SimulatorBlePeripheral
    if let existing = peripherals[uuid] { peripheral = existing }
    else if event == "discovered" {
      peripheral = SimulatorBlePeripheral(identifier: uuid, central: self)
      peripherals[uuid] = peripheral
    } else { return }
    let error: Error? = (message["error"] as? Bool == true) ? NSError(domain: "HuahuoBleRelay", code: 2) : nil
    switch event {
    case "discovered":
      guard isScanning else { return }
      peripheral.name = message["name"] as? String
      var advertisement: [String: Any] = [:]
      if let encoded = message["manufacturer"] as? String, let data = Data(base64Encoded: encoded) {
        advertisement[CBAdvertisementDataManufacturerDataKey] = data
      }
      if let name = message["localName"] as? String { advertisement[CBAdvertisementDataLocalNameKey] = name }
      if let value = message["connectable"] as? Bool { advertisement[CBAdvertisementDataIsConnectable] = value }
      delegate?.centralManager(self, didDiscover: peripheral, advertisementData: advertisement,
                               rssi: NSNumber(value: message["rssi"] as? Int ?? 127))
    case "connected":
      peripheral.state = .connected
      peripheral.hostReady = message["ready"] as? Bool ?? false
      peripheral.maxWithResponse = message["maxWithResponse"] as? Int ?? 20
      peripheral.maxWithoutResponse = message["maxWithoutResponse"] as? Int ?? 20
      peripheral.services = nil; peripheral.outstandingWrite = nil
      delegate?.centralManager(self, didConnect: peripheral)
    case "disconnected", "connectFailed":
      peripheral.state = .disconnected
      peripheral.hostReady = false; peripheral.outstandingWrite = nil
      if event == "connectFailed" { delegate?.centralManager(self, didFailToConnect: peripheral, error: error) }
      else { delegate?.centralManager(self, didDisconnectPeripheral: peripheral, error: error) }
    case "services":
      peripheral.services = (message["services"] as? [[String: Any]] ?? []).compactMap {
        guard let handle = $0["handle"] as? String, let uuid = $0["uuid"] as? String else { return nil }
        return SimulatorBleService(handle: handle, uuid: uuid)
      }
      peripheral.delegate?.peripheral(peripheral, didDiscoverServices: error)
    case "characteristics":
      guard let service = peripheral.services?.first(where: { $0.handle == message["service"] as? String }) else { return }
      service.characteristics = (message["characteristics"] as? [[String: Any]] ?? []).compactMap {
        guard let handle = $0["handle"] as? String, let uuid = $0["uuid"] as? String,
              let properties = $0["properties"] as? UInt else { return nil }
        return SimulatorBleCharacteristic(handle: handle, uuid: uuid, properties: properties)
      }
      peripheral.delegate?.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error)
    case "notify", "value", "written":
      guard let characteristic = peripheral.services?.flatMap({ $0.characteristics ?? [] })
        .first(where: { $0.handle == message["characteristic"] as? String }) else { return }
      if event == "notify" {
        characteristic.isNotifying = message["notifying"] as? Bool ?? false
        peripheral.delegate?.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error)
      } else if event == "value" {
        characteristic.value = (message["data"] as? String).flatMap { Data(base64Encoded: $0) }
        peripheral.delegate?.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
      } else { peripheral.delegate?.peripheral(peripheral, didWriteValueFor: characteristic, error: error) }
    case "flow":
      if let ack = message["ack"] as? Int, peripheral.outstandingWrite == ack { peripheral.outstandingWrite = nil }
      peripheral.hostReady = message["ready"] as? Bool ?? false
      if peripheral.canSendWriteWithoutResponse { peripheral.delegate?.peripheralIsReady(toSendWriteWithoutResponse: peripheral) }
    default: fail()
    }
  }
}
#endif
