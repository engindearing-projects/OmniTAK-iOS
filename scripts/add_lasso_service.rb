#!/usr/bin/env ruby
# Register the new files introduced for issue #16 (lasso multi-select)
# with the OmniTAKMobile target. Idempotent — safe to re-run.
require 'xcodeproj'

project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'OmniTAKMobile' } or abort 'OmniTAKMobile target not found'

mobile_group = project.main_group['OmniTAKMobile']
features = mobile_group['Features'] || mobile_group.new_group('Features', nil)
features.path = nil; features.source_tree = '<group>'
drawing = features['Drawing'] || features.new_group('Drawing', nil)
drawing.path = nil; drawing.source_tree = '<group>'
services = drawing['Services'] || drawing.new_group('Services', nil)
services.path = nil; services.source_tree = '<group>'
views = drawing['Views'] || drawing.new_group('Views', nil)
views.path = nil; views.source_tree = '<group>'

new_files = {
  services => [
    'OmniTAKMobile/Features/Drawing/Services/LassoSelectionService.swift',
  ],
  views => [
    'OmniTAKMobile/Features/Drawing/Views/LassoSelectionPill.swift',
  ],
}

new_files.each do |group, paths|
  paths.each do |rel|
    basename = File.basename(rel)
    if group.files.find { |f| f.display_name == basename }
      puts "#{basename} already referenced"
      next
    end
    ref = group.new_reference(rel)
    ref.last_known_file_type = 'sourcecode.swift'
    target.add_file_references([ref])
    puts "Added #{rel}"
  end
end

project.save
