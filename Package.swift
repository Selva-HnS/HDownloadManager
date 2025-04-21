// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HDownloadManager",
    platforms: [
        .iOS(.v15), // Adjust platform as needed
        .macOS(.v11)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "HDownloadManager",
            targets: ["HDownloadManager"]),
    ],
    dependencies: [
        // Add your SPM dependency here
        .package(url: "https://github.com/ZipArchive/ZipArchive.git", exact: "2.4.3")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "HDownloadManager",
            dependencies: [
                .product(name: "ZipArchive", package: "ZipArchive")
            ]),
        .testTarget(
            name: "HDownloadManagerTests",
            dependencies: ["HDownloadManager"]
        ),
    ]
)
