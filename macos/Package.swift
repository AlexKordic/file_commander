// swift-tools-version: 6.0
// The macOS app. CMake builds the C++ engine first (preset macos-app, which
// writes build-macos/libfc_engine_bundle.a); macos/build_app.sh then builds
// this package and assembles File Commander.app.
import PackageDescription

let engineLibraries = Context.packageDirectory + "/../build-macos"

let package = Package(
  name: "FileCommander",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "FileCommander", targets: ["FileCommander"]),
    .library(name: "ExplainerKit", targets: ["ExplainerKit"]),
  ],
  dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.2"),
    // The scene channel's protobuf runtime; FreshKit's types are generated
    // from Fresh's scene.proto (macos/tools/gen_scene_proto.sh).
    .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
  ],
  targets: [
    .systemLibrary(name: "CFCEngine", path: "Sources/CFCEngine"),
    .target(
      name: "FCKit",
      dependencies: ["CFCEngine"],
      swiftSettings: [.interoperabilityMode(.Cxx)],
      linkerSettings: [
        .unsafeFlags(["-L", engineLibraries]),
        .linkedFramework("CoreServices"),
      ]),
    // Annotation engine for explainers: no dependency on File Commander.
    .target(name: "ExplainerKit"),
    // Client of a Fresh session's scene channel: socket, scene model, key mapping.
    .target(name: "FreshKit", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
    .executableTarget(
      name: "FileCommander",
      dependencies: ["FCKit", "ExplainerKit", "FreshKit", .product(name: "SwiftTerm", package: "SwiftTerm")],
      resources: [.copy("Explainers"), .copy("Themes")],
      swiftSettings: [.interoperabilityMode(.Cxx)]),
    .executableTarget(name: "fc-relaunch"),
    .executableTarget(name: "fc-askpass"),
    .testTarget(name: "FCKitTests", dependencies: ["FCKit"], swiftSettings: [.interoperabilityMode(.Cxx)]),
    .testTarget(name: "ExplainerKitTests", dependencies: ["ExplainerKit"]),
    .testTarget(name: "FreshKitTests", dependencies: ["FreshKit"], resources: [.copy("Fixtures")]),
  ],
  swiftLanguageModes: [.v5],
  cxxLanguageStandard: .cxx20
)
