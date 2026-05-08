#!/usr/bin/env ruby
# Adds Localizable.strings (en/pl/de/fr) as a single Variant Group to the
# OmniTAKMobile target so Xcode treats them as one localized resource.
# Variant-group children use SOURCE_ROOT so the path is unambiguous.
require 'xcodeproj'

project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'OmniTAKMobile' }
abort 'OmniTAKMobile target not found' unless target

mobile_group = project.main_group.find_subpath('OmniTAKMobile', false)
abort 'OmniTAKMobile group not found' unless mobile_group
resources_group = mobile_group.find_subpath('Resources', false) || mobile_group.new_group('Resources', 'Resources')

# Drop any prior variant group (idempotent).
existing = resources_group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXVariantGroup) && c.display_name == 'Localizable.strings' }
if existing
  target.resources_build_phase.files.dup.each do |bf|
    target.resources_build_phase.remove_build_file(bf) if bf.file_ref == existing
  end
  existing.children.dup.each(&:remove_from_project)
  existing.remove_from_project
end

variant_group = resources_group.new_variant_group('Localizable.strings')
variant_group.set_source_tree('<group>')

%w[en pl de fr].each do |lang|
  file_ref = project.new(Xcodeproj::Project::Object::PBXFileReference)
  file_ref.name = lang
  file_ref.path = "OmniTAKMobile/Resources/#{lang}.lproj/Localizable.strings"
  file_ref.source_tree = 'SOURCE_ROOT'
  file_ref.last_known_file_type = 'text.plist.strings'
  file_ref.include_in_index = '1'
  variant_group.children << file_ref
end

unless target.resources_build_phase.files.any? { |bf| bf.file_ref == variant_group }
  target.resources_build_phase.add_file_reference(variant_group, true)
end

known = project.root_object.known_regions || []
%w[en pl de fr Base].each { |r| known << r unless known.include?(r) }
project.root_object.known_regions = known.uniq
project.root_object.development_region = 'en'

project.save
puts "Localizable.strings variant group ready (#{%w[en pl de fr].length} languages)."
