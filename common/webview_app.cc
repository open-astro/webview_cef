// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#include "webview_app.h"

#include <string>

#include "include/cef_browser.h"
#include "include/cef_command_line.h"
#include "include/cef_version.h"  // CEF_VERSION_MAJOR (fontations workaround gate)
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"
#include "include/wrapper/cef_helpers.h"

namespace {

// When using the Views framework this object provides the delegate
// implementation for the CefWindow that hosts the Views-based browser.
class SimpleWindowDelegate : public CefWindowDelegate {
public:
    explicit SimpleWindowDelegate(CefRefPtr<CefBrowserView> browser_view)
    : browser_view_(browser_view) {}
    
    void OnWindowCreated(CefRefPtr<CefWindow> window) override {
        // Add the browser view and show the window.
        window->AddChildView(browser_view_);
        window->Show();
        
        // Give keyboard focus to the browser view.
        browser_view_->RequestFocus();
    }
    
    void OnWindowDestroyed(CefRefPtr<CefWindow> window) override {
        browser_view_ = nullptr;
    }
    
    bool CanClose(CefRefPtr<CefWindow> window) override {
        // Allow the window to close if the browser says it's OK.
        CefRefPtr<CefBrowser> browser = browser_view_->GetBrowser();
        if (browser)
            return browser->GetHost()->TryCloseBrowser();
        return true;
    }
    
    CefSize GetPreferredSize(CefRefPtr<CefView> view) override {
        return CefSize(1280, 720);
    }
    
private:
    CefRefPtr<CefBrowserView> browser_view_;
    
    IMPLEMENT_REFCOUNTING(SimpleWindowDelegate);
    DISALLOW_COPY_AND_ASSIGN(SimpleWindowDelegate);
};

class SimpleBrowserViewDelegate : public CefBrowserViewDelegate {
public:
    SimpleBrowserViewDelegate() {}
    
    bool OnPopupBrowserViewCreated(CefRefPtr<CefBrowserView> browser_view,
                                   CefRefPtr<CefBrowserView> popup_browser_view,
                                   bool is_devtools) override {
        // Create a new top-level Window for the popup. It will show itself after
        // creation.
        CefWindow::CreateTopLevelWindow(
                                        new SimpleWindowDelegate(popup_browser_view));
        
        // We created the Window.
        return true;
    }
    
private:
    IMPLEMENT_REFCOUNTING(SimpleBrowserViewDelegate);
    DISALLOW_COPY_AND_ASSIGN(SimpleBrowserViewDelegate);
};

}  // namespace

WebviewApp::WebviewApp(CefRefPtr<WebviewHandler> handler) {
    m_handler = handler;
}

WebviewApp::ProcessType WebviewApp::GetProcessType(CefRefPtr<CefCommandLine> command_line)
{
    // The command-line flag won't be specified for the browser process.
	if (!command_line->HasSwitch("type"))
    {
        return BrowserProcess;
    }

	const std::string& process_type = command_line->GetSwitchValue("type");
	if (process_type == "renderer")
		return RendererProcess;
#if defined(OS_LINUX)
	else if (process_type == "zygote")
		return ZygoteProcess;
#endif
	return OtherProcess;
}

