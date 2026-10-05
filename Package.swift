// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ObsbotBar",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CObsbotUSB",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "ObsbotBar",
            dependencies: ["CObsbotUSB"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
    ]
)
