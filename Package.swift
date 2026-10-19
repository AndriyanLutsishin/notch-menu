// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotchMenu",
    platforms: [.macOS(.v14)],
    targets: [
        // Логіка без інтерфейсу: історія буфера, фільтр паролів, Claude API, монобанк.
        .target(
            name: "NotchCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Сама програма: панель під чубчиком.
        .executableTarget(
            name: "NotchMenu",
            dependencies: ["NotchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NotchCoreTests",
            dependencies: ["NotchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
