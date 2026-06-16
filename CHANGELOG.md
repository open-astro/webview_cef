## Unreleased (open-astro fork)
- [macOS] Upgraded CEF/Chromium to **130.1.2** (matching Linux) with Swift Package Manager support (CocoaPods kept as fallback); offscreen WebGL via ANGLE SwiftShader.
- [macOS] Switched from forced single-process to the stable **multi-process** model: the renderer runs in a `<App> Helper.app` subprocess. Added `add_helper_target.rb` to inject the helper target + embed phase + JIT entitlements into a host app's `Runner.xcodeproj` (no manual pbxproj editing).
- [macOS] Fixed offscreen GPU launch failure (run GPU in-process under SwiftShader) and disabled Chromium 130's Rust `fontations` font backend, which panicked on certain glyphs (`crash_in_rust_with_overflow`) in both single- and multi-process modes.

## 0.2.0
- Linux support!
- Multiple instances support.
- js eval support.

## 0.1.0
- JS bridge support (Thanks to @SinyimZhi)
- Cookie manipulation support (Thanks to @SinyimZhi)
- [Windows] fix compile error after upgrade from a lower version

## 0.0.9

- [Windows] Fixed crash caused by frame buffer lock.
- [Windows] Fixed WebGL support.

## 0.0.8

- Added support to build macOS universal app.
- Refined scrolling for different platform.
- Added search bar features in example project.
- Added title & url change aware in UI.

## 0.0.7

- Basic characters input support.
- Added back, forward, reload APIs.
- Mouse move events support.
- HTML5 drag & drop support.

## 0.0.6

- Fixed macOS compile issue.

## 0.0.5

1. Initial support for macOS.
2. Touchpad support (based on flutter 3.3).
3. Hi-DPI display support.

## 0.0.3

- Fixed compile issue on non-utf8 machines.

## 0.0.1

- Webview CEF plugin for Flutter Desktop.
- Windows support only.
