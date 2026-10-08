// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DoResearch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DoResearch",
            path: "Sources/DoResearch",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
