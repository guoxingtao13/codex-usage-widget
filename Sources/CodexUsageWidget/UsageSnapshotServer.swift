import Foundation
import Network

struct WidgetLimitPayload: Codable, Equatable, Sendable {
  let usedPercent: Double
  let windowMinutes: Int
  let resetsAt: TimeInterval

  init(_ limit: LimitWindow) {
    usedPercent = max(0, min(100, limit.usedPercent))
    windowMinutes = limit.windowMinutes
    resetsAt = limit.resetsAt.timeIntervalSince1970
  }
}

struct WidgetUsagePayload: Codable, Equatable, Sendable {
  let generatedAt: TimeInterval
  let sourceAt: TimeInterval
  let limits: [WidgetLimitPayload]
  let creditsBalance: String?

  init(_ snapshot: UsageSnapshot) {
    generatedAt = Date().timeIntervalSince1970
    sourceAt = snapshot.timestamp.timeIntervalSince1970
    limits = snapshot.limits.map(WidgetLimitPayload.init)
    creditsBalance = snapshot.creditsBalance
  }
}

final class UsageSnapshotServer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "local.codex.usage-widget.snapshot-server")
  private let lock = NSLock()
  private let encoder = JSONEncoder()
  private let maximumConcurrentConnections = 16
  private let requestTimeout: DispatchTimeInterval = .seconds(5)
  private var listener: NWListener?
  private var payloadData: Data?
  private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

  func start() {
    guard listener == nil else {
      return
    }

    do {
      let port = try NWEndpoint.Port(rawValue: WidgetConfiguration.serverPort).unwrap()
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(
        host: NWEndpoint.Host("127.0.0.1"),
        port: port
      )
      let listener = try NWListener(using: parameters)
      listener.newConnectionHandler = { [weak self] connection in
        self?.handle(connection)
      }
      listener.stateUpdateHandler = { state in
        if case .failed(let error) = state {
          NSLog("CodexUsageWidget snapshot server failed: \(error)")
        }
      }
      listener.start(queue: queue)
      self.listener = listener
    } catch {
      NSLog("CodexUsageWidget snapshot server could not start: \(error)")
    }
  }

  func stop() {
    listener?.cancel()
    listener = nil
    queue.async { [weak self] in
      guard let self else {
        return
      }
      for identifier in Array(activeConnections.keys) {
        finishConnection(identifier)
      }
    }
  }

  func update(_ snapshot: UsageSnapshot) {
    guard let data = try? encoder.encode(WidgetUsagePayload(snapshot)) else {
      return
    }

    lock.lock()
    payloadData = data
    lock.unlock()
  }

  func clear() {
    lock.lock()
    payloadData = nil
    lock.unlock()
  }

  private func handle(_ connection: NWConnection) {
    guard activeConnections.count < maximumConcurrentConnections else {
      connection.cancel()
      return
    }

    let identifier = ObjectIdentifier(connection)
    activeConnections[identifier] = connection
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled:
        self?.finishConnection(identifier)
      default:
        break
      }
    }
    connection.start(queue: queue)

    queue.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
      self?.finishConnection(identifier)
    }

    connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) {
      [weak self] data, _, _, error in
      guard let self else {
        return
      }

      guard error == nil, data?.isEmpty == false else {
        finishConnection(identifier)
        return
      }

      let response = makeResponse()
      connection.send(
        content: response,
        contentContext: .finalMessage,
        isComplete: true,
        completion: .contentProcessed { [weak self] error in
          if let error {
            NSLog("CodexUsageWidget snapshot send failed: \(error)")
          }
          self?.finishConnection(identifier)
        }
      )
    }
  }

  private func finishConnection(_ identifier: ObjectIdentifier) {
    guard let connection = activeConnections.removeValue(forKey: identifier) else {
      return
    }
    connection.stateUpdateHandler = nil
    connection.cancel()
  }

  private func makeResponse() -> Data {
    lock.lock()
    let body = payloadData
    lock.unlock()

    guard let body else {
      let header = [
        "HTTP/1.1 503 Service Unavailable",
        "Content-Type: application/json",
        "Content-Length: 0",
        "Connection: close",
        "",
        "",
      ].joined(separator: "\r\n")
      return Data(header.utf8)
    }

    let header = [
      "HTTP/1.1 200 OK",
      "Content-Type: application/json",
      "Cache-Control: no-store",
      "Content-Length: \(body.count)",
      "Connection: close",
      "",
      "",
    ].joined(separator: "\r\n")

    guard let bodyText = String(data: body, encoding: .utf8) else {
      return Data()
    }
    return Data((header + bodyText).utf8)
  }
}

extension Optional {
  fileprivate func unwrap(
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> Wrapped {
    guard let self else {
      throw UnwrapError.nilValue(file: file, line: line)
    }
    return self
  }
}

private enum UnwrapError: Error {
  case nilValue(file: StaticString, line: UInt)
}
