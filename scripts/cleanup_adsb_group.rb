#!/usr/bin/env ruby
# One-off: move ADSB file references from the now-stale Features/ADSB
# group into Plugins/ExampleADSBPlugin so the Xcode navigator matches
# the on-disk layout.
require 'xcodeproj'

project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

mobile_group = project.main_group['OmniTAKMobile'] or abort 'OmniTAKMobile group missing'
features_group = mobile_group['Features']
adsb_group = features_group && features_group['ADSB']
exit 0 unless adsb_group

plugins_group = mobile_group['Plugins'] || mobile_group.new_group('Plugins', nil)
example_group = plugins_group['ExampleADSBPlugin'] || plugins_group.new_group('ExampleADSBPlugin', nil)
example_group.path = nil
example_group.source_tree = '<group>'

# Recursively collect file references inside the stale ADSB group, move
# each into the example group, then delete the empty subgroups.
def collect_refs(group)
  refs = group.files.dup
  group.groups.each { |g| refs.concat(collect_refs(g)) }
  refs
end

refs = collect_refs(adsb_group)
refs.each do |ref|
  ref.move(example_group)
  puts "Moved #{File.basename(ref.path)} into Plugins/ExampleADSBPlugin"
end

# Remove the now-empty ADSB tree.
adsb_group.recursive_children_groups.each(&:remove_from_project)
adsb_group.remove_from_project

project.save
