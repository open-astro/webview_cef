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

# Validate the plugin inputs up front (paths are relative to the Runner.xcodeproj
# parent dir) so a wrong <plugin_macos_dir> fails here with a clear message
# instead of as a confusing Xcode build error later.
{ 'process_helper_main.cc' => helper_src, 'Helper-Info.plist' => helper_plist,
  'helper.entitlements' => helper_ents }.each do |label, rel|
  abort "missing #{label} at '#{File.join(macos_dir, rel)}' — is <plugin_macos_dir> ('#{plugin_macos}') correct?" \
    unless File.exist?(File.join(macos_dir, rel))
end

# --- Helper target (drop existing first for idempotency) -----------------------
if (old = project.targets.find { |t| t.name == helper_target })
  # Remove the Runner's dependency on the old helper target (and its container
  # proxy) BEFORE deleting the target. Otherwise a dangling PBXTargetDependency
  # (its .target now nil) is left behind and the later add_dependency call crashes
  # in the xcodeproj gem (dependency_for_target derefs dep.target.uuid).
  runner.dependencies.dup.each do |dep|
    if dep.target.nil? || dep.target == old
      dep.target_proxy&.remove_from_project
      dep.remove_from_project
    end
  end
  # Drop the target's product (Helper.app) reference too so re-runs don't leave
  # stale entries accumulating in the Products group.
  old.product_reference&.remove_from_project
  # remove_from_project deletes the target but can leave its XCBuildConfiguration
  # objects (and their XCConfigurationList container) orphaned in the project;
  # remove them explicitly so re-runs don't leave dead config objects behind.
  if (cl = old.build_configuration_list)
    cl.build_configurations.to_a.each(&:remove_from_project)
    cl.remove_from_project
  end
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

# xcodeproj's new_target auto-links Cocoa.framework via an SDK-pinned path
# (DEVELOPER_DIR/Platforms/.../MacOSX<ver>.sdk/...), which hardcodes the build
# machine's SDK version and makes the project fail to build on any other SDK. The
# helper links AppKit through OTHER_LDFLAGS instead, so strip the auto-added
# framework: empty the helper's Frameworks phase and drop every SDK-pinned
# Cocoa.framework file reference (and any build file still pointing at it).
helper.frameworks_build_phase.files.dup.each(&:remove_from_project)
project.objects.select { |o|
  o.isa == 'PBXFileReference' && o.path.to_s =~ %r{/MacOSX[\d.]*\.sdk/.*/Cocoa\.framework\z}
}.each do |ref|
  project.objects.select { |o| o.isa == 'PBXBuildFile' && o.file_ref == ref }.each(&:remove_from_project)
  ref.remove_from_project
end

# Place the helper source in a dedicated "CEF Helper" group rather than the
# project root, so it doesn't clutter the navigator of every consumer. Drop any
# stale reference (anywhere in the project) first so re-runs don't accumulate
# orphaned process_helper_main.cc entries.
project.files.select { |f| f.path == helper_src }.each(&:remove_from_project)
helper_group = project.main_group.groups.find { |g| g.display_name == 'CEF Helper' } ||
               project.main_group.new_group('CEF Helper')
src_ref = helper_group.new_file(helper_src)
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

# The host app needs JIT + framework-loading entitlements (V8 JIT, and
# disable-library-validation so the separately-signed CEF framework can be
# dlopen'd). A standard Flutter app already has CODE_SIGN_ENTITLEMENTS pointing at
# Runner/{DebugProfile,Release}.entitlements, so we MERGE the keys into whatever
# plist each build configuration uses rather than only setting the build setting
# (which would be a no-op when one is already configured). Falls back to the
# plugin's app.entitlements template only for a configuration that has none.
host_keys = %w[
  com.apple.security.cs.allow-jit
  com.apple.security.cs.allow-unsigned-executable-memory
  com.apple.security.cs.disable-library-validation
]

runner.build_configurations.each do |c|
  c.build_settings['LD_RUNPATH_SEARCH_PATHS'] ||= ['$(inherited)', '@executable_path/../Frameworks']
  ents = c.build_settings['CODE_SIGN_ENTITLEMENTS']
  if ents.nil? || ents.to_s.strip.empty?
    c.build_settings['CODE_SIGN_ENTITLEMENTS'] = "#{plugin_macos}/helper/app.entitlements"
    next
  end
  # Resolve the entitlements path (relative to the Runner.xcodeproj parent dir)
  # and merge the required keys into the existing plist. $(SRCROOT)/$(PROJECT_DIR)
  # both resolve to that same dir for a Flutter Runner project.
  resolved = ents.to_s.delete('"').gsub(/\$\((?:SRCROOT|SOURCE_ROOT|PROJECT_DIR)\)/, '.')
  ents_path = File.expand_path(resolved, macos_dir)
  # Abort (don't silently skip) on an unresolved path — skipping would leave the
  # host app without the JIT/library-validation entitlements and surface only as
  # a confusing runtime crash.
  unless File.exist?(ents_path)
    abort "  ! CODE_SIGN_ENTITLEMENTS '#{ents}' (#{c.name}) did not resolve to an existing file " \
          "(tried #{ents_path}). Merge the JIT entitlements manually or fix the path before re-running."
  end
  plist = Xcodeproj::Plist.read_from_path(ents_path) || {}
  added = host_keys.reject { |k| plist[k] == true }
  next if added.empty?
  added.each { |k| plist[k] = true }
  Xcodeproj::Plist.write_to_path(plist, ents_path)
  puts "  merged #{added.size} CEF entitlement(s) into #{File.basename(ents_path)} (#{c.name})"
end

project.save
puts "Wired '#{helper_name}' helper target + embed phase into #{proj_path}"
