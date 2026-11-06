// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LaunchUS",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .executableTarget(
            name: "LaunchUS",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/LaunchUS",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework is embedded in LaunchUS.app/Contents/Frameworks by scripts/build.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "LaunchUSTests",
            dependencies: ["LaunchUS"],
            path: "Tests/LaunchUSTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
