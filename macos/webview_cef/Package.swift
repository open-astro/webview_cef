// swift-tools-version: 5.9
// The webview_cef macOS plugin as a Swift package, so it integrates under
// Flutter's Swift Package Manager support (the CocoaPods podspec one directory
// up is kept as a fallback for projects that still use CocoaPods).
//
// CEF ships a flat, dynamic framework plus a prebuilt static wrapper lib; Swift
// Package Manager can only embed/link binaries declared as `.binaryTarget`, and
// those must be `.xcframework`s. Both are produced by the macOS setup step from
// the downloaded CEF distribution (see macos/webview_cef/third/cef) and are
// git-ignored — run that step before building.
import PackageDescription

let package = Package(
    name: "webview_cef",
    platforms: [
        .macOS("10.15"),
    ],
    products: [
        .library(name: "webview-cef", targets: ["webview_cef"]),
    ],
    targets: [
        // The Chromium Embedded Framework itself — embedded + signed into the app
        // bundle by Flutter because it is a binary framework target.
        .binaryTarget(
            name: "ChromiumEmbeddedFramework",
            path: "third/cef/Chromium Embedded Framework.xcframework"
        ),
        // CEF's C++ DLL wrapper (prebuilt static lib) — linked, not embedded.
        .binaryTarget(
            name: "libcef_dll_wrapper",
            path: "third/cef/libcef_dll_wrapper.xcframework"
        ),
        .target(
            name: "webview_cef",
            dependencies: [
                "ChromiumEmbeddedFramework",
                "libcef_dll_wrapper",
            ],
            // CEF headers are referenced as `include/cef_*.h`, so the search path
            // is the directory that contains `include/` (third/cef).
            cSettings: [
                .headerSearchPath("../../third/cef"),
            ],
            cxxSettings: [
                .headerSearchPath("../../third/cef"),
            ],
            linkerSettings: [
                .linkedFramework("CoreVideo"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
