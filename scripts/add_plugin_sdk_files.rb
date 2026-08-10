#!/usr/bin/env ruby
# Adds the Plugin SDK source files to the correct Xcode targets.
# Idempotent — safe to run multiple times.
require 'xcodeproj'

project_path = File.expand_path('../OmniTAK.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

app_target  = project.targets.find { |t| t.name == 'OmniTAKMobile' }
test_target = project.targets.find { |t| t.name == 'OmniTAKMobileTests' }
abort('Could not find OmniTAKMobile target')  unless app_target
abort('Could not find OmniTAKMobileTests target') unless test_target

main_group = project.main_group

# path (relative to project root) => target
app_files = [
  'OmniTAKMobile/Core/Plugin/OmniTAKPlugin.swift',
  'OmniTAKMobile/Core/Plugin/PluginHost.swift',
  'OmniTAKMobile/Core/Plugin/PluginRegistry.swift',
  'OmniTAKMobile/Core/Plugin/AppPluginHost.swift',
  'OmniTAKMobile/Core/Plugin/DiagnosticsPlugin.swift',
  'OmniTAKMobile/Features/ADSB/Plugin/ADSBPlugin.swift',
  'OmniTAKMobile/Features/ADSB/Plugin/ADSBStatusOverlay.swift',
]
test_files = [
  'OmniTAKMobileTests/PluginSDKTests.swift',
]

def file_ref_for(project, main_group, path)
  # Find an existing flat file reference by path, else create one.
  existing = project.files.find { |f| f.path == path }
  return existing if existing
  ref = main_group.new_reference(path)
  ref.name = File.basename(path)
  ref
end

def ensure_in_target(target, ref, path)
  already = target.source_build_phase.files.any? do |bf|
    bf.file_ref && bf.file_ref.path == path
  end
  if already
    puts "  = #{path} already in #{target.name}"
  else
    target.add_file_references([ref])
    puts "  + #{path} -> #{target.name}"
  end
end

puts 'Adding app-target files:'
app_files.each do |path|
  ref = file_ref_for(project, main_group, path)
  ensure_in_target(app_target, ref, path)
end

puts 'Adding test-target files:'
test_files.each do |path|
  ref = file_ref_for(project, main_group, path)
  ensure_in_target(test_target, ref, path)
end

project.save
puts 'Saved project.'
