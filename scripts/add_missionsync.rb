#!/usr/bin/env ruby
# Register the multi-server Mission Sync files (#10) with the OmniTAKMobile
# target. Idempotent.
require 'xcodeproj'
project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'OmniTAKMobile' } or abort 'target not found'

mobile = project.main_group['OmniTAKMobile']
features = mobile['Features'] || mobile.new_group('Features', nil)
dp = features['DataPackages'] || features.new_group('DataPackages', nil)
services = dp['Services'] || dp.new_group('Services', nil)
views = dp['Views'] || dp.new_group('Views', nil)
[features, dp, services, views].each { |g| g.path = nil; g.source_tree = '<group>' }

new_files = {
  services => ['OmniTAKMobile/Features/DataPackages/Services/MissionSyncManager.swift'],
  views    => ['OmniTAKMobile/Features/DataPackages/Views/MissionSyncView.swift'],
}
new_files.each do |group, paths|
  paths.each do |rel|
    base = File.basename(rel)
    if group.files.find { |f| f.display_name == base }
      puts "#{base} already referenced"; next
    end
    ref = group.new_reference(rel)
    ref.last_known_file_type = 'sourcecode.swift'
    target.add_file_references([ref])
    puts "Added #{rel}"
  end
end
project.save
puts "saved."
