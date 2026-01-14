// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "afmbridge",
  platforms: [.macOS(.v26)], // macOS 26+ (Apple Intelligence)
  products: [
    .library(name: "afmbridge-core", targets: ["afmbridge-core"]),
    .executable(name: "afmbridge-server", targets: ["afmbridge-server"]),
    .executable(name: "afmbridge-socket", targets: ["afmbridge-socket"]),
    .executable(name: "afmbridge-cli", targets: ["afmbridge-cli"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0")
  ],
  targets: [
    .target(
      name: "afmbridge-core",
      dependencies: [],
      linkerSettings: [.linkedFramework("FoundationModels")]
    ),
    .executableTarget(
      name: "afmbridge-server",
      dependencies: [
        "afmbridge-core",
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio")
      ],
      linkerSettings: [.linkedFramework("FoundationModels")]
    ),
    .executableTarget(
      name: "afmbridge-socket",
      dependencies: ["afmbridge-core"],
      linkerSettings: [.linkedFramework("FoundationModels")]
    ),
    .executableTarget(
      name: "afmbridge-cli",
      dependencies: ["afmbridge-core"],
      linkerSettings: [.linkedFramework("FoundationModels")]
    )
  ]
)
