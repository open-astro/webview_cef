#!/usr/bin/env ruby
# Injects the CEF subprocess "Helper" targets into a Flutter macOS Runner project
# and wires them to be embedded in the app bundle, so webview_cef runs CEF
# multi-process — the same model it uses on Linux/Windows — on macOS too.
#
# macOS multi-process CEF requires the *full set* of helper bundles, not one:
# the base "<App> Helper" plus the typed "<App> Helper (GPU)", "(Renderer)",
# "(Plugin)" and "(Alerts)" siblings, all in Contents/Frameworks. CEF derives the
# typed child paths from the base helper that browser_subprocess_path points at,
# so a missing sibling makes CEF fail to launch that child — most visibly the GPU
# process (gpu_process_host error_code=1003 → "GPU process isn't usable.
# Goodbye."). This script generates all five (mirroring CEF's own
# CEF_HELPER_APP_SUFFIXES in cmake/cef_variables.cmake.in).
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
#   <AppName>           the Runner product name, e.g. "openastroara" — the base
#                       helper is named "<AppName> Helper" (typed siblings get a
#                       " (GPU)"/"(Renderer)"/… suffix). MUST match the app's
#                       CFBundleExecutable (= PRODUCT_NAME for a stock Flutter
#                       app); the plugin derives the base helper path from
#                       CFBundleExecutable at runtime, so a mismatch makes the
#                       helpers unfindable and CEF subprocess launch fails.
#   <plugin_macos_dir>  path (relative to the Runner.xcodeproj's parent dir) to
#                       the plugin's macos/webview_cef dir, e.g.
#                       ../packages/webview_cef/macos/webview_cef
#
# The helper links only libcef_dll_wrapper.a + AppKit and dlopens the CEF
# framework at runtime (CefScopedLibraryLoader::LoadInHelper), so it needs no
# framework link — just the wrapper, headers, an rpath to the embedded framework,
# and the JIT entitlements.
begin
  require 'xcodeproj'
rescue LoadError
  abort "missing the 'xcodeproj' gem — install it with:  gem install xcodeproj"
end

proj_path, app_name, plugin_macos = ARGV
abort 'usage: add_helper_target.rb <Runner.xcodeproj> <AppName> <plugin_macos_dir>' unless proj_path && app_name && plugin_macos

helper_name   = "#{app_name} Helper" # base helper (typed siblings add a suffix)
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

# The five CEF macOS helper variants. Mirrors CEF's own CEF_HELPER_APP_SUFFIXES
# (cmake/cef_variables.cmake.in); each row is
# [<app-name suffix>, <Xcode target suffix>, <bundle-id suffix>]. The base ("")
# is what browser_subprocess_path points at; CEF derives the typed siblings'
# paths from it, so all five must be built and embedded.
HELPER_VARIANTS = [
  ['',            '',          ''],
  [' (Alerts)',   '_alerts',   '.alerts'],
  [' (GPU)',      '_gpu',      '.gpu'],
  [' (Plugin)',   '_plugin',   '.plugin'],
  [' (Renderer)', '_renderer', '.renderer'],
].freeze

# --- Helper targets (drop ALL existing first for idempotency) ------------------
# Match the base "Helper" and any typed "Helper_<variant>", so a re-run after the
# single→multi upgrade also cleans up the old lone "Helper" target.
project.targets.select { |t| t.name =~ /\AHelper(_[a-z]+)?\z/ }.each do |old|
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

# The helper source goes in a dedicated "CEF Helper" group (not the project root)
# so it doesn't clutter every consumer's navigator. One shared file reference is
# added to each helper target's compile phase. Drop any stale reference first so
# re-runs don't accumulate orphaned process_helper_main.cc entries.
project.files.select { |f| f.path == helper_src }.each(&:remove_from_project)
helper_group = project.main_group.groups.find { |g| g.display_name == 'CEF Helper' } ||
               project.main_group.new_group('CEF Helper')
src_ref = helper_group.new_file(helper_src)

# Order each helper's build configurations Debug, Profile, Release to match the
# canonical Flutter Runner layout (new_target emits them in a different order).
config_order = { 'Debug' => 0, 'Profile' => 1, 'Release' => 2 }

