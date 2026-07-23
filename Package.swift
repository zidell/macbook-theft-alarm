// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Alert",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "alert", targets: ["Alert"])
    ],
    targets: [
        .executableTarget(
            name: "Alert",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Alert/Info.plist"
                ]),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network")
            ]
        )
    ]
)
