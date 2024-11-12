// swift-tools-version:5.3.0

import PackageDescription

let package = Package(
    name: "PaymentLedger",
    platforms: [.iOS(.v12), .macOS(.v10_12)],
    products: [
        .library(name: "PaymentLedger", targets: ["PaymentLedger"])
    ],
    dependencies: [
        .package(url: "git@github.com:bizz84/SwiftyStoreKit.git", .exactItem("0.16.3")),
        .package(url: "git@github.com:kishikawakatsumi/KeychainAccess.git", .exactItem("4.2.2")),
        .package(url: "git@github.com:MobileNativeFoundation/Kronos.git", .exactItem("4.2.1")),
        .package(url: "git@github.com:rosberry/ion.git", .branchItem("master"))
    ],
    targets: [
        .target(
            name: "PaymentLedger",
            dependencies: [
                .product(name: "SwiftyStoreKit", package: "SwiftyStoreKit"),
                .product(name: "KeychainAccess", package: "KeychainAccess"),
                .product(name: "Kronos", package: "Kronos"),
                .product(name: "Ion", package: "ion")
            ],
            path: "Sources/Ledger",
            resources: [])
    ]
)
