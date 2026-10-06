// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MusePocketCore", platforms: [.iOS(.v18), .macOS(.v15)],
  products: [.library(name: "MusePocketCore", targets: ["MusePocketCore"])],
  dependencies: [.package(path: "../../esp32/components/noise_core")],
  targets: [
    .target(name: "MusePocketCore", dependencies: [.product(name: "MuseNoiseNative", package: "noise_core")]),
    .testTarget(name: "MusePocketCoreTests", dependencies: ["MusePocketCore"]),
  ])
