// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "DittoMac",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "DittoMac",
            path: "Sources/DittoMac",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
