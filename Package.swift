// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "soulvercalc",
    platforms: [.macOS("13.5")],
    dependencies: [
        .package(url: "https://github.com/soulverteam/SoulverCore", from: "3.0.0")
    ],
    targets: [
        .executableTarget(
            name: "soulvercalc",
            dependencies: [.product(name: "SoulverCore", package: "SoulverCore")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        )
    ]
)
