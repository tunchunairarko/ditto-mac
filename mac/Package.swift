// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "DittoMac",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        // The app itself. It is a library rather than part of the executable so
        // that the tests can link against it.
        .target(
            name: "DittoKit",
            path: "Sources/DittoKit",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement")
            ]
        ),

        // Two lines: hand control to DittoKit.
        .executableTarget(
            name: "DittoMac",
            dependencies: ["DittoKit"],
            path: "Sources/DittoMac"
        ),

        // The parts worth testing without a window server: the database schema
        // that has to stay compatible with Windows Ditto, the byte layouts, the
        // search language, the paste transforms, and the auto-delete rules.
        .testTarget(
            name: "DittoKitTests",
            dependencies: ["DittoKit"],
            path: "Tests/DittoKitTests"
        )
    ]
)
