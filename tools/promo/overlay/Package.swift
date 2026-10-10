// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PromoOverlay",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "fc-promo-overlay", targets: ["PromoOverlay"])],
  targets: [
    // Event decoding, easing, cell geometry, theme and key labels: no AppKit, unit tested.
    .target(name: "OverlayCore"),
    .executableTarget(name: "PromoOverlay", dependencies: ["OverlayCore"]),
    .testTarget(name: "OverlayCoreTests", dependencies: ["OverlayCore"]),
  ],
  swiftLanguageModes: [.v5]
)
