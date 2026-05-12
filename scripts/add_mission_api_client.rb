#!/usr/bin/env ruby
# Register MissionAPIClient.swift + MissionCreateView.swift in the
# OmniTAKMobile target under the existing Features/Mission group.
# Idempotent — safe to re-run. Mirrors add_mission_exporter.rb.
require 'xcodeproj'

project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'OmniTAKMobile' } or abort 'OmniTAKMobile target not found'

mobile_group = project.main_group['OmniTAKMobile']
features = mobile_group['Features'] || mobile_group.new_group('Features', nil)
features.path = nil; features.source_tree = '<group>'
mission = features['Mission'] || features.new_group('Mission', nil)
mission.path = nil; mission.source_tree = '<group>'

files = [
  'OmniTAKMobile/Features/Mission/MissionAPIClient.swift',
  'OmniTAKMobile/Features/Mission/MissionCreateView.swift',
]

files.each do |rel|
  basename = File.basename(rel)
  unless mission.files.find { |f| f.display_name == basename }
    ref = mission.new_reference(rel)
    ref.last_known_file_type = 'sourcecode.swift'
    target.add_file_references([ref])
    puts "Added #{rel}"
  else
    puts "#{basename} already referenced"
  end
end

project.save
