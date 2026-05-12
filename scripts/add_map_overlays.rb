#!/usr/bin/env ruby
# Register the Issue #17 map overlay sources in the OmniTAKMobile target.
# Idempotent. Mirrors add_drawing_cot.rb / add_config_bundle_fetcher.rb.
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

app_target = project.targets.find { |t| t.name == 'OmniTAKMobile' } or
  abort 'OmniTAKMobile target not found'

features = project.main_group['Features'] ||
  project.main_group['OmniTAKMobile']&.send(:[], 'Features') ||
  abort('Features group not found')
map = features['Map'] || ensure_group(features, 'Map')
overlays = map['Overlays'] || ensure_group(map, 'Overlays')

add_source(overlays, app_target,
           'OmniTAKMobile/Features/Map/Overlays/MapOverlayDescriptor.swift')
add_source(overlays, app_target,
           'OmniTAKMobile/Features/Map/Overlays/MapOverlayManager.swift')
add_source(overlays, app_target,
           'OmniTAKMobile/Features/Map/Overlays/MapOverlaysListView.swift')

# KMLOverlayRenderer lives under Utilities/Integration with the existing
# KMLOverlayManager + KMLMapIntegration files.
utilities = project.main_group['Utilities'] ||
  project.main_group['OmniTAKMobile']&.send(:[], 'Utilities') ||
  abort('Utilities group not found')
integration = utilities['Integration'] || ensure_group(utilities, 'Integration')
add_source(integration, app_target,
           'OmniTAKMobile/Utilities/Integration/KMLOverlayRenderer.swift')

# Tests target intentionally skipped — no PBXNativeTarget yet.
tests_target = project.targets.find { |t| t.name == 'OmniTAKMobileTests' }
if tests_target.nil?
  puts 'OmniTAKMobileTests target not present — KMLOverlayRendererTests.swift left as orphan source (parity with sibling tests).'
else
  tests_group = project.main_group['OmniTAKMobileTests'] ||
    project.main_group.new_group('OmniTAKMobileTests', nil)
  tests_group.path = nil
  tests_group.source_tree = '<group>'
  add_source(tests_group, tests_target,
             'OmniTAKMobileTests/KMLOverlayRendererTests.swift')
end

project.save
puts 'Saved project.'
