// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Recorder",
    platforms: [.macOS("15.0")],
    targets: [
        .target(name: "RecorderCore", path: "Sources/RecorderCore"),
        .executableTarget(
            name: "Recorder",
            dependencies: ["RecorderCore"],
            path: "Sources/Recorder"
        ),
        .testTarget(
            name: "RecorderCoreTests",
            dependencies: ["RecorderCore"],
            path: "Tests/RecorderCoreTests"
        ),
    ]
)
