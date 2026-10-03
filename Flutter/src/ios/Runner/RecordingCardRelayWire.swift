#if os(macOS) || (DEBUG && targetEnvironment(simulator))
import Foundation
import Network

enum BleRelayError: Error { case invalidFrame, authentication, replay, overflow }

struct BleRelayFrames {
  static let limit = 1_048_576
  private var buffer = Data()

  static func encode(_ object: [String: Any]) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object), object["v"] as? Int == 1 else {
      throw BleRelayError.invalidFrame
    }
    let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard !body.isEmpty, body.count <= limit else { throw BleRelayError.overflow }
    let size = UInt32(body.count)
    return Data([UInt8(size >> 24), UInt8((size >> 16) & 255),
                 UInt8((size >> 8) & 255), UInt8(size & 255)]) + body
  }

  mutating func push(_ bytes: Data) throws -> [[String: Any]] {
    buffer.append(bytes)
    var result: [[String: Any]] = []
    while buffer.count >= 4 {
      let prefix = Array(buffer.prefix(4))
      let size = prefix.reduce(0) { ($0 << 8) | Int($1) }
      guard size > 0, size <= Self.limit else { throw BleRelayError.overflow }
      guard buffer.count >= size + 4 else { break }
      let body = Data(buffer.dropFirst(4).prefix(size))
      buffer.removeFirst(size + 4)
      guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            object["v"] as? Int == 1 else { throw BleRelayError.invalidFrame }
      result.append(object)
    }
    guard buffer.count <= Self.limit + 4 else { throw BleRelayError.overflow }
    return result
  }
}

struct BleRelaySessionGate {
  let token: String
  private(set) var authenticated = false
  private(set) var lastSequence = 0

  mutating func accept(_ message: [String: Any]) throws {
    guard message["v"] as? Int == 1,
          let sequence = message["seq"] as? Int, sequence == lastSequence + 1,
          let operation = message["op"] as? String else { throw BleRelayError.replay }
    if !authenticated {
      guard operation == "hello", token.count >= 32,
            message["token"] as? String == token else { throw BleRelayError.authentication }
      authenticated = true
    } else if operation == "hello" {
      throw BleRelayError.replay
    }
    lastSequence = sequence
  }
}

// Both ends use one ordered stream; no retries or data dropping in this layer.
final class BleRelaySocket {
  let connection: NWConnection
  var onMessage: (([String: Any]) -> Void)?
  var onClose: (() -> Void)?
  var onReady: (() -> Void)?
  private var frames = BleRelayFrames()
  private var pendingBytes = 0
  private var closed = false

  init(_ connection: NWConnection) { self.connection = connection }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      guard let self, !self.closed else { return }
      switch state {
      case .ready: self.onReady?()
      case .failed, .cancelled: self.close()
      default: break
      }
    }
    connection.start(queue: .main)
    receive()
  }

  func send(_ message: [String: Any]) {
    guard !closed else { return }
    do {
      let data = try BleRelayFrames.encode(message)
      guard pendingBytes + data.count <= 4 * BleRelayFrames.limit else {
        throw BleRelayError.overflow
      }
      pendingBytes += data.count
      connection.send(content: data, completion: .contentProcessed { [weak self] error in
        guard let self else { return }
        self.pendingBytes -= data.count
        if error != nil { self.close() }
      })
    } catch { close() }
  }

  func close() {
    guard !closed else { return }
    closed = true
    connection.cancel()
    onClose?()
    onMessage = nil
    onReady = nil
    onClose = nil
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] data, _, complete, error in
      guard let self, !self.closed else { return }
      do {
        if let data {
          for message in try self.frames.push(data) {
            guard !self.closed else { return }
            self.onMessage?(message)
          }
        }
      } catch { self.close(); return }
      if complete || error != nil { self.close() } else { self.receive() }
    }
  }
}
#endif
