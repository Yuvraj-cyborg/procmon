// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Procmon",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Procmon",
            swiftSettings: [
                // Shipped builds are optimised for size; debug builds stay fast to compile.
                .unsafeFlags(["-Osize"], .when(configuration: .release)),
            ],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(name: "ProcmonTests", dependencies: ["Procmon"]),
    ]
)
