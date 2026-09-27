// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YaYaStatus",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "YaYaStatus", targets: ["YaYaStatus"])],
    targets: [
        .executableTarget(
            name: "YaYaStatus",
            path: "Sources/YaYaStatus",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
