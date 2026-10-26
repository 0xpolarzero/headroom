// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Headroom", targets: ["Headroom"]),
    ],
    targets: [
        .executableTarget(
            name: "Headroom",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "HeadroomTests", dependencies: ["Headroom"]),
    ]
)
