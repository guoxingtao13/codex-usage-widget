import Foundation
import WidgetKit

@main
enum CodexUsageAgentMain {
  static func main() {
    let runtime = MainActor.assumeIsolated {
      CodexUsageAgentRuntime()
    }
    MainActor.assumeIsolated {
      runtime.start()
    }

    withExtendedLifetime(runtime) {
      RunLoop.main.run()
    }
  }
}

@MainActor
private final class CodexUsageAgentRuntime {
  private let minimumWidgetReloadInterval: TimeInterval = 60
  private let snapshotServer = UsageSnapshotServer()
  private var monitor: CodexUsageMonitor?
  private var lastSnapshot: UsageSnapshot?
  private var lastWidgetReloadAt: Date?
  private var hasScheduledReload = false

  func start() {
    snapshotServer.start()
    monitor = CodexUsageMonitor { [weak self] snapshot in
      guard let self, snapshot != lastSnapshot else {
        return
      }
      lastSnapshot = snapshot
      if let snapshot {
        snapshotServer.update(snapshot)
      } else {
        snapshotServer.clear()
      }
      requestWidgetReload()
    }
    monitor?.start()
  }

  private func requestWidgetReload() {
    let now = Date()
    let remaining = max(
      0,
      minimumWidgetReloadInterval - now.timeIntervalSince(lastWidgetReloadAt ?? .distantPast)
    )

    guard remaining > 0 else {
      lastWidgetReloadAt = now
      WidgetCenter.shared.reloadTimelines(ofKind: WidgetConfiguration.kind)
      return
    }

    guard !hasScheduledReload else {
      return
    }
    hasScheduledReload = true
    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
      guard let self else {
        return
      }
      hasScheduledReload = false
      requestWidgetReload()
    }
  }
}
