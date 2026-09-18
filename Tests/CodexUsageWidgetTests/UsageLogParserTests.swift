import Foundation
import Testing

@testable import CodexUsageWidget

struct UsageLogParserTests {
  @Test
  func parsesPrimaryAndSecondaryWindows() throws {
    let json = """
      {"timestamp":"2026-07-25T13:34:26.121Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":16.0,"window_minutes":300,"resets_at":1785281297},"secondary":{"used_percent":35.0,"window_minutes":10080,"resets_at":1785281297},"credits":{"has_credits":true,"balance":"12.5"},"plan_type":"pro"}}}
      """

    let snapshot = UsageLogParser.parseSnapshot(
      try #require(json.data(using: .utf8)),
      sourcePath: "/tmp/sample.jsonl"
    )

    let value = try #require(snapshot)
    #expect(value.primary?.remainingPercent == 84)
    #expect(value.secondary?.remainingPercent == 65)
    #expect(value.creditsBalance == "12.5")
    #expect(value.hasCredits == true)
    #expect(value.limits.map(\.windowMinutes) == [300, 10_080])
    #expect(value.mostConstrainedLimit?.remainingPercent == 65)
  }

  @Test
  func picksLatestValidRecordFromTail() throws {
    let old = """
      {"timestamp":"2026-07-25T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10,"window_minutes":10080,"resets_at":1785281297}}}}
      """
    let unrelated = """
      {"timestamp":"2026-07-25T12:01:00.000Z","type":"event_msg","payload":{"type":"other"}}
      """
    let newest = """
      {"timestamp":"2026-07-25T13:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":22,"window_minutes":10080,"resets_at":1785281297}}}}
      """
    let data = try #require([old, unrelated, newest].joined(separator: "\n").data(using: .utf8))

    let snapshot = UsageLogParser.latestSnapshot(in: data, sourcePath: "/tmp/tail.jsonl")

    #expect(snapshot?.primary?.usedPercent == 22)
  }

  @Test
  func clampsRemainingPercentage() {
    let future = Date().addingTimeInterval(3_600)
    let overused = LimitWindow(
      usedPercent: 120,
      windowMinutes: 300,
      resetsAt: future
    )
    let negative = LimitWindow(
      usedPercent: -5,
      windowMinutes: 300,
      resetsAt: future
    )

    #expect(overused.remainingPercent == 0)
    #expect(negative.remainingPercent == 100)
  }

  @Test
  func doesNotInventAResetForExpiredData() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let limit = LimitWindow(
      usedPercent: 87,
      windowMinutes: 300,
      resetsAt: now.addingTimeInterval(-60)
    )

    #expect(limit.remainingPercent == 13)
    #expect(!limit.isCurrent(at: now))
  }

  @Test
  func rejectsOldOrExpiredSnapshots() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let limit = LimitWindow(
      usedPercent: 45,
      windowMinutes: 10_080,
      resetsAt: now.addingTimeInterval(3_600)
    )
    let fresh = UsageSnapshot(
      timestamp: now.addingTimeInterval(-60),
      primary: limit,
      secondary: nil,
      creditsBalance: nil,
      hasCredits: nil,
      planType: nil,
      sourcePath: "/tmp/sample.jsonl"
    )

    #expect(fresh.isFresh(at: now))
    #expect(!fresh.isFresh(at: now.addingTimeInterval(UsageSnapshot.maximumAge)))
    #expect(!fresh.isFresh(at: now.addingTimeInterval(3_600)))

    let payload = WidgetUsagePayload(fresh)
    #expect(payload.sourceAt == fresh.timestamp.timeIntervalSince1970)
    #expect(payload.limits.first?.usedPercent == 45)
  }
}
