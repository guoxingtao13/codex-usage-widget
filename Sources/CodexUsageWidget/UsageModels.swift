import Foundation

struct LimitWindow: Equatable, Sendable {
  let usedPercent: Double
  let windowMinutes: Int
  let resetsAt: Date

  var remainingPercent: Double {
    remainingPercent(at: Date())
  }

  func remainingPercent(at date: Date) -> Double {
    if resetsAt <= date {
      return 100
    }
    return max(0, min(100, 100 - usedPercent))
  }

  func effectiveUsedPercent(at date: Date) -> Double {
    100 - remainingPercent(at: date)
  }

  var displayName: String {
    switch windowMinutes {
    case 300:
      return "5 小时额度"
    case 1_440:
      return "每日额度"
    case 10_080:
      return "7 天额度"
    default:
      if windowMinutes.isMultiple(of: 1_440) {
        return "\(windowMinutes / 1_440) 天额度"
      }
      if windowMinutes.isMultiple(of: 60) {
        return "\(windowMinutes / 60) 小时额度"
      }
      return "\(windowMinutes) 分钟额度"
    }
  }
}

struct UsageSnapshot: Equatable, Sendable {
  let timestamp: Date
  let primary: LimitWindow?
  let secondary: LimitWindow?
  let creditsBalance: String?
  let hasCredits: Bool?
  let planType: String?
  let sourcePath: String

  var limits: [LimitWindow] {
    [primary, secondary]
      .compactMap { $0 }
      .sorted { $0.windowMinutes < $1.windowMinutes }
  }

  var mostConstrainedLimit: LimitWindow? {
    limits.min { $0.remainingPercent < $1.remainingPercent }
  }
}

enum UsageLogParser {
  static func latestSnapshot(in data: Data, sourcePath: String) -> UsageSnapshot? {
    guard let text = String(data: data, encoding: .utf8) else {
      return nil
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
      guard line.contains("\"rate_limits\""),
        line.contains("\"token_count\""),
        let lineData = line.data(using: .utf8),
        let snapshot = parseSnapshot(lineData, sourcePath: sourcePath)
      else {
        continue
      }
      return snapshot
    }

    return nil
  }

  static func parseSnapshot(_ data: Data, sourcePath: String) -> UsageSnapshot? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      root["type"] as? String == "event_msg",
      let payload = root["payload"] as? [String: Any],
      payload["type"] as? String == "token_count",
      let rateLimits = payload["rate_limits"] as? [String: Any],
      let timestampText = root["timestamp"] as? String,
      let timestamp = parseTimestamp(timestampText)
    else {
      return nil
    }

    let credits = rateLimits["credits"] as? [String: Any]

    return UsageSnapshot(
      timestamp: timestamp,
      primary: parseLimit(rateLimits["primary"]),
      secondary: parseLimit(rateLimits["secondary"]),
      creditsBalance: stringValue(credits?["balance"]),
      hasCredits: credits?["has_credits"] as? Bool,
      planType: rateLimits["plan_type"] as? String,
      sourcePath: sourcePath
    )
  }

  private static func parseLimit(_ value: Any?) -> LimitWindow? {
    guard let dictionary = value as? [String: Any],
      let usedPercent = numberValue(dictionary["used_percent"]),
      let windowMinutes = numberValue(dictionary["window_minutes"]),
      let resetsAt = numberValue(dictionary["resets_at"])
    else {
      return nil
    }

    return LimitWindow(
      usedPercent: usedPercent,
      windowMinutes: Int(windowMinutes),
      resetsAt: Date(timeIntervalSince1970: resetsAt)
    )
  }

  private static func numberValue(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
      return number.doubleValue
    }
    if let string = value as? String {
      return Double(string)
    }
    return nil
  }

  private static func stringValue(_ value: Any?) -> String? {
    switch value {
    case let value as String:
      return value
    case let value as NSNumber:
      return value.stringValue
    default:
      return nil
    }
  }

  private static func parseTimestamp(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
      return date
    }

    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}
