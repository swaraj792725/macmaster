// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacMaster",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacMaster",
            path: "Sources/MacMaster",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
