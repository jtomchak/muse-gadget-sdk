// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MusePocketCore", platforms: [.iOS(.v18), .macOS(.v15)],
  products: [.library(name: "MusePocketCore", targets: ["MusePocketCore"])],
  targets: [
    .target(name: "MusePocketCore"),
    .testTarget(name: "MusePocketCoreTests", dependencies: ["MusePocketCore"]),
  ])
