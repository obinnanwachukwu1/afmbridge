// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "syslm",
  platforms: [.macOS(.v26)], // macOS 26+ (Apple Intelligence)
  products: [
    .library(name: "syslm-core", targets: ["syslm-core"]),
    .executable(name: "syslm-server", targets: ["syslm-server"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0")
  ],
  targets: [
    .target(
      name: "syslm-core",
      dependencies: [],
      linkerSettings: [.linkedFramework("FoundationModels")]
    ),
    .executableTarget(
      name: "syslm-server",
      dependencies: [
        "syslm-core",
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio")
      ],
      linkerSettings: [.linkedFramework("FoundationModels")]
    )
  ]
)
