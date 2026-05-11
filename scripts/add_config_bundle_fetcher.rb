#!/usr/bin/env ruby
# Register ConfigBundleFetcher.swift in the OmniTAKMobile target.
# Idempotent.
require 'xcodeproj'

project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'OmniTAKMobile' } or abort 'OmniTAKMobile target not found'

mobile_group = project.main_group['OmniTAKMobile'] or abort 'OmniTAKMobile group missing'
features = mobile_group['Features'] || mobile_group.new_group('Features', nil)
features.path = nil; features.source_tree = '<group>'
networking = features['Networking'] || features.new_group('Networking', nil)
networking.path = nil; networking.source_tree = '<group>'
services = networking['Services'] || networking.new_group('Services', nil)
services.path = nil; services.source_tree = '<group>'

rel_path = 'OmniTAKMobile/Features/Networking/Services/ConfigBundleFetcher.swift'
basename = File.basename(rel_path)

existing = services.files.find { |f| f.display_name == basename }
unless existing
  file_ref = services.new_reference(rel_path)
  file_ref.last_known_file_type = 'sourcecode.swift'
  target.add_file_references([file_ref])
  puts "Added #{rel_path} to OmniTAKMobile target"
else
  puts "#{basename} already referenced"
end

project.save