void WebviewApp::OnBeforeCommandLineProcessing(const CefString &process_type, CefRefPtr<CefCommandLine> command_line)
{
    // Pass additional command-line flags to the browser process.
	if (process_type.empty())
	{
		if (!m_bEnableGPU)
		{
			// Software offscreen rendering WITH software WebGL — the combo that makes
			// CefRenderHandler::OnPaint fire AND lets WebGL (Aladin Lite v3) paint.
			// --disable-gpu + --disable-gpu-compositing keep the whole pipeline on the
			// software compositor so frames come straight from OnPaint with no GPU
			// readback. Modern Chromium disables WebGL when the GPU is off UNLESS
			// --enable-unsafe-swiftshader is set, which re-enables it via *in-process*
			// SwiftShader whose frames land in that same OnPaint buffer. Do NOT add
			// --use-angle=swiftshader (forces an ANGLE GPU process; the software OnPaint
			// readback then comes back blank), and do NOT set --disable-gpu-vsync or
			// --headless (both suppress OnPaint). --enable-begin-frame-scheduling makes
			// the software compositor actually produce frames.
			command_line->AppendSwitch("disable-gpu");
			command_line->AppendSwitch("disable-gpu-compositing");
			command_line->AppendSwitch("enable-unsafe-swiftshader");
			command_line->AppendSwitch("enable-begin-frame-scheduling");
		}
		command_line->AppendSwitch("disable-web-security");                                     //disable web security
		command_line->AppendSwitch("allow-running-insecure-content");                           //allow running insecure content in secure pages
		// Don't create a "GPUCache" directory when cache-path is unspecified.
		command_line->AppendSwitch("disable-gpu-shader-disk-cache");                            //disable gpu shader disk cache
        // (Sandbox is disabled authoritatively via CefSettings.no_sandbox in
        // WebviewPlugin::startCEF, which makes CEF propagate --no-sandbox to every
        // process; no command-line switch is added here. The original upstream line
        // was misspelled "no-sanbox" and was a no-op anyway.)

#ifdef __APPLE__
		// macOS: force single-process (renderer + GPU inside the browser process).
		// The out-of-process model fails here — the GPU subprocess won't launch
		// (gpu_process_host error_code=1003 from the single embedded helper bundle;
		// CEF then fatally aborts "GPU process isn't usable. Goodbye.") and the
		// renderer subprocess never paints (white screen). This DISABLES the renderer
		// sandbox, which is acceptable for this trusted-content OSR embed (Aladin Lite
		// from a bundled page); the teardown caveat (exit() racing live CEF threads)
		// is handled by driving CefShutdown on app exit (AppLifecycleListener
		// .onExitRequested -> WebviewManager().quit()). The m_uMode process-model
		// selection is intentionally skipped on macOS — single-process overrides it.
		command_line->AppendSwitch("single-process");
#else
		// Linux/Windows: keep the multi-process model (out-of-process GPU/renderer is
		// verified working and preserves the renderer sandbox). Honor the caller's
		// requested process model. http://www.chromium.org/developers/design-documents/process-models
		if (m_uMode == 1)
		{
			command_line->AppendSwitch("process-per-site");                                     //each site in its own process
			command_line->AppendSwitchWithValue("renderer-process-limit", "8");              //limit renderer process count to decrease memory usage
		}
		else if (m_uMode == 2)
		{
			command_line->AppendSwitch("process-per-tab");                                      //each tab in its own process
		}
		else if (m_uMode == 3)
		{
			command_line->AppendSwitch("single-process");                                       //all in one process (debug-only / unstable)
		}
#endif
		command_line->AppendSwitchWithValue("autoplay-policy", "no-user-gesture-required");     //autoplay policy for media

        //Support cross domain requests
        std::string values = command_line->GetSwitchValue("disable-features");
        // Comma-delimited token check (not a substring search) so a feature name
        // that merely *contains* another (e.g. "NewFontationsFontBackend") can't be
        // mistaken for an existing entry.
        auto hasFeature = [&values](const char* tok) {
            const std::string t(tok);
            if (t.empty()) return false; // guard: an empty token would loop forever
            for (size_t p = values.find(t); p != std::string::npos; p = values.find(t, p + t.size())) {
                const bool startOk = (p == 0 || values[p - 1] == ',');
                const size_t end = p + t.size();
                const bool endOk = (end == values.size() || values[end] == ',');
                if (startOk && endOk) return true;
            }
            return false;
        };
        auto appendFeature = [&values, &hasFeature](const char* tok) {
            if (hasFeature(tok)) return;        // don't duplicate an existing entry
            values += (values.empty() ? "" : ",");
            values += tok;
        };
        appendFeature("SameSiteByDefaultCookies");
        appendFeature("CookiesWithoutSameSiteMustBeSecure");
#ifdef _WIN32
        // Native window-occlusion tracking is a Windows-only Chromium feature
        // (it can pause rendering for "occluded" offscreen windows); disabling it
        // is a no-op elsewhere, so only touch it on Windows.
        appendFeature("CalculateNativeWinOcclusion");
#endif
#if defined(CEF_VERSION_MAJOR) && CEF_VERSION_MAJOR >= 130
        // Chromium 130 made the Rust "fontations" backend the default Skia font
        // rasterizer. It panics with an integer overflow (crash_in_rust_with_overflow
        // in fontations_ffi BridgeBitmapGlyph) on certain glyphs — reproduced in
        // both single- and multi-process CEF on macOS. Fall back to the long-stable
        // FreeType path.
        //
        // Gate on the CEF major version, not the OS: this is a Chromium-version bug
        // (fontations became the default in 130), not a platform one. macOS and Linux
        // both download CEF 130.1.2 here and need it; the Windows fork is still on
        // CEF 101 (pre-fontations) so the macro is 101 and the switch is dropped.
        // Keying off the actually-compiled CEF version means a future Windows bump to
        // 130 is covered with no code change, and any platform rolled back below 130
        // sheds the now-irrelevant switch on its own.
        // NOTE: this only runs in the browser process (OnBeforeCommandLineProcessing
        // here, process_type empty). In this plugin the Helper runs
        // CefExecuteProcess with a NULL CefApp, so this callback doesn't fire in any
        // subprocess — the fix still reaches the renderer because Chromium copies
        // --disable-features onto each child process's command line for feature-state
        // consistency. (So renderer-only feature flags can't be added via this
        // callback in this design — they'd need the helper to pass its own CefApp.)
        // TODO: remove this workaround once the upstream Chromium "fontations" font
        // backend stops panicking (re-test on each CEF/Chromium upgrade).
        appendFeature("FontationsFontBackend");
#endif

        command_line->AppendSwitchWithValue("disable-features", values);
        // for unsafe domain, add domain to whitelist
		if (!m_strFilterDomain.empty())
		{
			command_line->AppendSwitch("ignore-certificate-errors");                            //ignore certificate errors
			command_line->AppendSwitchWithValue("unsafely-treat-insecure-origin-as-secure",
                m_strFilterDomain);
		}

#ifdef __APPLE__
		// Route Chromium's keychain access to a mock so it doesn't prompt. Scoped to
		// the browser process intentionally: on macOS keychain access (password /
		// cookie / cert storage) is a browser-process responsibility — the
		// renderer/GPU subprocesses don't talk to the keychain directly — so the
		// mock only needs to be set here. (This callback fires per process type, so
		// without the guard the switch would also be appended to every subprocess
		// command line unnecessarily.)
		command_line->AppendSwitch("use-mock-keychain");
#endif
    }

    // NOTE: single-process mode is intentionally NOT forced on macOS anymore. It
    // is a debug-only Chromium mode and is unstable for long-running WebGL/font
    // work (renderer CHECK/abort after hours). macOS now runs multi-process via
    // the bundled "<App> Helper.app" subprocess (see browser_subprocess_path in
    // WebviewPlugin::startCEF + the helper target the host app embeds).
}

