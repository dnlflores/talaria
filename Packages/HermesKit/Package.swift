// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "HermesKit",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "HermesKit", targets: ["HermesKit"]),
    .library(name: "MarkdownBlocks", targets: ["MarkdownBlocks"]),
  ],
  targets: [
    .target(name: "HermesKit", dependencies: ["MarkdownBlocks"]),
    .target(name: "MarkdownBlocks"),
    .testTarget(name: "HermesKitTests", dependencies: ["HermesKit"]),
    .testTarget(name: "MarkdownBlocksTests", dependencies: ["MarkdownBlocks"]),
  ],
  swiftLanguageModes: [.v6]
)
