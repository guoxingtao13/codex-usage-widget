// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "CodexUsageWidget",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(
      name: "CodexUsageWidget",
      targets: ["CodexUsageWidget"]
    )
  ],
  targets: [
    .executableTarget(
      name: "CodexUsageWidget"
    ),
    .testTarget(
      name: "CodexUsageWidgetTests",
      dependencies: ["CodexUsageWidget"]
    ),
  ]
)
