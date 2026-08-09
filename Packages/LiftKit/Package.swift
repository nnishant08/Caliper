// swift-tools-version: 6.0
import PackageDescription

// LiftKit is a stub until M6. It exists now, at M0, for one reason: §7 of the
// brief reserves the right to either commit properly to programming depth or
// drop the lift log entirely and go pure nutrition. That decision is cheap only
// if the lift log never grows tendrils into the nutrition code.
//
// A package makes the boundary a compiler error rather than a matter of
// discipline. LiftKit must never depend on NutritionKit, and NutritionKit must
// never depend on LiftKit. Anything genuinely shared moves into a third package
// rather than one importing the other.
let package = Package(
    name: "LiftKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LiftKit", targets: ["LiftKit"])
    ],
    targets: [
        .target(
            name: "LiftKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LiftKitTests",
            dependencies: ["LiftKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
