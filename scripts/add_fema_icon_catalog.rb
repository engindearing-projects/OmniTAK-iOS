#!/usr/bin/env ruby
# Register the FEMA / IC symbology files (issue #13) in the OmniTAKMobile target.
# Idempotent — safe to re-run.
require 'xcodeproj'

project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'OmniTAKMobile' } or abort 'OmniTAKMobile target not found'

mobile_group = project.main_group['OmniTAKMobile']

# --- Shared/Services/FEMAIconCatalog.swift ---
shared = mobile_group['Shared'] || mobile_group.new_group('Shared', nil)
shared.path = nil; shared.source_tree = '<group>'
services = shared['Services'] || shared.new_group('Services', nil)
services.path = nil; services.source_tree = '<group>'

# --- Features/Drawing/Views/FEMAMarkerPaletteView.swift ---
features = mobile_group['Features'] || mobile_group.new_group('Features', nil)
features.path = nil; features.source_tree = '<group>'
drawing = features['Drawing'] || features.new_group('Drawing', nil)
drawing.path = nil; drawing.source_tree = '<group>'
views = drawing['Views'] || drawing.new_group('Views', nil)
views.path = nil; views.source_tree = '<group>'

mappings = [
  [services, 'OmniTAKMobile/Shared/Services/FEMAIconCatalog.swift'],
  [views,    'OmniTAKMobile/Features/Drawing/Views/FEMAMarkerPaletteView.swift'],
]

mappings.each do |group, rel|
  basename = File.basename(rel)
  unless group.files.find { |f| f.display_name == basename }
    ref = group.new_reference(rel)
    ref.last_known_file_type = 'sourcecode.swift'
    target.add_file_references([ref])
    puts "Added #{rel}"
  else
    puts "#{basename} already referenced"
  end
end

project.save
