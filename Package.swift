// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Featureflip",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "Featureflip", targets: ["Featureflip"]),
    ],
    targets: [
        .target(name: "Featureflip"),
        .testTarget(name: "FeatureflipTests", dependencies: ["Featureflip"]),
    ]
)
