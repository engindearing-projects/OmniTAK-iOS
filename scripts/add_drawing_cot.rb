#!/usr/bin/env ruby
# Register DrawingCoT.swift in the OmniTAKMobile target and
# DrawingCoTTests.swift in the OmniTAKMobileTests target. Idempotent.
#
# Mirrors the established add_*.rb pattern (e.g. add_config_bundle_fetcher.rb).
require 'xcodeproj'

project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

def ensure_group(parent, name)
  group = parent[name] || parent.new_group(name, nil)
  group.path = nil
  group.source_tree = '<group>'
  group
end

def add_source(group, target, rel_path)
  basename = File.basename(rel_path)
  if group.files.find { |f| f.display_name == basename }
    puts "#{basename} already referenced"
    return
  end
  ref = group.new_reference(rel_path)
  ref.last_known_file_type = 'sourcecode.swift'
  target.add_file_references([ref])
  puts "Added #{rel_path}"
end

# Main target: DrawingCoT.swift under Features/Drawing/Services/
app_target = project.targets.find { |t| t.name == 'OmniTAKMobile' } or
  abort 'OmniTAKMobile target not found'

# Resolve the existing "Features → Drawing → Services" group. The
# project's group hierarchy puts most features under the root
# `Main Group > Features` rather than under `OmniTAKMobile/Features`
# (which is a sibling group that's mostly empty). Probe both.
features = project.main_group['Features'] ||
  project.main_group['OmniTAKMobile']&.send(:[], 'Features') ||
  abort('Features group not found')
drawing = features['Drawing'] || ensure_group(features, 'Drawing')
services = drawing['Services'] || ensure_group(drawing, 'Services')

add_source(
  services,
  app_target,
  'OmniTAKMobile/Features/Drawing/Services/DrawingCoT.swift'
)

# Clean up any stray "Drawing > Services" subgroup the earlier
# revision of this script created under OmniTAKMobile/Features/.
# Empty groups don't fail the build but bloat the navigator.
stray_root = project.main_group['OmniTAKMobile']&.send(:[], 'Features')
if stray_root
  stray_drawing = stray_root['Drawing']
  if stray_drawing
    stray_services = stray_drawing['Services']
    if stray_services && stray_services.files.empty? && stray_services.children.empty?
      stray_services.remove_from_project
    end
    if stray_drawing.files.empty? && stray_drawing.children.empty?
      stray_drawing.remove_from_project
    end
  end
end

# Tests target: optional. The repo currently has an OmniTAKMobileTests/
# directory with test files but no corresponding xcodebuild target — all
# the existing tests live as orphan source. When the unit-test target is
# eventually added (TODO across the repo), this script will pick it up
# without manual intervention.
tests_target = project.targets.find { |t| t.name == 'OmniTAKMobileTests' }
if tests_target.nil?
  puts 'OmniTAKMobileTests target not present — DrawingCoTTests.swift left as orphan source (parity with sibling tests).'
else
  tests_group = project.main_group['OmniTAKMobileTests'] ||
    project.main_group.new_group('OmniTAKMobileTests', nil)
  tests_group.path = nil
  tests_group.source_tree = '<group>'
  add_source(tests_group, tests_target, 'OmniTAKMobileTests/DrawingCoTTests.swift')
end

project.save
puts 'Saved project.'
