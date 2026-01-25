// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SayStuff",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.5.0")
    ],
    targets: [
        .target(
            name: "SayStuff",
            dependencies: ["Sparkle"]
        )
    ]
)
