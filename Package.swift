// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XCResultExplorer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "xcresult-explorer", targets: ["XCResultExplorer"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "XCResultExplorer",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)