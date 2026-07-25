import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      switch SMAppService.mainApp.status {
      case .enabled, .requiresApproval:
        try SMAppService.mainApp.unregister()
      case .notRegistered, .notFound:
        break
      @unknown default:
        break
      }
    } catch {
      NSLog("CodexUsageWidget: 无法移除旧登录项：\(error.localizedDescription)")
    }

    NSApplication.shared.terminate(nil)
  }
}
