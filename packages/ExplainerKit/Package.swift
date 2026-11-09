// swift-tools-version: 6.0
import PackageDescription

// Standalone tutorial runtime and capture adapter. No FC engine, editor,
// terminal emulator, network dependency, or signing-team configuration.
let package = Package(
  name: "ExplainerKit",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "ExplainerKit", targets: ["ExplainerKit"]),
    .executable(name: "tutorial-capture", targets: ["TutorialCapture"]),
    .executable(name: "tutorial-example", targets: ["TutorialExample"]),
  ],
  targets: [
    .target(name: "ExplainerKit", resources: [.copy("MediaTools")]),
    .executableTarget(name: "TutorialCapture", dependencies: ["ExplainerKit"]),
    .executableTarget(name: "TutorialExample", dependencies: ["ExplainerKit"], resources: [.copy("Lessons")]),
    .testTarget(name: "ExplainerKitTests", dependencies: ["ExplainerKit"]),
  ],
  swiftLanguageModes: [.v5]
)
