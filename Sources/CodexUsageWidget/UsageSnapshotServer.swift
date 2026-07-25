import Foundation
import Network

struct WidgetLimitPayload: Codable, Equatable, Sendable {
  let usedPercent: Double
  let windowMinutes: Int
  let resetsAt: TimeInterval

  init(_ limit: LimitWindow) {
    usedPercent = limit.effectiveUsedPercent(at: Date())
    windowMinutes = limit.windowMinutes
    resetsAt = limit.resetsAt.timeIntervalSince1970
  }
}

struct WidgetUsagePayload: Codable, Equatable, Sendable {
  let generatedAt: TimeInterval
  let limits: [WidgetLimitPayload]
  let creditsBalance: String?

  init(_ snapshot: UsageSnapshot) {
    generatedAt = Date().timeIntervalSince1970
    limits = snapshot.limits.map(WidgetLimitPayload.init)
    creditsBalance = snapshot.creditsBalance
  }
}

final class UsageSnapshotServer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "local.codex.usage-widget.snapshot-server")
  private let lock = NSLock()
  private let encoder = JSONEncoder()
  private var listener: NWListener?
  private var payloadData: Data?

  func start() {
    guard listener == nil else {
      return
    }

    do {
      let port = try NWEndpoint.Port(rawValue: WidgetConfiguration.serverPort).unwrap()
      let listener = try NWListener(using: .tcp, on: port)
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
  }

  func update(_ snapshot: UsageSnapshot) {
    guard let data = try? encoder.encode(WidgetUsagePayload(snapshot)) else {
      return
    }

    lock.lock()
    payloadData = data
    lock.unlock()
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) {
      [weak self] _, _, _, _ in
      guard let self else {
        connection.cancel()
        return
      }

      let response = makeResponse()
      connection.send(
        content: response,
        contentContext: .finalMessage,
        isComplete: true,
        completion: .contentProcessed { error in
          if let error {
            NSLog("CodexUsageWidget snapshot send failed: \(error)")
          }
        }
      )
    }
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
