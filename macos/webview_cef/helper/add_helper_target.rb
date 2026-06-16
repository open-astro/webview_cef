#!/usr/bin/env ruby
# Injects the CEF subprocess "Helper" target into a Flutter macOS Runner project
# and wires it to be embedded in the app bundle, so webview_cef can run CEF
# multi-process (the default/stable mode) instead of single-process.
#
# Idempotent: re-running updates the existing target rather than duplicating it.
# Note: it tears down and recreates the Helper target, so each run regenerates
# the target's object UUIDs — the end state is convergent (no duplication / dead
# objects), but re-running produces a non-empty project.pbxproj git diff even
# when nothing substantive changed. Run it once and commit the result; don't
# expect byte-stable output across runs (e.g. in a CI verify step).
#
# Usage:
#   ruby add_helper_target.rb <Runner.xcodeproj> <AppName> <plugin_macos_dir>
#
#   <Runner.xcodeproj>  e.g. macos/Runner.xcodeproj
#   <AppName>           the Runner product name, e.g. "openastroara" — the helper
#                       is named "<AppName> Helper". MUST match the app's
#                       CFBundleExecutable (= PRODUCT_NAME for a stock Flutter
#                       app); the plugin derives the helper path from
#                       CFBundleExecutable at runtime, so a mismatch makes the
#                       helper unfindable and forces single-process mode.
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

