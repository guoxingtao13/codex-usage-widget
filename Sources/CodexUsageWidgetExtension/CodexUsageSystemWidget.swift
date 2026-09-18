import Foundation
import SwiftUI
import WidgetKit

private enum WidgetConstants {
  static let kind = "CodexUsageSystemWidget"
  static let endpoint = URL(string: "http://127.0.0.1:49671/snapshot")!
  static let accent = Color(red: 0.24, green: 0.92, blue: 0.34)
  static let maximumSnapshotAge: TimeInterval = 15 * 60
  static let timelineRefreshInterval: TimeInterval = 5 * 60
}

private struct WidgetLimit: Codable, Equatable {
  let usedPercent: Double
  let windowMinutes: Int
  let resetsAt: TimeInterval

  var remainingPercent: Double {
    return max(0, min(100, 100 - usedPercent))
  }

  var title: String {
    switch windowMinutes {
    case 300:
      return "5 小时额度"
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

private struct WidgetPayload: Codable, Equatable {
  let generatedAt: TimeInterval
  let sourceAt: TimeInterval
  let limits: [WidgetLimit]
  let creditsBalance: String?

  var validUntil: Date {
    let sourceExpiry = sourceAt + WidgetConstants.maximumSnapshotAge
    let firstReset = limits.map(\.resetsAt).min() ?? sourceExpiry
    return Date(timeIntervalSince1970: min(sourceExpiry, firstReset))
  }

  func isFresh(at date: Date) -> Bool {
    !limits.isEmpty
      && sourceAt <= date.addingTimeInterval(60).timeIntervalSince1970
      && date < validUntil
  }

  var sortedLimits: [WidgetLimit] {
    limits.sorted { $0.windowMinutes < $1.windowMinutes }
  }

  var headline: WidgetLimit? {
    limits.min { $0.remainingPercent < $1.remainingPercent }
  }
}

private struct UsageEntry: TimelineEntry {
  let date: Date
  let payload: WidgetPayload?
  let isStale: Bool
}

private struct UsageProvider: TimelineProvider {
  func placeholder(in context: Context) -> UsageEntry {
    UsageEntry(
      date: Date(),
      payload: WidgetPayload(
        generatedAt: Date().timeIntervalSince1970,
        sourceAt: Date().timeIntervalSince1970,
        limits: [
          WidgetLimit(
            usedPercent: 24,
            windowMinutes: 10_080,
            resetsAt: Date().addingTimeInterval(3 * 86_400).timeIntervalSince1970
          )
        ],
        creditsBalance: nil
      ),
      isStale: false
    )
  }

  func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
    if context.isPreview {
      completion(placeholder(in: context))
      return
    }
    fetchEntry(completion: completion)
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
    fetchEntry { entry in
      let nextRefresh = entry.date.addingTimeInterval(WidgetConstants.timelineRefreshInterval)
      var entries = [entry]
      if let payload = entry.payload, !entry.isStale {
        entries.append(
          UsageEntry(date: payload.validUntil, payload: payload, isStale: true)
        )
      }
      completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }
  }

  private func fetchEntry(completion: @escaping (UsageEntry) -> Void) {
    var request = URLRequest(
      url: WidgetConstants.endpoint,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: 2
    )
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    URLSession.shared.dataTask(with: request) { data, response, _ in
      let statusCode = (response as? HTTPURLResponse)?.statusCode
      let payload: WidgetPayload?
      if statusCode == 200, let data {
        payload = try? JSONDecoder().decode(WidgetPayload.self, from: data)
      } else {
        payload = nil
      }
      let now = Date()
      completion(
        UsageEntry(
          date: now,
          payload: payload,
          isStale: payload.map { !$0.isFresh(at: now) } ?? false
        )
      )
    }.resume()
  }
}

struct CodexUsageSystemWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WidgetConstants.kind, provider: UsageProvider()) { entry in
      CodexUsageWidgetView(entry: entry)
        .containerBackground(for: .widget) {
          Color.black.opacity(0.68)
        }
    }
    .configurationDisplayName("Codex 用量")
    .description("查看 Codex 当前已用、剩余额度和重置时间。")
    .supportedFamilies([.systemSmall, .systemMedium])
    .containerBackgroundRemovable(false)
    .contentMarginsDisabled()
  }
}

private struct CodexUsageWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: UsageEntry

  var body: some View {
    Group {
      if let payload = entry.payload, entry.isStale {
        WaitingView(
          title: "数据已过期",
          detail: "最后更新 \(updatedTime(payload.sourceAt))"
        )
      } else if let payload = entry.payload, let headline = payload.headline {
        switch family {
        case .systemMedium:
          MediumUsageView(payload: payload, headline: headline, entryDate: entry.date)
        default:
          SmallUsageView(
            headline: headline,
            entryDate: entry.date,
            sourceAt: payload.sourceAt
          )
        }
      } else {
        WaitingView(title: "数据暂不可用", detail: "可能已过期，等待后台更新")
      }
    }
    .padding(family == .systemMedium ? 16 : 14)
    .foregroundStyle(.white)
    .shadow(color: .black.opacity(0.28), radius: 1, y: 1)
  }
}

