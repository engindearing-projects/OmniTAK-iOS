#!/usr/bin/env ruby
# Register QuickMarkService.swift in the OmniTAKMobile target.
# Idempotent — safe to re-run.
require 'xcodeproj'

project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'OmniTAKMobile' } or abort 'OmniTAKMobile target not found'

mobile_group = project.main_group['OmniTAKMobile']
features = mobile_group['Features'] || mobile_group.new_group('Features', nil)
features.path = nil; features.source_tree = '<group>'
map = features['Map'] || features.new_group('Map', nil)
map.path = nil; map.source_tree = '<group>'
services = map['Services'] || map.new_group('Services', nil)
services.path = nil; services.source_tree = '<group>'

files = [
  'OmniTAKMobile/Features/Map/Services/QuickMarkService.swift',
]

files.each do |rel|
  basename = File.basename(rel)
  unless services.files.find { |f| f.display_name == basename }
    ref = services.new_reference(rel)
    ref.last_known_file_type = 'sourcecode.swift'
    target.add_file_references([ref])
    puts "Added #{rel}"
  else
    puts "#{basename} already referenced"
  end
end

project.save
