import AppKit

@main
enum CodexUsageWidgetMain {
  static func main() {
    let application = NSApplication.shared
    let appDelegate = MainActor.assumeIsolated {
      AppDelegate()
    }

    application.delegate = appDelegate
    application.setActivationPolicy(.accessory)
    application.run()
  }
}
