#!/usr/bin/env ruby
# One-off: register AtakDeepLinkExtensionsTests.swift in the
# OmniTAKMobileTests target. Idempotent.
require 'xcodeproj'

project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'OmniTAKMobileTests' } or abort 'tests target not found'

tests_group = project.main_group['OmniTAKMobileTests']
unless tests_group
  tests_group = project.main_group.new_group('OmniTAKMobileTests', nil)
  tests_group.source_tree = '<group>'
end

rel_path = 'OmniTAKMobileTests/AtakDeepLinkExtensionsTests.swift'
basename = File.basename(rel_path)

existing = tests_group.files.find { |f| f.display_name == basename }
unless existing
  file_ref = tests_group.new_reference(rel_path)
  file_ref.last_known_file_type = 'sourcecode.swift'
  target.add_file_references([file_ref])
  puts "Added #{rel_path} to OmniTAKMobileTests target"
else
  puts "#{basename} already referenced"
end

project.save