# Reuse the Runner's bundle id prefix for the helper's id. Flutter projects set
# PRODUCT_BUNDLE_IDENTIFIER in Runner/Configs/AppInfo.xcconfig, so the project
# file often holds the literal "$(PRODUCT_BUNDLE_IDENTIFIER)" (or nothing) rather
# than a real id. Resolve through the xcconfig(s) before falling back, otherwise
# the helper would get a bogus id like "$(PRODUCT_BUNDLE_IDENTIFIER).helper".
def resolve_bundle_id(runner, macos_dir)
  raw = runner.build_configurations.first.build_settings['PRODUCT_BUNDLE_IDENTIFIER']
  # Reject any unresolved value ($(...) or ${...}) and fall through to the xcconfig.
  return raw if raw && !raw.empty? && !raw.include?('$')
  # Flutter keeps the real id in Runner/Configs/AppInfo.xcconfig. Search only the
  # Runner's own xcconfigs — NOT Pods/, whose configs carry an unrelated
  # "org.cocoapods.${PRODUCT_NAME:rfc1034identifier}" default.
  Dir.glob(File.join(macos_dir, 'Runner', '**', '*.xcconfig')).sort.each do |xc|
    File.foreach(xc) do |line|
      if line =~ /^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*(\S+)/
        # Strip a trailing inline "// comment" defensively (xcconfig only really
        # supports whole-line comments, but be robust).
        val = Regexp.last_match(1).strip.sub(%r{//.*\z}, '')
        return val unless val.empty? || val.include?('$')
      end
    end
  end
  nil
end

runner_bundle_id = resolve_bundle_id(runner, macos_dir)
if runner_bundle_id.nil? || runner_bundle_id.empty?
  # Abort rather than fall back to a com.example.app placeholder: a bogus helper
  # bundle id builds fine locally but fails notarization later with a non-obvious
  # root cause. Better to stop and have the caller pass/define a real id.
  abort "  ! could not resolve the Runner's PRODUCT_BUNDLE_IDENTIFIER (checked the " \
        "project file + Runner/*.xcconfig). Set PRODUCT_BUNDLE_IDENTIFIER to a real " \
        "id (e.g. in Runner/Configs/AppInfo.xcconfig) before re-running."
end
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
  # The CEF framework is embedded in the OUTER app's Contents/Frameworks dir.
  # From the helper executable (<App> Helper.app/Contents/MacOS/<App> Helper):
  #   ..       -> Contents/        (of <App> Helper.app)
  #   ../..    -> <App> Helper.app/
  #   ../../.. -> <App>.app/Contents/Frameworks/   (where the CEF framework lives)
  # (CefScopedLibraryLoader::LoadInHelper dlopens via a computed path, so this
  # rpath is a belt-and-suspenders fallback.)
  s['LD_RUNPATH_SEARCH_PATHS']      = ['$(inherited)', '@executable_path/../../..']
  s['OTHER_LDFLAGS']                = ['$(inherited)', '-lcef_dll_wrapper', '-framework', 'AppKit']
  s['SKIP_INSTALL']                 = 'YES'
  s['CODE_SIGN_STYLE']              = 'Automatic'
  s['ENABLE_HARDENED_RUNTIME']      = 'YES'
  # xcodeproj's new_target seeds CLANG_ENABLE_OBJC_WEAK = NO; the helper is pure
  # C++ so it's irrelevant — drop it so it doesn't confuse readers and inherits
  # the project/Xcode default.
  s.delete('CLANG_ENABLE_OBJC_WEAK')
end

# new_target names the product reference "Helper.app" (after the target name),
# but PRODUCT_NAME builds "<App> Helper.app". Align the product reference so the
# pbxproj is self-consistent (the embed phase resolves the product by target, so
# the build works either way, but this avoids a confusing Helper.app vs
# "<App> Helper.app" mismatch in the project).
helper.product_reference.path = "#{helper_name}.app"

# Order the helper's build configurations Debug, Profile, Release to match the
# canonical Flutter Runner layout (new_target emits them in a different order).
config_order = { 'Debug' => 0, 'Profile' => 1, 'Release' => 2 }
helper.build_configuration_list.build_configurations.sort_by! { |c| config_order.fetch(c.name, 99) }

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
# new_target also leaves an empty "OS X" group (it had held Cocoa.framework);
# drop it once empty so it doesn't litter the navigator. Search all groups, not
# just top-level ones, since the gem nests it.
project.objects.select { |o|
  o.isa == 'PBXGroup' && o.display_name == 'OS X' && o.children.empty?
}.each(&:remove_from_project)

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
  # Ensure the Frameworks rpath is present (don't just set-if-absent): a project
  # that already defines LD_RUNPATH_SEARCH_PATHS without @executable_path/../Frameworks
  # would otherwise fail to dlopen the embedded CEF framework at runtime. xcodeproj
  # returns this as an Array for multi-value entries and a space-separated String
  # for single-value ones; preserve whichever shape it already uses (and only
  # append when the rpath isn't already a whitespace-delimited token, so re-runs
  # don't duplicate it).
  fw_rpath = '@executable_path/../Frameworks'
  raw_rpaths = c.build_settings['LD_RUNPATH_SEARCH_PATHS']
  case raw_rpaths
  when Array
    raw_rpaths << fw_rpath unless raw_rpaths.include?(fw_rpath)
    c.build_settings['LD_RUNPATH_SEARCH_PATHS'] = raw_rpaths
  when String
    unless raw_rpaths.split(/\s+/).include?(fw_rpath)
      c.build_settings['LD_RUNPATH_SEARCH_PATHS'] =
        raw_rpaths.strip.empty? ? fw_rpath : "#{raw_rpaths} #{fw_rpath}"
    end
  else
    c.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', fw_rpath]
  end

  ents = c.build_settings['CODE_SIGN_ENTITLEMENTS']
  if ents.nil? || ents.to_s.strip.empty?
    c.build_settings['CODE_SIGN_ENTITLEMENTS'] = "#{plugin_macos}/helper/app.entitlements"
    next
  end
  # Resolve the entitlements path (relative to the Runner.xcodeproj parent dir)
  # and merge the required keys into the existing plist. $(SRCROOT)/$(PROJECT_DIR)/
  # $(SOURCE_ROOT) all resolve to that same dir for a Flutter Runner project;
  # accept both $(...) and ${...} forms.
  resolved = ents.to_s.delete('"').gsub(/\$[({](?:SRCROOT|SOURCE_ROOT|PROJECT_DIR)[)}]/, '.')
  ents_path = File.expand_path(resolved, macos_dir)
  # Abort (don't silently skip) on an unresolved path — skipping would leave the
  # host app without the JIT/library-validation entitlements and surface only as
  # a confusing runtime crash.
  unless File.exist?(ents_path)
    abort "  ! CODE_SIGN_ENTITLEMENTS '#{ents}' (#{c.name}) did not resolve to an existing file " \
          "(tried #{ents_path}). Merge the JIT entitlements manually or fix the path before re-running."
  end
  # Abort (don't fall back to {}) if the plist can't be parsed: writing an empty
  # hash back would erase the host app's existing entitlements (sandbox, network,
  # …) and leave only the three CEF keys.
  plist = Xcodeproj::Plist.read_from_path(ents_path)
  abort "  ! could not parse #{ents_path} as a plist (#{c.name}); refusing to " \
        "overwrite it. Merge the JIT entitlements manually." unless plist
  # disable-library-validation is incompatible with the App Sandbox for
  # distribution; if the host is sandboxed, warn rather than silently produce a
  # contradictory entitlement set (and the helper would also need app-sandbox +
  # inherit — see the README "sandboxed hosts" note).
  if plist['com.apple.security.app-sandbox'] == true
    warn "  ! #{File.basename(ents_path)} (#{c.name}) enables the App Sandbox; adding " \
         "disable-library-validation produces a combination incompatible with sandboxed " \
         "distribution. A sandboxed host also needs the helper to carry app-sandbox + " \
         "com.apple.security.inherit. See the README \"sandboxed hosts\" note."
  end
  added = host_keys.reject { |k| plist[k] == true }
  next if added.empty?
  added.each { |k| plist[k] = true }
  Xcodeproj::Plist.write_to_path(plist, ents_path)
  puts "  merged #{added.size} CEF entitlement(s) into #{File.basename(ents_path)} (#{c.name})"
end

project.save
puts "Wired '#{helper_name}' helper target + embed phase into #{proj_path}"
puts "  note: this grants com.apple.security.cs.disable-library-validation to the " \
     "HOST app (needed to load the separately-signed CEF framework). It relaxes " \
     "dylib-injection protection for the whole host process and is incompatible " \
     "with Mac App Store distribution — fine for Developer-ID. Re-running this " \
     "script regenerates target UUIDs, so commit the result once; don't re-run it " \
     "in a CI 'git diff --exit-code' check."
