// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FirebaseUploaderMac",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "FirebaseUploaderMac",
            path: "Sources/FirebaseUploaderMac",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
