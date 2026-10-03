import CoreBluetooth
import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
  if !value() { fatalError(message) }
}
func rejects(_ message: String, _ action: () throws -> Void) {
  do { try action() } catch { return }
  fatalError(message)
}
final class Delegate: SimulatorBleCentralDelegate {
  func centralManagerDidUpdateState(_ central: SimulatorBleCentral) {}
  func centralManager(_ central: SimulatorBleCentral, didDiscover peripheral: SimulatorBlePeripheral, advertisementData: [String: Any], rssi: NSNumber) {}
  func centralManager(_ central: SimulatorBleCentral, didConnect peripheral: SimulatorBlePeripheral) {}
  func centralManager(_ central: SimulatorBleCentral, didFailToConnect peripheral: SimulatorBlePeripheral, error: Error?) {}
  func centralManager(_ central: SimulatorBleCentral, didDisconnectPeripheral peripheral: SimulatorBlePeripheral, error: Error?) {}
}

@main enum WireTests {
  static func main() throws {
    let packet: [String: Any] = ["v": 1, "event": "value", "data": Data([0, 255, 10]).base64EncodedString()]
    let encoded = try BleRelayFrames.encode(packet)
    for split in 1..<encoded.count {
      var frames = BleRelayFrames()
      let first = try frames.push(Data(encoded.prefix(split)))
      check(first.isEmpty, "fragment must wait")
      let result = try frames.push(Data(encoded.dropFirst(split)))
      check(result.count == 1 && result[0]["data"] as? String == packet["data"] as? String, "fragment bytes must survive")
    }
    var frames = BleRelayFrames()
    let coalesced = try frames.push(encoded + encoded + encoded)
    check(coalesced.count == 3, "coalesced notifications cannot be dropped")
    rejects("reject oversized length") { var f = BleRelayFrames(); _ = try f.push(Data([0, 32, 0, 0])) }
    rejects("reject empty frame") { var f = BleRelayFrames(); _ = try f.push(Data([0, 0, 0, 0])) }
    rejects("reject invalid JSON") { var f = BleRelayFrames(); _ = try f.push(Data([0, 0, 0, 1, 255])) }
    rejects("reject wrong version") { _ = try BleRelayFrames.encode(["v": 2]) }
    let token = String(repeating: "a", count: 64)
    rejects("no command before auth") {
      var gate = BleRelaySessionGate(token: token)
      try gate.accept(["v": 1, "seq": 1, "op": "write"])
    }
    rejects("wrong token") {
      var gate = BleRelaySessionGate(token: token)
      try gate.accept(["v": 1, "seq": 1, "op": "hello", "token": "wrong"])
    }
    var gate = BleRelaySessionGate(token: token)
    try gate.accept(["v": 1, "seq": 1, "op": "hello", "token": token])
    try gate.accept(["v": 1, "seq": 2, "op": "write"])
    rejects("never replay a write") { try gate.accept(["v": 1, "seq": 2, "op": "write"]) }
    rejects("reject sequence gap") { try gate.accept(["v": 1, "seq": 4, "op": "write"]) }
    rejects("reject repeated hello") { try gate.accept(["v": 1, "seq": 3, "op": "hello", "token": token]) }

    unsetenv("HUAHUO_BLE_PROXY_PORT"); unsetenv("HUAHUO_BLE_PROXY_TOKEN")
    let delegate = Delegate()
    let central = SimulatorBleCentral(delegate: delegate, queue: .main, options: nil)
    check(central.state == .unsupported, "relay must be opt-in")
    let peripheral = SimulatorBlePeripheral(identifier: UUID(), central: central)
    peripheral.state = .connected; peripheral.hostReady = true
    check(peripheral.canSendWriteWithoutResponse, "ready after connection")
    peripheral.outstandingWrite = 2
    check(!peripheral.canSendWriteWithoutResponse, "host ready cannot override in-flight write")
    peripheral.outstandingWrite = nil; peripheral.hostReady = false
    check(!peripheral.canSendWriteWithoutResponse, "backpressure must block writes")
    peripheral.state = .disconnected; peripheral.hostReady = true
    check(!peripheral.canSendWriteWithoutResponse, "disconnected cannot write")
    print("PASS: fragmented/coalesced frames, corruption/size/version, auth/replay, opt-in and write flow")
  }
}
