// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "syslm-cli",
  platforms: [.macOS(.v26)], // macOS 15+ (Apple Intelligence)
  products: [
    .library(name: "syslm-core", targets: ["syslm-core"]),
    .executable(name: "syslm-cli", targets: ["syslm-cli"]),
    .executable(name: "syslm-server", targets: ["syslm-server"]),
    .executable(name: "syslm-dbh", targets: ["syslm-dbh"])
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
      name: "syslm-cli",
      dependencies: ["syslm-core"],
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
    ),
    .executableTarget(
      name: "syslm-dbh",
      dependencies: ["syslm-core"],
      linkerSettings: [.linkedFramework("FoundationModels")]
    )
  ]
)
