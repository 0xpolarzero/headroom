// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lastdrop",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "lastdrop", targets: ["LastDrop"]),
    ],
    targets: [
        .executableTarget(
            name: "LastDrop",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "LastDropTests", dependencies: ["LastDrop"]),
    ]
)
