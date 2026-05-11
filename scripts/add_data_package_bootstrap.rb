#!/usr/bin/env ruby
# One-off: register DataPackageBootstrap.swift in the OmniTAKMobile target.
# Idempotent.
require 'xcodeproj'

project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'OmniTAKMobile' } or abort 'OmniTAKMobile target not found'

mobile_group = project.main_group['OmniTAKMobile'] or abort 'OmniTAKMobile group missing'
features = mobile_group['Features'] || mobile_group.new_group('Features', nil)
features.path = nil; features.source_tree = '<group>'

datapkg = features['DataPackages'] || features.new_group('DataPackages', nil)
datapkg.path = nil; datapkg.source_tree = '<group>'

services = datapkg['Services'] || datapkg.new_group('Services', nil)
services.path = nil; services.source_tree = '<group>'

rel_path = 'OmniTAKMobile/Features/DataPackages/Services/DataPackageBootstrap.swift'
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
