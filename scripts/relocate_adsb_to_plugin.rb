#!/usr/bin/env ruby
# One-off: rewrite ADSB file paths in OmniTAKMobile.xcodeproj to their new
# home under plugins/example-adsb-plugin. Then add ADSBPlugin.swift.
require 'xcodeproj'

project_path = File.expand_path('../OmniTAKMobile.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'OmniTAKMobile' } or abort 'OmniTAKMobile target not found'

renames = {
  'OmniTAKMobile/Features/ADSB/Models/ADSBModels.swift'        => 'plugins/example-adsb-plugin/Sources/ADSBPlugin/Models/ADSBModels.swift',
  'OmniTAKMobile/Features/ADSB/Models/AircraftIcons.swift'     => 'plugins/example-adsb-plugin/Sources/ADSBPlugin/Models/AircraftIcons.swift',
  'OmniTAKMobile/Features/ADSB/Services/ADSBTrafficService.swift' => 'plugins/example-adsb-plugin/Sources/ADSBPlugin/Services/ADSBTrafficService.swift',
  'OmniTAKMobile/Features/ADSB/Views/ADSBTrafficView.swift'    => 'plugins/example-adsb-plugin/Sources/ADSBPlugin/Views/ADSBTrafficView.swift',
  'OmniTAKMobile/Features/ADSB/Views/AircraftAnnotation.swift' => 'plugins/example-adsb-plugin/Sources/ADSBPlugin/Views/AircraftAnnotation.swift'
}

project.files.each do |f|
  next if f.path.nil?
  if (new_path = renames[f.path])
    f.path = new_path
    f.source_tree = 'SOURCE_ROOT'
    puts "Repointed #{File.basename(new_path)} -> #{new_path}"
  end
end

# Add ADSBPlugin.swift under a new logical group plugins/example-adsb-plugin.
mobile_group = project.main_group['OmniTAKMobile'] or abort 'OmniTAKMobile group missing'
plugins_group = mobile_group['Plugins'] || mobile_group.new_group('Plugins', nil)
plugins_group.path = nil
plugins_group.source_tree = '<group>'
example_group = plugins_group['ExampleADSBPlugin'] || plugins_group.new_group('ExampleADSBPlugin', nil)
example_group.path = nil
example_group.source_tree = '<group>'

adsb_plugin_path = 'plugins/example-adsb-plugin/Sources/ADSBPlugin/ADSBPlugin.swift'
basename = File.basename(adsb_plugin_path)
example_group.files.select { |f| f.display_name == basename }.each do |existing|
  target.source_build_phase.files.select { |bf| bf.file_ref == existing }.each(&:remove_from_project)
  existing.remove_from_project
end
ref = example_group.new_file(adsb_plugin_path)
ref.name = basename
ref.path = adsb_plugin_path
ref.source_tree = 'SOURCE_ROOT'
target.add_file_references([ref])
puts "Added #{adsb_plugin_path}"

project.save
