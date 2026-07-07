// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "pixa",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "pixa", targets: ["pixa"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "pixa",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
