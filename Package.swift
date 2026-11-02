// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "YTSA",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "YTSA",
            path: "Sources/YTSA",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