helpers = HELPER_VARIANTS.map do |name_suffix, target_suffix, id_suffix|
  product_name = "#{helper_name}#{name_suffix}"          # e.g. "openastroara Helper (GPU)"
  helper = project.new_target(:application, "Helper#{target_suffix}", :osx, '10.15')

  helper.build_configurations.each do |c|
    s = c.build_settings
    s['PRODUCT_NAME']                 = product_name
    s['PRODUCT_BUNDLE_IDENTIFIER']    = "#{runner_bundle_id}.helper#{id_suffix}"
    s['INFOPLIST_FILE']               = helper_plist
    s['CODE_SIGN_ENTITLEMENTS']       = helper_ents
    s['MACOSX_DEPLOYMENT_TARGET']     = '10.15'
    s['CLANG_CXX_LANGUAGE_STANDARD']  = 'c++20'
    s['HEADER_SEARCH_PATHS']          = ['$(inherited)', cef_dir]
    s['LIBRARY_SEARCH_PATHS']         = ['$(inherited)', cef_dir]
    # The CEF framework is embedded in the OUTER app's Contents/Frameworks dir.
    # Every helper bundle sits at <App>.app/Contents/Frameworks/<helper>.app, so
    # from each helper executable (<helper>.app/Contents/MacOS/<helper>):
    #   ..       -> Contents/        (of <helper>.app)
    #   ../..    -> <helper>.app/
    #   ../../.. -> <App>.app/Contents/Frameworks/   (where the CEF framework lives)
    # (CefScopedLibraryLoader::LoadInHelper dlopens via a computed path, so this
    # rpath is a belt-and-suspenders fallback — identical for all variants.)
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

  # new_target names the product reference after the target ("Helper_gpu.app"),
  # but PRODUCT_NAME builds "<App> Helper (GPU).app". Align the product reference
  # so the pbxproj is self-consistent and the embedded bundle name matches what
  # CEF derives from the base helper path.
  helper.product_reference.path = "#{product_name}.app"
  helper.build_configuration_list.build_configurations.sort_by! { |c| config_order.fetch(c.name, 99) }

  # xcodeproj's new_target auto-links Cocoa.framework via an SDK-pinned path that
  # hardcodes the build machine's SDK version; the helper links AppKit through
  # OTHER_LDFLAGS instead, so empty each helper's Frameworks phase (the orphaned
  # SDK-pinned file refs are swept globally once, after the loop).
  helper.frameworks_build_phase.files.dup.each(&:remove_from_project)
  helper.source_build_phase.add_file_reference(src_ref)
  helper
end

# Drop every SDK-pinned Cocoa.framework file reference the five new_target calls
# left behind (and any build file still pointing at one) so the project builds on
# any SDK version, plus the empty "OS X" groups new_target creates.
project.objects.select { |o|
  o.isa == 'PBXFileReference' && o.path.to_s =~ %r{/MacOSX[\d.]*\.sdk/.*/Cocoa\.framework\z}
}.each do |ref|
  project.objects.select { |o| o.isa == 'PBXBuildFile' && o.file_ref == ref }.each(&:remove_from_project)
  ref.remove_from_project
end
project.objects.select { |o|
  o.isa == 'PBXGroup' && o.display_name == 'OS X' && o.children.empty?
}.each(&:remove_from_project)

# --- Runner: embed every helper + JIT entitlements + dependencies --------------
helpers.each { |h| runner.add_dependency(h) }

# Copy all five built helper bundles into Runner.app/Contents/Frameworks, signed.
embed = runner.build_phases.find { |p| p.respond_to?(:symbol_dst_subfolder_spec) && p.display_name == 'Embed CEF Helper' }
embed ||= runner.new_copy_files_build_phase('Embed CEF Helper')
embed.symbol_dst_subfolder_spec = :frameworks
embed.files.dup.each { |bf| embed.remove_build_file(bf) }
helpers.each do |h|
  bf = embed.add_file_reference(h.product_reference)
  bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
end

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
    # Pointing CODE_SIGN_ENTITLEMENTS at the plugin's app.entitlements template
    # would bake in a path relative to the plugin's location — fine for a local
    # path dependency, but unresolvable on another machine / CI when the plugin
    # is consumed from the pub cache. Rather than write a fragile path, ask the
    # developer to create their own entitlements file. (Stock Flutter apps ship
    # Runner/Configs/{DebugProfile,Release}.entitlements, so this is rarely hit.)
    abort "  ! #{c.name} has no CODE_SIGN_ENTITLEMENTS. Create a Runner entitlements " \
          "file (e.g. Runner/Release.entitlements), set CODE_SIGN_ENTITLEMENTS to it, " \
          "and add these keys before re-running: " \
          "com.apple.security.cs.allow-jit, allow-unsigned-executable-memory, " \
          "disable-library-validation. (See macos/webview_cef/helper/app.entitlements.)"
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
  # …) and leave only the three CEF keys. read_from_path RAISES (Nanaimo parse
  # error) on a malformed/empty/truncated file rather than returning nil, so catch
  # that and turn it into the same clean abort instead of a raw gem stack trace.
  plist = nil
  parse_error = nil
  begin
    plist = Xcodeproj::Plist.read_from_path(ents_path)
  rescue StandardError => e
    parse_error = e.message
  end
  unless plist.is_a?(Hash)
    abort "  ! could not parse #{ents_path} as a plist (#{c.name})" \
          "#{parse_error ? ": #{parse_error}" : ''}; refusing to overwrite it. " \
          "Merge the JIT entitlements manually."
  end
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
puts "Wired #{helpers.size} '#{helper_name}' helper targets (base + GPU/Renderer/Plugin/Alerts) " \
     "+ embed phase into #{proj_path}"
puts "  note: this grants com.apple.security.cs.disable-library-validation to the " \
     "HOST app (needed to load the separately-signed CEF framework). It relaxes " \
     "dylib-injection protection for the whole host process and is incompatible " \
     "with Mac App Store distribution — fine for Developer-ID. Re-running this " \
     "script regenerates target UUIDs, so commit the result once; don't re-run it " \
     "in a CI 'git diff --exit-code' check."
