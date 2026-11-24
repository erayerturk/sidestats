// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SideStats",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SideStats",
            path: "Sources/SideStats"
        )
    ]
)
