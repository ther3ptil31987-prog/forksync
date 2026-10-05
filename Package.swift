// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ForkSync",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ForkSync", path: "Sources/ForkSync")
    ]
)
