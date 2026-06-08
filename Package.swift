// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "SyncBrightness",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "CDDC"),
    .executableTarget(
      name: "SyncBrightness",
      dependencies: ["CDDC"],
      linkerSettings: [
        .linkedFramework("Cocoa"),
        .linkedFramework("IOKit"),
        .linkedFramework("Carbon"), // RegisterEventHotKey for custom global hotkeys
      ]
    ),
  ]
)
