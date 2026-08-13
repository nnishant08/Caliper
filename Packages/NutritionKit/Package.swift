// swift-tools-version: 6.0
import PackageDescription

// NutritionKit holds the trend, expenditure and target-issuance maths.
//
// Two hard rules govern this package, both enforceable by inspection of the
// import list in every file:
//
//   1. No UIKit, no SwiftUI, no HealthKit, no GRDB, no SwiftData. The maths must
//      be testable against synthetic data with no device, no database and no
//      user present.
//   2. No Calendar and no TimeZone. Date-window arithmetic is done in `DayIndex`
//      space (see Sources/NutritionKit/Time/DayIndex.swift). Calendar resolution
//      happens exactly once, at the app boundary, on Darwin Foundation.
//
// Rule 2 exists because this package's test suite runs on Linux in CI, where
// swift-corelibs-foundation's Calendar and TimeZone behaviour diverges from
// Darwin's. A package that is green on Linux and subtly wrong on device is the
// worst outcome available to us, so the engine simply does not have access to
// the types that would let that happen.
let package = Package(
    name: "NutritionKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "NutritionKit", targets: ["NutritionKit"])
    ],
    targets: [
        .target(
            name: "NutritionKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NutritionKitTests",
            dependencies: ["NutritionKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