private struct SmallUsageView: View {
  let headline: WidgetLimit
  let entryDate: Date
  let sourceAt: TimeInterval

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      WidgetHeader()

      HStack(spacing: 10) {
        UsageRing(remaining: headline.remainingPercent, size: 64)

        VStack(alignment: .leading, spacing: 4) {
          Text(headline.title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .lineLimit(1)
          Text("已用 \(Int(headline.usedPercent.rounded()))%")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
          Text(resetText(for: headline, now: entryDate))
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.86))
            .lineLimit(2)
            .minimumScaleFactor(0.78)
        }
      }
      .frame(maxHeight: .infinity)

      Text("更新于 \(updatedTime(sourceAt))")
        .font(.system(size: 9, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.72))
    }
  }
}

private struct MediumUsageView: View {
  let payload: WidgetPayload
  let headline: WidgetLimit
  let entryDate: Date

  var body: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 8) {
        WidgetHeader()
        UsageRing(remaining: headline.remainingPercent, size: 88)
      }
      .frame(width: 110, alignment: .leading)

      VStack(alignment: .leading, spacing: 12) {
        ForEach(Array(payload.sortedLimits.prefix(2).enumerated()), id: \.offset) { _, limit in
          LimitBar(limit: limit, now: entryDate)
        }

        if payload.sortedLimits.count == 1 {
          Text(resetText(for: headline, now: entryDate))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.72))
        }

        if let credits = payload.creditsBalance, credits != "0" {
          Label("Credits \(credits)", systemImage: "sparkles")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.76))
        }

        Text("更新于 \(updatedTime(payload.sourceAt))")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.72))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct WidgetHeader: View {
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "chevron.left.forwardslash.chevron.right")
        .font(.system(size: 11, weight: .bold))
      Text("CODEX")
        .font(.system(size: 12, weight: .heavy, design: .rounded))
        .tracking(1.3)
      Spacer(minLength: 0)
    }
    .foregroundStyle(WidgetConstants.accent)
    .overlay(alignment: .trailing) {
      Circle()
        .fill(WidgetConstants.accent)
        .frame(width: 6, height: 6)
    }
  }
}

private struct UsageRing: View {
  let remaining: Double
  let size: CGFloat

  var body: some View {
    ZStack {
      Circle()
        .stroke(.white.opacity(0.18), lineWidth: size > 70 ? 9 : 7)
      Circle()
        .trim(from: 0, to: max(0.004, min(1, remaining / 100)))
        .stroke(
          WidgetConstants.accent,
          style: StrokeStyle(lineWidth: size > 70 ? 9 : 7, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))

      VStack(spacing: -2) {
        Text("\(Int(remaining.rounded()))%")
          .font(
            .system(
              size: size > 70 ? 25 : 19,
              weight: .heavy,
              design: .rounded
            )
          )
          .monospacedDigit()
        Text("剩余")
          .font(.system(size: 9, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.72))
      }
    }
    .frame(width: size, height: size)
  }
}

private struct LimitBar: View {
  let limit: WidgetLimit
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(limit.title)
          .font(.system(size: 12, weight: .bold, design: .rounded))
        Spacer()
        Text("已用 \(Int(limit.usedPercent.rounded()))%")
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .foregroundStyle(.white.opacity(0.9))
      }

      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(.white.opacity(0.17))
          Capsule()
            .fill(WidgetConstants.accent)
            .frame(width: proxy.size.width * max(0, min(1, limit.remainingPercent / 100)))
        }
      }
      .frame(height: 6)

      Text(resetText(for: limit, now: now))
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.84))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
  }
}

private struct WaitingView: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      WidgetHeader()
      Spacer()
      Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: 26, weight: .medium))
        .foregroundStyle(WidgetConstants.accent)
      Text(title)
        .font(.system(size: 14, weight: .bold, design: .rounded))
      Text(detail)
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.7))
      Spacer()
    }
  }
}

private func updatedTime(_ timestamp: TimeInterval) -> String {
  let date = Date(timeIntervalSince1970: timestamp)
  if Calendar.current.isDateInToday(date) {
    return date.formatted(date: .omitted, time: .shortened)
  }
  return date.formatted(date: .abbreviated, time: .shortened)
}

private func resetText(for limit: WidgetLimit, now: Date) -> String {
  let interval = max(0, limit.resetsAt - now.timeIntervalSince1970)
  if interval == 0 {
    return "额度已经重置"
  }
  let days = Int(interval) / 86_400
  let hours = (Int(interval) % 86_400) / 3_600
  let minutes = (Int(interval) % 3_600) / 60

  if days > 0 {
    return "\(days) 天 \(hours) 小时后重置"
  }
  if hours > 0 {
    return "\(hours) 小时 \(minutes) 分后重置"
  }
  return "\(max(1, minutes)) 分钟后重置"
}
