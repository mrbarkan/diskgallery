// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dgkeygen",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "dgkeygen", path: "Sources/dgkeygen")
    ]
)
