#!/usr/bin/env ruby
#
# Sync the MIL-STD SVG asset bundle in OmniTAK.xcodeproj.
#
# Scans `OmniTAKMobile/Shared/Resources/MilStdIcons/*.svg`, removes
# any pbxproj entries for files that no longer exist on disk, and
# adds entries for files present on disk but not yet referenced.
#
# Run after the Android `scripts/milsymbol/generate.mjs` regenerates
# the catalogue and the SVGs have been copied across:
#
#     gem install xcodeproj
#     ruby scripts/sync-milstd-pbxproj.rb

require 'xcodeproj'
require 'pathname'

ROOT = Pathname.new(__dir__).parent.realpath
PROJ_PATH = ROOT.join('OmniTAK.xcodeproj')
ASSETS_DIR = ROOT.join('OmniTAKMobile/Shared/Resources/MilStdIcons')

project = Xcodeproj::Project.open(PROJ_PATH)

# Find the MilStdIcons group.
icons_group = project.main_group.find_subpath(
  'OmniTAKMobile/Shared/Resources/MilStdIcons',
  false
)
abort 'MilStdIcons group not found in project' unless icons_group

target = project.targets.first
abort 'No app target found' unless target
resources_phase = target.resources_build_phase

on_disk = ASSETS_DIR.children.select { |p| p.extname == '.svg' }.map { |p| p.basename.to_s }.sort
in_proj = icons_group.children.select { |c| c.is_a?(Xcodeproj::Project::Object::PBXFileReference) }
              .map(&:path).sort

added = []
removed = []

# Remove project entries for files no longer on disk.
icons_group.children.dup.each do |ref|
  next unless ref.is_a?(Xcodeproj::Project::Object::PBXFileReference)
  next if on_disk.include?(ref.path)
  # Drop any build files referencing this fileRef from the resources phase.
  resources_phase.files.dup.each do |bf|
    resources_phase.remove_build_file(bf) if bf.file_ref == ref
  end
  ref.remove_from_project
  removed << ref.path
end

# Add project entries for files on disk that aren't referenced yet.
(on_disk - in_proj).each do |name|
  file_ref = icons_group.new_reference(name)
  file_ref.last_known_file_type = 'text'
  resources_phase.add_file_reference(file_ref)
  added << name
end

project.save

puts "synced #{ASSETS_DIR.relative_path_from(ROOT)}"
puts "  on-disk:  #{on_disk.size}"
puts "  added:    #{added.size}"
added.first(10).each { |a| puts "    + #{a}" }
puts "    ..." if added.size > 10
puts "  removed:  #{removed.size}"
removed.first(10).each { |r| puts "    - #{r}" }
puts "    ..." if removed.size > 10
