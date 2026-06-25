#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint webview_cef.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'webview_cef'
  s.version          = '0.0.1'
  s.summary          = 'Flutter webview backed by CEF (Chromium Embedded Framework)'
  s.description      = <<-DESC
Flutter webview backed by CEF (Chromium Embedded Framework)
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  s.source           = { :path => '.' }
  # Sources live under the Swift package layout (webview_cef/Sources/webview_cef)
  # so the same tree feeds both CocoaPods and Swift Package Manager.
  s.source_files     = 'webview_cef/Sources/webview_cef/**/*'
  s.dependency 'FlutterMacOS'
  s.vendored_frameworks = 'webview_cef/third/cef/Chromium Embedded Framework.framework'
  s.vendored_libraries = 'webview_cef/third/cef/libcef_dll_wrapper.a'

  $dir = File.dirname(__FILE__)
  $dir = $dir + "/webview_cef/third/cef/**"
  s.xcconfig = { "HEADER_SEARCH_PATHS" => $dir}
  # s.private_header_files = '../common/simple_app.h', '../common/simple_handler.h'

  s.platform = :osx, '12.0'
  # CEF 149's headers require C++20 (concepts: std::same_as / derived_from /
  # convertible_to, requires-clauses in cef_scoped_refptr.h); the pod target
  # otherwise inherits gnu++14 and fails.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
  }
  s.swift_version = '5.0'
end
