// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "DropBoxImage",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "DropBoxImage",
            targets: ["DropBoxImage"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/dropbox/SwiftyDropbox.git", from: "10.1.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies.git", from: "1.4.1"),
        // Add other dependencies here
    ],
    targets: [
        .target(
            name: "DropBoxImage",
            dependencies: [
                .product(name: "SwiftyDropbox", package: "SwiftyDropbox"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                // Add other dependencies here
            ],
            path: "Sources"),
        .testTarget(
            name: "DropBoxImageTests",
            dependencies: ["DropBoxImage"]),
    ]
)
