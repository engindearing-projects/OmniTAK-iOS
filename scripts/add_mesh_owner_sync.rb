#!/usr/bin/env ruby
# Register MeshOwnerNames.swift + MeshOwnerSync.swift in the OmniTAKMobile target.
# Idempotent.
require 'xcodeproj'

project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'OmniTAKMobile' } or abort 'OmniTAKMobile target not found'

mobile_group = project.main_group['OmniTAKMobile']
features = mobile_group['Features'] || mobile_group.new_group('Features', nil)
features.path = nil; features.source_tree = '<group>'
mesh = features['Meshtastic'] || features.new_group('Meshtastic', nil)
mesh.path = nil; mesh.source_tree = '<group>'
services = mesh['Services'] || mesh.new_group('Services', nil)
services.path = nil; services.source_tree = '<group>'

files = [
  'OmniTAKMobile/Features/Meshtastic/Services/MeshOwnerNames.swift',
  'OmniTAKMobile/Features/Meshtastic/Services/MeshOwnerSync.swift',
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
