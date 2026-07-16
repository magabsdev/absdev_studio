// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ABSDEVStudio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ABSDEVStudio", targets: ["ABSDEVStudio"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "ABSDEVStudio",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/ABSDEVStudio"
        ),
        .testTarget(
            name: "ABSDEVStudioTests",
            dependencies: ["ABSDEVStudio"],
            path: "Tests/ABSDEVStudioTests"
        )
    ]
)