void WebviewApp::OnContextInitialized()
{
    CEF_REQUIRE_UI_THREAD();
//    CefBrowserSettings browser_settings;
//    browser_settings.windowless_frame_rate = 60;
//                
//    CefWindowInfo window_info;
//    window_info.SetAsWindowless(0);
//
//    // create browser
//    CefBrowserHost::CreateBrowser(window_info, m_handler, "", browser_settings, nullptr, nullptr);
    
}

// CefRefPtr<CefClient> WebviewApp::GetDefaultClient() {
//     // Called when a new browser window is created via the Chrome runtime UI.
//     return WebviewHandler::GetInstance();
// }

void WebviewApp::SetUnSafelyTreatInsecureOriginAsSecure(const CefString &strFilterDomain)
{
    m_strFilterDomain = strFilterDomain;
}

void WebviewApp::OnWebKitInitialized()
{
    //inject js function for jssdk
    std::string extensionCode = R"(
			var external = {};
			var clientSdk = {};
			(() => {
				clientSdk.jsCmd = (functionName, arg1, arg2, arg3) => {
					if (typeof arg1 === 'function') {
						native function jsCmd(functionName, arg1);
						return jsCmd(functionName, arg1);
					} 
					else if	 (typeof arg2 === 'function') {
                        jsonString = arg1;
                        if	(typeof arg1 !== 'string'){
						    jsonString = JSON.stringify(arg1);
                        }
						native function jsCmd(functionName, jsonString, arg2);
						return jsCmd(functionName, jsonString, arg2);
					}
					else if	 (typeof arg3 === 'function') {
                        jsonString = arg1;
                        if	(typeof arg1 !== 'string'){
						    jsonString = JSON.stringify(arg1);
                        }
						native function jsCmd(functionName, jsonString, arg2, arg3);
						return jsCmd(functionName, jsonString, arg2, arg3);
					}else {

					}
				};

                external.JavaScriptChannel = (n,e,r) => {
                    var a; 
                    null == r ? a = '' : (a = '_' + new Date + (1e3 + Math.floor(8999 * Math.random())), window[a] = function (n, e) { 
                        return function () { 
                            try {
                                e && e.call && e.call(null, arguments[1]) 
                            } finally {
                                delete window[n]
                            } 
                        } 
                    }(a, r)); 
                    try {
                        external.StartRequest(external.GetNextReqID(), n, a, JSON.stringify(e || {}), '') 
                    } catch (l) {
                        console.log('messeage send')
                    }
                }

                external.EvaluateCallback = (nReqID, result) => {
                    native function EvaluateCallback();
                    EvaluateCallback(nReqID, result);
                }

				external.StartRequest  = (nReqID, strCmd, strCallBack, strArgs, strLog) => {
					native function StartRequest();
					StartRequest(nReqID, strCmd, strCallBack, strArgs, strLog);
				};
				external.GetNextReqID  = () => {
				  native function GetNextReqID();
				  return GetNextReqID();
				};
			})();
		 )";

    CefRefPtr<CefJSHandler> handler = new CefJSHandler();

    if (!m_render_js_bridge.get())
        m_render_js_bridge.reset(new CefJSBridge);
    handler->AttachJSBridge(m_render_js_bridge);

    CefRegisterExtension("v8/extern", extensionCode, handler);
}

