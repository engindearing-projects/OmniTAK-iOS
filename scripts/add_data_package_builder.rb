#!/usr/bin/env ruby
# Register DataPackageBuilder.swift + DataPackageZip.swift in the
# Services group and DataPackageBuilderView.swift in the Views group
# of the existing DataPackages feature. Idempotent — safe to re-run.
#
# Closes issue #15 (in-app data package authoring) — K9Blue SAR
# feedback 5/10/26.
require 'xcodeproj'

project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'OmniTAKMobile' } or abort 'OmniTAKMobile target not found'

mobile_group = project.main_group['OmniTAKMobile']
features = mobile_group['Features'] || mobile_group.new_group('Features', nil)
features.path = nil; features.source_tree = '<group>'
dp = features['DataPackages'] || features.new_group('DataPackages', nil)
dp.path = nil; dp.source_tree = '<group>'
services = dp['Services'] || dp.new_group('Services', nil)
services.path = nil; services.source_tree = '<group>'
views = dp['Views'] || dp.new_group('Views', nil)
views.path = nil; views.source_tree = '<group>'

mapping = {
  services => [
    'OmniTAKMobile/Features/DataPackages/Services/DataPackageBuilder.swift',
    'OmniTAKMobile/Features/DataPackages/Services/DataPackageZip.swift',
  ],
  views => [
    'OmniTAKMobile/Features/DataPackages/Views/DataPackageBuilderView.swift',
  ]
}

mapping.each do |group, files|
  files.each do |rel|
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
end

project.save
puts "Saved #{project_path}"
