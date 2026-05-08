#!/usr/bin/env ruby
# Adds the vendored TAKAware files under
# OmniTAKMobile/Features/Military/Vendor/TAKAware/ to the OmniTAKMobile
# target. Idempotent.
require 'xcodeproj'

project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'OmniTAKMobile' }
abort 'OmniTAKMobile target not found' unless target

mobile_group = project.main_group.find_subpath('OmniTAKMobile', false) ||
               project.main_group.new_group('OmniTAKMobile', 'OmniTAKMobile')
features_group = mobile_group.find_subpath('Features', false) ||
                 mobile_group.new_group('Features', 'Features')
military_group = features_group.find_subpath('Military', false) ||
                 features_group.new_group('Military', 'Military')
vendor_group = military_group.find_subpath('Vendor', false) ||
               military_group.new_group('Vendor', 'Vendor')
takaware_group = vendor_group.find_subpath('TAKAware', false) ||
                 vendor_group.new_group('TAKAware', 'TAKAware')

%w[IconData.swift IconsetImporter.swift].each do |basename|
  path = "OmniTAKMobile/Features/Military/Vendor/TAKAware/#{basename}"
  exists = takaware_group.children.any? { |c| c.respond_to?(:path) && c.path == path }
  if exists
    puts "Already in project: #{basename}"
    next
  end
  file_ref = project.new(Xcodeproj::Project::Object::PBXFileReference)
  file_ref.path = path
  file_ref.name = basename
  file_ref.source_tree = 'SOURCE_ROOT'
  file_ref.last_known_file_type = 'sourcecode.swift'
  file_ref.include_in_index = '1'
  takaware_group.children << file_ref

  unless target.source_build_phase.files.any? { |bf| bf.file_ref == file_ref }
    target.source_build_phase.add_file_reference(file_ref, true)
  end
  puts "Added #{basename}"
end

project.save
