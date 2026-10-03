import AppKit
import CoreBluetooth
import Foundation
import Network

// This host deliberately contains no recording-card protocol implementation.
final class BleRelayHost: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  private let token: String
  private let readyFile: URL
  private var listener: NWListener!
  private var client: BleRelaySocket?
  private var gate: BleRelaySessionGate
  private var central: CBCentralManager!
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var services: [String: CBService] = [:]
  private var characteristics: [String: CBCharacteristic] = [:]
  private var retiring = Set<UUID>()
  private var timer: Timer?
  private var lastRequest = ProcessInfo.processInfo.systemUptime
  private var authenticated: Bool { gate.authenticated && client != nil }

  init(token: String, readyFile: URL) throws {
    guard token.count >= 32 else { throw BleRelayError.authentication }
    self.token = token; self.readyFile = readyFile
    gate = BleRelaySessionGate(token: token)
    super.init()
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      if case .ready = state, let port = self.listener.port {
        do {
          try Data(String(port.rawValue).utf8).write(to: self.readyFile, options: .atomic)
          NSLog("[BLE Relay] listening on loopback; waiting for authenticated simulator")
        } catch { exit(1) }
      } else if case .failed = state { exit(1) }
    }
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    listener.start(queue: .main)
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.retiring = self.retiring.filter { self.peripherals[$0]?.state != .disconnected }
      if self.client != nil && ProcessInfo.processInfo.systemUptime - self.lastRequest > 8 {
        self.client?.close()
      }
    }
  }

  private func accept(_ connection: NWConnection) {
    guard client == nil, retiring.isEmpty else { connection.cancel(); return }
    peripherals.removeAll(); services.removeAll(); characteristics.removeAll()
    gate = BleRelaySessionGate(token: token)
    lastRequest = ProcessInfo.processInfo.systemUptime
    let socket = BleRelaySocket(connection)
    client = socket
    socket.onMessage = { [weak self, weak socket] message in
      guard let self, let socket, self.client === socket else { return }
      do {
        try self.gate.accept(message)
        self.lastRequest = ProcessInfo.processInfo.systemUptime
        try self.handle(message)
      } catch {
        NSLog("[BLE Relay] request rejected; session closed")
        socket.close()
      }
    }
    socket.onClose = { [weak self, weak socket] in
      guard let self, self.client === socket else { return }
      self.client = nil
      if self.central?.state == .poweredOn {
        self.central.stopScan()
        for peripheral in self.peripherals.values where peripheral.state != .disconnected {
          self.retiring.insert(peripheral.identifier)
          self.central.cancelPeripheralConnection(peripheral)
          peripheral.delegate = nil
        }
      }
      self.central?.delegate = nil
      self.central = nil
      self.services.removeAll(); self.characteristics.removeAll()
      NSLog("[BLE Relay] client ended; BLE work retired")
    }
    socket.start()
  }

  private func handle(_ m: [String: Any]) throws {
    guard let op = m["op"] as? String else { throw BleRelayError.invalidFrame }
    if op == "hello" {
      emit("hello")
      if central == nil {
        central = CBCentralManager(delegate: self, queue: .main,
          options: [CBCentralManagerOptionShowPowerAlertKey: false])
      } else { emit("state", ["state": central.state.rawValue]) }
      NSLog("[BLE Relay] authenticated; CoreBluetooth active")
      return
    }
    if op == "ping" { emit("pong"); return }
    guard central?.state == .poweredOn else { emit("state", ["state": central?.state.rawValue ?? 0]); return }
    if op == "scan" {
      central.scanForPeripherals(withServices: try uuids(m), options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]); return
    }
    if op == "stopScan" { central.stopScan(); return }
    guard let raw = m["peripheral"] as? String, let id = UUID(uuidString: raw),
          let p = peripherals[id], !retiring.contains(id) else { throw BleRelayError.invalidFrame }
    if op == "connect" {
      guard p.state == .disconnected else { throw BleRelayError.invalidFrame }
      // One simulator owns one selected radio link.
      guard !peripherals.values.contains(where: { $0 !== p && $0.state != .disconnected }) else {
        throw BleRelayError.invalidFrame
      }
      p.delegate = self; central.connect(p, options: nil); return
    }
    if op == "disconnect" { central.cancelPeripheralConnection(p); return }
    guard p.state == .connected else { throw BleRelayError.invalidFrame }
    switch op {
    case "services": p.discoverServices(try uuids(m))
    case "characteristics":
      guard let handle = m["service"] as? String, let service = services[handle],
            service.peripheral === p else { throw BleRelayError.invalidFrame }
      p.discoverCharacteristics(try uuids(m), for: service)
    case "notify", "write":
      guard let handle = m["characteristic"] as? String, let c = characteristics[handle],
            c.service?.peripheral === p else { throw BleRelayError.invalidFrame }
      if op == "notify" {
        guard let enabled = m["enabled"] as? Bool else { throw BleRelayError.invalidFrame }
        p.setNotifyValue(enabled, for: c)
      } else {
        guard let encoded = m["data"] as? String, let data = Data(base64Encoded: encoded),
              let response = m["response"] as? Bool else { throw BleRelayError.invalidFrame }
        let type: CBCharacteristicWriteType = response ? .withResponse : .withoutResponse
        guard data.count > 0, data.count <= p.maximumWriteValueLength(for: type),
              c.properties.contains(response ? .write : .writeWithoutResponse),
              response || p.canSendWriteWithoutResponse else { throw BleRelayError.invalidFrame }
        p.writeValue(data, for: c, type: type)
        if !response { emit("flow", p, ["ready": p.canSendWriteWithoutResponse, "ack": m["seq"]!]) }
      }
    default: throw BleRelayError.invalidFrame
    }
  }

  private func uuids(_ m: [String: Any]) throws -> [CBUUID]? {
    guard let values = m["uuids"] as? [String], values.count <= 32,
          values.allSatisfy({ $0.range(of: "^(?:[0-9A-Fa-f]{4}|[0-9A-Fa-f]{8}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})$", options: .regularExpression) != nil })
    else { throw BleRelayError.invalidFrame }
    return values.isEmpty ? nil : values.map { CBUUID(string: $0) }
  }
  private func emit(_ event: String, _ fields: [String: Any] = [:]) {
    guard authenticated else { return }
    var m = fields; m["v"] = 1; m["event"] = event
    client?.send(m)
  }
  private func emit(_ event: String, _ p: CBPeripheral, _ fields: [String: Any] = [:]) {
    guard peripherals[p.identifier] === p, !retiring.contains(p.identifier) else { return }
    var fields = fields; fields["peripheral"] = p.identifier.uuidString
    emit(event, fields)
  }
  private func handle(_ service: CBService) -> String {
    if let existing = services.first(where: { $0.value === service }) { return existing.key }
    let id = UUID().uuidString; services[id] = service; return id
  }
  private func handle(_ characteristic: CBCharacteristic) -> String {
    if let existing = characteristics.first(where: { $0.value === characteristic }) { return existing.key }
    let id = UUID().uuidString; characteristics[id] = characteristic; return id
  }
  private func event(_ event: String, _ p: CBPeripheral, _ c: CBCharacteristic, _ error: Error?, _ extras: [String: Any] = [:]) {
    guard let handle = characteristics.first(where: { $0.value === c })?.key else { return }
    var fields = extras; fields["characteristic"] = handle; fields["error"] = error != nil
    emit(event, p, fields)
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central === self.central else { return }
    NSLog("[BLE Relay] radio state=%ld", central.state.rawValue)
    emit("state", ["state": central.state.rawValue])
  }
  func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
    guard central === self.central, authenticated, central.isScanning else { return }
    guard peripherals.count < 512 || peripherals[p.identifier] != nil else { return }
    peripherals[p.identifier] = p
    var fields: [String: Any] = ["rssi": rssi.intValue]
    if let name = p.name { fields["name"] = name }
    if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String { fields["localName"] = name }
    if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data { fields["manufacturer"] = data.base64EncodedString() }
    if let flag = advertisementData[CBAdvertisementDataIsConnectable] as? Bool { fields["connectable"] = flag }
    emit("discovered", p, fields)
  }
  func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
    guard central === self.central, authenticated, !retiring.contains(p.identifier) else { central.cancelPeripheralConnection(p); return }
    emit("connected", p, ["ready": p.canSendWriteWithoutResponse,
      "maxWithResponse": p.maximumWriteValueLength(for: .withResponse),
      "maxWithoutResponse": p.maximumWriteValueLength(for: .withoutResponse)])
  }
  func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
    guard central === self.central else { return }
    if retiring.remove(p.identifier) != nil { return }
    emit("connectFailed", p, ["error": error != nil])
  }
  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
    guard central === self.central else { return }
    services = services.filter { $0.value.peripheral !== p }
    characteristics = characteristics.filter { $0.value.service?.peripheral !== p }
    if retiring.remove(p.identifier) != nil { return }
    emit("disconnected", p, ["error": error != nil])
  }
  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    emit("services", p, ["error": error != nil, "services": (p.services ?? []).map { ["handle": handle($0), "uuid": $0.uuid.uuidString] }])
  }
  func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    let rows: [[String: Any]] = (service.characteristics ?? []).map {
      ["handle": handle($0), "uuid": $0.uuid.uuidString, "properties": $0.properties.rawValue]
    }
    emit("characteristics", p, ["error": error != nil, "service": handle(service), "characteristics": rows])
  }
  func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
    event("notify", p, c, error, ["notifying": c.isNotifying])
  }
  func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
    event("value", p, c, error, ["data": c.value?.base64EncodedString() ?? ""])
  }
  func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
    event("written", p, c, error)
  }
  func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
    emit("flow", p, ["ready": p.canSendWriteWithoutResponse])
  }
}

let env = ProcessInfo.processInfo.environment
guard let tokenFile = env["HUAHUO_BLE_PROXY_TOKEN_FILE"],
      let readyPath = env["HUAHUO_BLE_PROXY_READY_FILE"],
      let token = try? String(contentsOfFile: tokenFile, encoding: .utf8) else {
  fputs("Start this development app through tool/ble_proxy/run.py\n", stderr)
  exit(2)
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let host = try BleRelayHost(token: token.trimmingCharacters(in: .whitespacesAndNewlines), readyFile: URL(fileURLWithPath: readyPath))
application.run()
