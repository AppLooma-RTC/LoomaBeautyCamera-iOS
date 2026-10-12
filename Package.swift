// swift-tools-version:5.9
// Looma Beauty Camera for iOS, AppLooma RTC's free real-time beauty camera. © AppLooma LLC
import PackageDescription
import Foundation

// Two products:
// - LoomaBeautyCore: every effect, the panels, the catalogue and the assets,
//   with no dependency on the RTC SDK. `AppBeauty.process(_:rotation:timestamp:)`
//   works on any CVPixelBuffer pipeline.
// - LoomaBeautyCamera: LoomaBeautyCore plus the AppLooma RTC glue
//   (`engine.setVideoProcessor(beauty)`); re-exports LoomaBeautyCore.
//
// Inside the AppLooma monorepo the host SDK is the sibling folder (so both are
// built from the same commit); everywhere else it is the published package.
let monorepoSdk = Context.packageDirectory + "/../ios"
let inMonorepo = FileManager.default.fileExists(atPath: monorepoSdk + "/Package.swift")
let hostDependency: Package.Dependency = inMonorepo
    ? .package(path: monorepoSdk)
    : .package(url: "https://github.com/AppLooma-RTC/iOS-SDK.git", from: "0.6.0")
let hostPackage = inMonorepo ? "ios" : "iOS-SDK"

let package = Package(
    name: "LoomaBeautyCamera",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "LoomaBeautyCore", targets: ["LoomaBeautyCore"]),
        .library(name: "LoomaBeautyCamera", targets: ["LoomaBeautyCamera"])
    ],
    dependencies: [hostDependency],
    targets: [
        .target(
            name: "LoomaBeautyCore",
            path: "Sources/LoomaBeautyCore",
            resources: [.copy("Resources/beauty-catalog.json")]
        ),
        .target(
            name: "LoomaBeautyCamera",
            dependencies: [
                "LoomaBeautyCore",
                .product(name: "AppLoomaRTC", package: hostPackage)
            ],
            path: "Sources/LoomaBeautyCamera"
        )
    ]
)
