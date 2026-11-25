// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SideStats",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "SideStats",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/SideStats",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
