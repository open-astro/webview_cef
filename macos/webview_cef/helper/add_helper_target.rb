#!/usr/bin/env ruby
# Injects the CEF subprocess "Helper" target into a Flutter macOS Runner project
# and wires it to be embedded in the app bundle, so webview_cef can run CEF
# multi-process (the default/stable mode) instead of single-process.
#
# Idempotent: re-running updates the existing target rather than duplicating it.
#
# Usage:
#   ruby add_helper_target.rb <Runner.xcodeproj> <AppName> <plugin_macos_dir>
#
#   <Runner.xcodeproj>  e.g. macos/Runner.xcodeproj
#   <AppName>           the Runner product name, e.g. "openastroara" — the helper
#                       is named "<AppName> Helper"
#   <plugin_macos_dir>  path (relative to the Runner.xcodeproj's parent dir) to
#                       the plugin's macos/webview_cef dir, e.g.
#                       ../packages/webview_cef/macos/webview_cef
#
# The helper links only libcef_dll_wrapper.a + AppKit and dlopens the CEF
# framework at runtime (CefScopedLibraryLoader::LoadInHelper), so it needs no
# framework link — just the wrapper, headers, an rpath to the embedded framework,
# and the JIT entitlements.
require 'xcodeproj'

proj_path, app_name, plugin_macos = ARGV
abort 'usage: add_helper_target.rb <Runner.xcodeproj> <AppName> <plugin_macos_dir>' unless proj_path && app_name && plugin_macos

helper_name   = "#{app_name} Helper"
helper_target = 'Helper'
project       = Xcodeproj::Project.open(proj_path)
macos_dir     = File.dirname(proj_path) # the "macos" dir next to Runner.xcodeproj

runner = project.targets.find { |t| t.name == 'Runner' } or abort 'no Runner target'

# Reuse the Runner's bundle id prefix for the helper's id.
runner_bundle_id = runner.build_configurations.first.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] || 'com.example.app'
helper_bundle_id = "#{runner_bundle_id}.helper"

cef_dir       = "#{plugin_macos}/third/cef"                       # contains include/ + libcef_dll_wrapper.a
helper_src     = "#{plugin_macos}/helper/process_helper_main.cc"
helper_plist   = "#{plugin_macos}/helper/Helper-Info.plist"
helper_ents    = "#{plugin_macos}/helper/helper.entitlements"

# --- Helper target (drop existing first for idempotency) -----------------------
if (old = project.targets.find { |t| t.name == helper_target })
  old.remove_from_project
end
helper = project.new_target(:application, helper_target, :osx, '10.15')

helper.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_NAME']                 = helper_name
  s['PRODUCT_BUNDLE_IDENTIFIER']    = helper_bundle_id
  s['INFOPLIST_FILE']               = helper_plist
  s['CODE_SIGN_ENTITLEMENTS']       = helper_ents
  s['MACOSX_DEPLOYMENT_TARGET']     = '10.15'
  s['CLANG_CXX_LANGUAGE_STANDARD']  = 'c++17'
  s['HEADER_SEARCH_PATHS']          = ['$(inherited)', cef_dir]
  s['LIBRARY_SEARCH_PATHS']         = ['$(inherited)', cef_dir]
  # The framework is embedded in the OUTER app's Frameworks dir; from the helper
  # executable (<App> Helper.app/Contents/MacOS/<App> Helper) that is four levels up.
  s['LD_RUNPATH_SEARCH_PATHS']      = ['$(inherited)', '@executable_path/../../../..']
  s['OTHER_LDFLAGS']                = ['$(inherited)', '-lcef_dll_wrapper', '-framework', 'AppKit']
  s['SKIP_INSTALL']                 = 'YES'
  s['CODE_SIGN_STYLE']              = 'Automatic'
  s['ENABLE_HARDENED_RUNTIME']      = 'YES'
end

src_ref = project.main_group.new_file(helper_src)
helper.source_build_phase.add_file_reference(src_ref)

# --- Runner: embed the helper + JIT entitlements + dependency ------------------
runner.add_dependency(helper)

# Copy the built Helper.app into Runner.app/Contents/Frameworks, signed.
embed = runner.build_phases.find { |p| p.respond_to?(:symbol_dst_subfolder_spec) && p.display_name == 'Embed CEF Helper' }
embed ||= runner.new_copy_files_build_phase('Embed CEF Helper')
embed.symbol_dst_subfolder_spec = :frameworks
embed.files.dup.each { |bf| embed.remove_build_file(bf) }
helper_product = helper.product_reference
bf = embed.add_file_reference(helper_product)
bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }

# Make sure the Runner app has the JIT entitlements merged in (V8). We only add
# the keys if the Runner already has an entitlements file; otherwise we point it
# at the plugin's app.entitlements template.
runner.build_configurations.each do |c|
  c.build_settings['LD_RUNPATH_SEARCH_PATHS'] ||= ['$(inherited)', '@executable_path/../Frameworks']
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] ||= "#{plugin_macos}/helper/app.entitlements"
end

project.save
puts "Wired '#{helper_name}' helper target + embed phase into #{proj_path}"
