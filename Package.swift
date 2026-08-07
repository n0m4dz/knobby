// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Knobby",
    platforms: [
        .macOS("14.4")
    ],
    targets: [
        .executableTarget(
            name: "Knobby",
            path: "Sources/Knobby",
            exclude: ["Resources"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Knobby/Resources/Info.plist",
                ])
            ]
        ),
    ]
)
