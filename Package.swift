// swift-tools-version: 6.0
// Package.swift нужен, чтобы запускать юнит-тесты из консоли и на CI:
//   swift test
// Xcode-проект (SwiftPractice.xcodeproj) остаётся основным способом работы.
// Модуль SwiftPractice собирается из каталога SwiftPractice/ без main.swift
// (main.swift — учебные скрипты с top-level кодом, их тестировать не нужно).
import PackageDescription

let package = Package(
    name: "SwiftPractice",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "SwiftPractice", targets: ["SwiftPractice"])],
    targets: [
        .target(
            name: "SwiftPractice",
            path: "SwiftPractice",
            exclude: ["main.swift"]
        ),
        .testTarget(
            name: "SwiftPracticeTests",
            dependencies: ["SwiftPractice"],
            path: "Tests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
