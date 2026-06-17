// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that can
// be found in the LICENSE file.
//
// Subprocess entry point for the macOS "<App> Helper" bundles. CEF execs this
// executable for each out-of-process child (renderer, GPU, utility, ...). The
// host app builds it as a separate executable target, bundles it at
// <App>.app/Contents/Frameworks/<App> Helper.app, and CEF is pointed at it via
// CefSettings.browser_subprocess_path (see WebviewPlugin::startCEF).
//
// No CefApp is provided here: webview_cef drives page JS from the browser
// process via ExecuteJavaScript, so the renderer needs no native handler. A
// consumer that relies on the C++ JS message channel in the renderer would
// instead pass its CefApp here (and link the common/ sources).

#include <cstdio>

#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  // Load the CEF framework library at runtime (it lives in the outer app's
  // Frameworks dir, reached relative to this helper executable).
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    // Make the failure visible: otherwise the browser side only sees an opaque
    // subprocess-exit error, not that the CEF framework couldn't be loaded
    // (wrong rpath / missing framework / entitlement mismatch).
    fprintf(stderr, "[webview_cef helper] failed to load the CEF framework "
                    "(LoadInHelper); check the embedded framework + rpath.\n");
    return 1;
  }

  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, nullptr, nullptr);
}
