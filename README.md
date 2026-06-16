> **open-astro fork.** Maintained by the OpenAstro Ara project as a patched line of
> [hlwhl/webview_cef](https://github.com/hlwhl/webview_cef). Upstream's last release
> (0.2.2) and its `main` no longer compile against Flutter 3.44+ — Flutter added
> `TextInputClient.onFocusReceived`, which the text-input mixin predates. This fork
> carries that shim (and any further Flutter-compat shims OpenAstro Ara needs). We do
> not track upstream; cherry-pick from it only if it revives. See the §36 Sky Atlas
> embed in the openastro-ara repo.

# WebView CEF

<a href="https://pub.dev/packages/webview_cef"><img src="https://img.shields.io/pub/likes/webview_cef?logo=dart" alt="Pub.dev likes"/></a> <a href="https://pub.dev/packages/webview_cef" alt="Pub.dev popularity"><img src="https://img.shields.io/pub/popularity/webview_cef?logo=dart"/></a> <a href="https://pub.dev/packages/webview_cef"><img src="https://img.shields.io/pub/points/webview_cef?logo=dart" alt="Pub.dev points"/></a> <a href="https://pub.dev/packages/webview_cef"><img src="https://img.shields.io/pub/v/webview_cef.svg" alt="latest version"/></a> <a href="https://pub.dev/packages/webview_cef"><img src="https://img.shields.io/badge/macOS%20%7C%20Windows%20%7C%20Linux-blue?logo=flutter" alt="Platform"/></a>

Flutter Desktop WebView backed by CEF (Chromium Embedded Framework).
This project is under heavy development, and the APIs are not stable yet.

## Index

- [Supported OSs](#supported-oss)
- [Setting Up](#setting-up)
  - [Windows <img align="center" src="https://upload.wikimedia.org/wikipedia/commons/thumb/8/87/Windows_logo_-_2021.svg/1200px-Windows_logo_-_2021.svg.png" width="12">](#windows)
  - [macOS <img align="center" src="https://seeklogo.com/images/A/apple-logo-52C416BDDD-seeklogo.com.png" width="12">](#macos)
  - [Linux <img align="center" src="https://1000logos.net/wp-content/uploads/2017/03/LINUX-LOGO.png" width="14">](#linux)
- [TODOs](#todos)
- [Demo](#demo)
  - [Screenshots](#screenshots)
- [Credits](#credits)

## Supported OSs

- [x] Windows 7+ <img align="center" src="https://upload.wikimedia.org/wikipedia/commons/thumb/8/87/Windows_logo_-_2021.svg/1200px-Windows_logo_-_2021.svg.png" width="12">
- [x] macOS 10.12+ <img align="center" src="https://seeklogo.com/images/A/apple-logo-52C416BDDD-seeklogo.com.png" width="12">
- [x] Linux (x64 and arm64) <img align="center" src="https://1000logos.net/wp-content/uploads/2017/03/LINUX-LOGO.png" width="14">

## Setting Up

### Windows <img src="https://upload.wikimedia.org/wikipedia/commons/thumb/8/87/Windows_logo_-_2021.svg/1200px-Windows_logo_-_2021.svg.png" width="16">

Inside your application folder, you need to add some lines in your `windows\runner\main.cpp`.（Because of Chromium multi process architecture, and IME support, and also flutter rquires invoke method channel on flutter engine thread)

```cpp
//Introduce the source code of this plugin into your own project
#include "webview_cef/webview_cef_plugin_c_api.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  //start cef deamon processes. MUST CALL FIRST
  int exit_code = initCEFProcesses(instance);
  if (exit_code >= 0) {
    return exit_code;
  }
```

```cpp
  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
    
    //add this line to enable cef keybord input, and enable to post messages to flutter engine thread from cef message loop thread.
    handleWndProcForCEF(msg.hwnd, msg.message, msg.wParam, msg.lParam);
  }
```

When building the project for the first time, a prebuilt cef bin package (200MB, link in release) will be downloaded automatically, so you may wait for a longer time if you are building the project for the first time.

### macOS <img src="https://seeklogo.com/images/A/apple-logo-52C416BDDD-seeklogo.com.png" width="15">

To use the plugin in macOS, you'll need to clone the repository onto your project location, prefereably inside a `packages/` folder on the root of your project. 
Update your `pubspec.yaml` file to accomodate the change.
```
...

dependencies:
  # Webview
  webview_cef:
    path: ./packages/webview_cef     # Or wherever you cloned the repo
    
    
...
```

Then fetch the CEF binaries by running the setup script <b>inside the cloned repository</b>:

```sh
./macos/setup_cef.sh        # host arch (arm64 or x86_64)
```

It downloads CEF 130.1.2 (the same Chromium the Linux build uses), builds
`libcef_dll_wrapper.a`, lays the framework out as a versioned bundle, and wraps
both as `.xcframework`s for Swift Package Manager. The binaries are git-ignored;
re-run the script after cloning or when the CEF version changes. Then run the
example app.

> The macOS plugin supports **both Swift Package Manager** (default on Flutter
> 3.44+; the framework is embedded via a binary target) and **CocoaPods** (the
> podspec is kept as a fallback). No extra steps either way once `setup_cef.sh`
> has run.

#### CEF version per platform

| Platform | CEF / Chromium | Source |
|---|---|---|
| macOS | **130.1.2** (chromium-130) | `macos/setup_cef.sh` (Spotify CDN) |
| Linux | **130.1.2** (chromium-130) | `third/download.cmake` (Spotify CDN) |
| Windows | 101.0.18 (chromium-101) | `third/download.cmake` (legacy prebuilt) — **migration to 130 pending** (needs `windows/CMakeLists.txt` rewritten to build the wrapper from the raw Spotify dist, as Linux does, and a Windows build to verify) |

#### Multi-process (macOS helper bundle)

macOS now runs CEF **multi-process** (the stable, default Chromium model): the
renderer runs in a separate `<App> Helper.app` subprocess instead of being
forced into the browser process. Single-process mode was a debug convenience
and is unstable for long-running WebGL/font workloads (the renderer eventually
hits a CHECK/abort).

To wire the helper subprocess into your own host app, run the injection script
against your Flutter `Runner.xcodeproj` once. It needs the [`xcodeproj`](https://rubygems.org/gems/xcodeproj)
gem (`gem install xcodeproj`):

```sh
gem install xcodeproj   # one-time, if not already installed
ruby packages/webview_cef/macos/webview_cef/helper/add_helper_target.rb \
  macos/Runner.xcodeproj <AppName> packages/webview_cef/macos/webview_cef
```

- `<AppName>` is your Runner product name; the helper is named `<AppName> Helper`.
- The last argument is the path (relative to the `macos/` dir) to the plugin's
  `macos/webview_cef` directory.

The script is idempotent — re-running updates the existing target (no duplicated
or orphaned objects). It does regenerate the helper target's UUIDs each run,
though, so **run it once and commit the result**; don't re-run it in a CI
`git diff --exit-code` check (the diff won't be byte-stable). It:

- adds a `Helper` application target (`<AppName> Helper`) that links
  `libcef_dll_wrapper` + AppKit and `dlopen`s the embedded CEF framework at
  runtime via `CefScopedLibraryLoader::LoadInHelper`;
- adds an **Embed CEF Helper** copy-files phase so the helper is bundled into
  `Runner.app/Contents/Frameworks` and code-signed on copy;
- merges the JIT entitlements V8/CEF require (`allow-jit`,
  `allow-unsigned-executable-memory`, `disable-library-validation`) into the
  helper and into the host app's existing entitlements plist(s) — it edits the
  `Runner/{DebugProfile,Release}.entitlements` your project already references,
  not just the build setting.

The plugin discovers the helper automatically (`browser_subprocess_path` is
derived from the running app bundle), so no further code changes are needed. See
`example/macos/Runner.xcodeproj` for a project the script has already been run
against.

> **Distribution note:** `disable-library-validation` (needed so the host
> process can `dlopen` the separately-signed CEF framework) together with
> `allow-jit` is **incompatible with Mac App Store** distribution. This is fine
> for Developer-ID / direct distribution (notarization is unaffected), which is
> how CEF apps normally ship. Note that `disable-library-validation` relaxes
> third-party code-injection protection for the whole host process (not just CEF
> framework loading) — this is the standard CEF-on-macOS requirement, not
> something specific to this plugin.

> **Sandboxed hosts:** the example app is **not** sandboxed, and the script's
> default entitlements assume that. If your host app enables the App Sandbox
> (`com.apple.security.app-sandbox`), you need to do three extra things yourself:
> (1) add `com.apple.security.network.client` to the **host** (the browser
> process opens the sockets, so without it no URL loads); (2) give the **helper**
> both `com.apple.security.app-sandbox` and `com.apple.security.inherit` so it
> joins the host's sandbox container — a sandboxed host with a non-sandboxed
> nested helper fails to launch the child; and (3) be aware that
> `disable-library-validation` is incompatible with sandboxed App Store
> distribution. The script warns when it merges into sandboxed entitlements.

> Offscreen (windowless) rendering uses ANGLE's SwiftShader for WebGL with an
> in-process GPU, and disables Chromium 130's Rust `fontations` font backend
> (it panics on certain glyphs); both are handled inside the plugin.

### Linux <img src="https://1000logos.net/wp-content/uploads/2017/03/LINUX-LOGO.png" width="16">

For Linux, just adding `webview_cef` to your `pubspec.yaml` (e.g. by running `flutter pub add webview_cef`) does the job.

## TODOs

> Pull requests are welcome.

- [x] Windows support
- [x] macOS support
- [x] Linux support
- [x] Multi instance support
- [x] IME support(Only support Third party IME on Linux and Windows, Microsoft IME on Windows, and only tested Chinese input methods)
- [x] Mouse events support
- [x] JS bridge support
- [x] Cookie manipulation support
- [x] Release to pub
- [x] Trackpad support
- [ ] Better macOS binary distribution
- [x] Easier way to integrate macOS helper bundles(multi process) — `add_helper_target.rb`
- [x] devTools support

## Demo

This demo is a simple webview app that can be used to test the `webview_cef` plugin.

<kbd>![demo_compressed](https://user-images.githubusercontent.com/7610615/190432410-c53ef1c4-33c2-461b-af29-b0ecab983579.gif)</kbd>

### Screenshots

| Windows <img src="https://upload.wikimedia.org/wikipedia/commons/thumb/8/87/Windows_logo_-_2021.svg/1200px-Windows_logo_-_2021.svg.png" width="12"> | macOS <img src="https://seeklogo.com/images/A/apple-logo-52C416BDDD-seeklogo.com.png" width="11"> | Linux <img src="https://1000logos.net/wp-content/uploads/2017/03/LINUX-LOGO.png" width="12"> |
| --- | --- | --- |
| <img src="https://user-images.githubusercontent.com/7610615/190431027-6824fac1-015d-4091-b034-dd58f79adbcb.png" width="400" /> | <img src="https://user-images.githubusercontent.com/7610615/190911381-db88cf33-70a2-4abc-9916-e563e54eb3f9.png" width="400" /> | <img src ="https://github.com/hlwhl/webview_cef/assets/49640121/50a4c2f6-1f24-4d10-9913-ad274d76cf3f" width="400" /> |
| <img src="https://user-images.githubusercontent.com/7610615/190431037-62ba0ea7-f7d1-4fca-8ce1-596a0a508f93.png" width="400" /> | <img src="https://user-images.githubusercontent.com/7610615/190911410-bd01e912-5482-4f9e-9dae-858874e5aaed.png" width="400" /> | <img src="https://github.com/hlwhl/webview_cef/assets/49640121/10a693d5-4ee0-4389-a1e8-1b0355f7c0a6" width="400" /> |
| <img src="https://user-images.githubusercontent.com/7610615/195815041-b9ec4da8-560f-4257-9303-f03a016da5c6.png" width="400" /> | <img width="400" alt="image" src="https://user-images.githubusercontent.com/7610615/195818746-e5adf0ef-dc8c-48ad-9b11-e552ca65b08a.png"> | <img src="https://github.com/hlwhl/webview_cef/assets/49640121/3a81f576-b555-4e16-8609-b3c7d6eec869" width="400" /> |

## Credits

This project is inspired from [**`flutter_webview_windows`**](https://github.com/jnschulze/flutter-webview-windows).
