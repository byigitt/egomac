// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EGOMac",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "EGOMac",
            dependencies: ["SwiftSoup"],
            path: "Sources/EGOMac",
            exclude: ["Resources"]
        ),
    ]
)
