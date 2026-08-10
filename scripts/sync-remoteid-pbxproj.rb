#!/usr/bin/env ruby
#
# Register the RemoteID feature's Swift sources in OmniTAK.xcodeproj.
#
# Run once after adding files under
# `OmniTAKMobile/Features/RemoteID/{Models,Services}` and
# `OmniTAKMobileTests/`. Idempotent: re-runs add any new files
# and leave existing references untouched.
#
#     gem install xcodeproj   # if not already installed
#     ruby scripts/sync-remoteid-pbxproj.rb

require 'xcodeproj'
require 'pathname'

ROOT = Pathname.new(__dir__).parent.realpath
PROJ_PATH = ROOT.join('OmniTAK.xcodeproj')

project = Xcodeproj::Project.open(PROJ_PATH)

app_target = project.targets.find { |t| t.name == 'OmniTAKMobile' } || project.targets.first
test_target = project.targets.find { |t| t.name == 'OmniTAKMobileTests' }
abort 'app target not found' unless app_target

# ---- App-target sources: OmniTAKMobile/Features/RemoteID/**/*.swift -----

feature_root = ROOT.join('OmniTAKMobile/Features/RemoteID')
feature_files = Dir.glob(feature_root.join('**/*.swift')).map { |p| Pathname.new(p) }

# Make sure the group hierarchy exists under
# main_group → OmniTAKMobile → Features → RemoteID → {Models,Services}.
features_group = project.main_group.find_subpath('OmniTAKMobile/Features', true)
remote_id_group = features_group.children.find { |c| c.display_name == 'RemoteID' } ||
                  features_group.new_group('RemoteID', 'RemoteID')

existing_paths = remote_id_group.recursive_children.select { |c|
  c.is_a?(Xcodeproj::Project::Object::PBXFileReference)
}.map { |c| ROOT.join(c.real_path).cleanpath }.to_set

added_app = []
feature_files.each do |path|
  next if existing_paths.include?(path.cleanpath)

  # Pick the right subgroup based on the source folder name.
  subname = path.parent.basename.to_s
  subgroup = remote_id_group.children.find { |c| c.display_name == subname } ||
             remote_id_group.new_group(subname, subname)

  rel = path.relative_path_from(ROOT.join('OmniTAKMobile/Features/RemoteID').join(subname))
  ref = subgroup.new_reference(rel.to_s)
  app_target.source_build_phase.add_file_reference(ref)
  added_app << path.basename.to_s
end

# ---- Test target: OmniTAKMobileTests/*RemoteId*Tests.swift ---------------

added_tests = []
if test_target
  tests_group = project.main_group.find_subpath('OmniTAKMobileTests', true)
  test_files = Dir.glob(ROOT.join('OmniTAKMobileTests/*RemoteId*Tests.swift')) +
               Dir.glob(ROOT.join('OmniTAKMobileTests/*OpenDroneId*Tests.swift'))
  existing_test_paths = tests_group.children.select { |c|
    c.is_a?(Xcodeproj::Project::Object::PBXFileReference)
  }.map { |c| ROOT.join(c.real_path).cleanpath }.to_set

  test_files.map { |p| Pathname.new(p) }.each do |path|
    next if existing_test_paths.include?(path.cleanpath)
    ref = tests_group.new_reference(path.basename.to_s)
    test_target.source_build_phase.add_file_reference(ref)
    added_tests << path.basename.to_s
  end
end

project.save

puts "added #{added_app.size} app source(s):"
added_app.each { |n| puts "    + #{n}" }
puts "added #{added_tests.size} test source(s):"
added_tests.each { |n| puts "    + #{n}" }
