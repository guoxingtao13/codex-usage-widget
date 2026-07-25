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
  private let snapshotServer = UsageSnapshotServer()
  private var monitor: CodexUsageMonitor?
  private var lastSnapshot: UsageSnapshot?

  func start() {
    snapshotServer.start()
    monitor = CodexUsageMonitor { [weak self] snapshot in
      guard let self, let snapshot else {
        return
      }
      guard snapshot != lastSnapshot else {
        return
      }
      lastSnapshot = snapshot
      snapshotServer.update(snapshot)
      WidgetCenter.shared.reloadTimelines(ofKind: WidgetConfiguration.kind)
    }
    monitor?.start()
  }
}