void WebviewApp::OnBrowserCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDictionaryValue> extra_info)
{
    if (!m_render_js_bridge.get()) {
        m_render_js_bridge.reset(new CefJSBridge);
    }
}

void WebviewApp::SetProcessMode(uint32_t uMode)
{
    m_uMode = uMode;
}

void WebviewApp::SetEnableGPU(bool bEnable)
{
    m_bEnableGPU = bEnable;
}

void WebviewApp::OnBeforeChildProcessLaunch(CefRefPtr<CefCommandLine> command_line)
{
}

void WebviewApp::OnBrowserDestroyed(CefRefPtr<CefBrowser> browser)
{
}

void WebviewApp::OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context)
{
}

void WebviewApp::OnContextReleased(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context)
{
    if (m_render_js_bridge.get())
    {
        m_render_js_bridge->RemoveCallbackFuncWithFrame(frame);
    }
}

void WebviewApp::OnUncaughtException(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context, CefRefPtr<CefV8Exception> exception, CefRefPtr<CefV8StackTrace> stackTrace)
{
}

void WebviewApp::OnFocusedNodeChanged(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefDOMNode> node)
 {    
    //Get node attribute
    bool is_editable = (node.get() && node->IsEditable());
    CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kFocusedNodeChangedMessage);
    message->GetArgumentList()->SetBool(0, is_editable);
    if (is_editable)
    {
        CefRect rect = node->GetElementBounds();
        message->GetArgumentList()->SetInt(1, rect.x);
        message->GetArgumentList()->SetInt(2, rect.y + rect.height);
    }
    frame->SendProcessMessage(PID_BROWSER, message);
}

bool WebviewApp::OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefProcessId source_process, CefRefPtr<CefProcessMessage> message)
{
    const CefString& message_name = message->GetName();
    if (message_name == kExecuteJsCallbackMessage)
    {
        int			callbackId = message->GetArgumentList()->GetInt(0);
        bool		error = message->GetArgumentList()->GetBool(1);
        CefString	result = message->GetArgumentList()->GetString(2);
        if (m_render_js_bridge.get())
        {
            m_render_js_bridge->ExecuteJSCallbackFunc(callbackId, error, result);
        }
    }

    return false;
}
