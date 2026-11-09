// swift-tools-version: 6.0
// The macOS app. CMake builds the C++ engine first (preset macos-app, which
// writes build-macos/libfc_engine_bundle.a); macos/build_app.sh then builds
// this package and assembles File Commander.app.
import PackageDescription
import Foundation

// CTest links the engine from the build it is qualifying, rather than a
// potentially stale archive in the interactive app's default build directory.
let engineLibraries = ProcessInfo.processInfo.environment["FC_ENGINE_LIBRARY_DIR"]
  ?? Context.packageDirectory + "/../build-macos"
let explainerKit: Target.Dependency = .product(name: "ExplainerKit", package: "ExplainerKit")

let package = Package(
  name: "FileCommander",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "FileCommander", targets: ["FileCommander"]),
  ],
  dependencies: [
    .package(path: "../packages/ExplainerKit"),
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
    // Client of a Fresh session's scene channel: socket, scene model, key mapping.
    .target(name: "FreshKit", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
    .executableTarget(
      name: "FileCommander",
      dependencies: ["FCKit", explainerKit, "FreshKit", .product(name: "SwiftTerm", package: "SwiftTerm")],
      resources: [.copy("Explainers"), .copy("Themes")],
      swiftSettings: [.interoperabilityMode(.Cxx)]),
    .executableTarget(name: "fc-relaunch"),
    .executableTarget(name: "fc-askpass"),
    // Explicit development resource profile; not included in the app bundle.
    .executableTarget(name: "fc-compose-profile", dependencies: ["FreshKit"]),
    .testTarget(name: "FCKitTests", dependencies: ["FCKit"], swiftSettings: [.interoperabilityMode(.Cxx)]),
    .testTarget(name: "ExplainerKitTests", dependencies: [explainerKit]),
    .testTarget(name: "FreshKitTests", dependencies: ["FreshKit"], resources: [.copy("Fixtures")]),
    .testTarget(name: "NativeEditorTests", dependencies: ["FileCommander", "FreshKit"], swiftSettings: [.interoperabilityMode(.Cxx)]),
  ],
  swiftLanguageModes: [.v5],
  cxxLanguageStandard: .cxx20
)
