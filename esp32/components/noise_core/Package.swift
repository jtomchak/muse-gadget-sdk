// swift-tools-version: 6.0
import PackageDescription

// Compile the same transport sources used by firmware; upstream protocol fixes
// therefore reach both platforms without a second Noise implementation.
let package = Package(
  name: "MuseNoiseNative", platforms: [.iOS(.v18), .macOS(.v15)],
  products: [.library(name: "MuseNoiseNative", targets: ["MuseNoiseNative"])],
  targets: [.target(name: "MuseNoiseNative", path: ".", exclude: ["CMakeLists.txt", "src/PsaCryptoBackend.cpp", "src/MbedtlsCryptoBackend.cpp", "include"], sources: [
    "src/Status.cpp", "src/InitiatorHandshake.cpp", "src/Transport.cpp",
    "src/TransportFrameCodec.cpp", "src/ServiceCodec.cpp", "src/ClientSession.cpp",
    "apple/Bridge.cpp",
  ], publicHeadersPath: "apple/include", cxxSettings: [.headerSearchPath("include")])],
  cxxLanguageStandard: .cxx17
)
