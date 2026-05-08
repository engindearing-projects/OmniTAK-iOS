#!/usr/bin/env ruby
# One-off: ensure OmniTAKMobile/Plugins/Core/*.swift are referenced and
# compiled by the OmniTAKMobile target. Idempotent.
require 'xcodeproj'

project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'OmniTAKMobile' } or abort 'OmniTAKMobile target not found'

mobile_group = project.main_group['OmniTAKMobile'] or abort 'OmniTAKMobile group missing'

# Logical groups (no path) so file paths aren't double-prefixed.
plugins_group = mobile_group['Plugins'] || mobile_group.new_group('Plugins', nil)
plugins_group.path = nil
plugins_group.source_tree = '<group>'

core_group = plugins_group['Core'] || plugins_group.new_group('Core', nil)
core_group.path = nil
core_group.source_tree = '<group>'

files = [
  'OmniTAKMobile/Plugins/Core/OmniTAKPlugin.swift',
  'OmniTAKMobile/Plugins/Core/PluginRegistry.swift',
  'OmniTAKMobile/Plugins/Core/BundledPlugins.swift'
]

files.each do |rel_path|
  basename = File.basename(rel_path)

  # Remove any prior file refs with this name from the core group.
  core_group.files.select { |f| f.display_name == basename }.each do |existing|
    target.source_build_phase.files.select { |bf| bf.file_ref == existing }.each(&:remove_from_project)
    existing.remove_from_project
  end

  ref = core_group.new_file(rel_path)
  ref.name = basename
  ref.path = rel_path
  ref.source_tree = 'SOURCE_ROOT'
  target.add_file_references([ref])
  puts "Wired #{rel_path}"
end

project.save
