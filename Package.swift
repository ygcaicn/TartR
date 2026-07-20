// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TartR",
  defaultLocalization: "zh-Hans",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "TartRCore", targets: ["TartRCore"]),
    .executable(name: "TartR", targets: ["TartR"]),
  ],
  targets: [
    .target(name: "TartRCore"),
    .executableTarget(name: "TartR", dependencies: ["TartRCore"]),
    .testTarget(name: "TartRCoreTests", dependencies: ["TartRCore"]),
  ],
  swiftLanguageModes: [.v5]
)
