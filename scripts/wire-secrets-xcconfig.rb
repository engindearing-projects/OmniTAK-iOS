#!/usr/bin/env ruby
#
# Wire Config.base.xcconfig (committed) as the baseConfigurationReference for
# the app target's Debug + Release build configs, so Xcode substitutes
# $(MBX_ACCESS_TOKEN) and $(DEFAULT_P12_PASSWORD) into Info.plist at build.
#
# Config.base.xcconfig ships empty defaults so fresh checkouts build, and
# optionally `#include?`s Config.xcconfig (gitignored) for real secret values.
#
# Idempotent: re-run safely.
#
#     ruby scripts/wire-secrets-xcconfig.rb

require 'xcodeproj'
require 'pathname'

ROOT = Pathname.new(__dir__).parent.realpath
PROJ_PATH = ROOT.join('OmniTAK.xcodeproj')
XCCONFIG_NAME = 'Config.base.xcconfig'

project = Xcodeproj::Project.open(PROJ_PATH)

# 1. File reference at project root (no group nesting — top level)
existing_ref = project.main_group.files.find { |f| f.display_name == XCCONFIG_NAME }
xc_ref = existing_ref || project.main_group.new_file(XCCONFIG_NAME)
xc_ref.last_known_file_type = 'text.xcconfig'
puts "file reference: #{xc_ref.uuid} (#{existing_ref ? 'existing' : 'created'})"

# 2. Set baseConfigurationReference on the app target's Debug + Release
app = project.targets.find { |t| t.name == 'OmniTAKMobile' } or abort 'app target not found'
%w[Debug Release].each do |name|
  bc = app.build_configurations.find { |c| c.name == name } or next
  bc.base_configuration_reference = xc_ref
  puts "target OmniTAKMobile/#{name}: baseConfigurationReference -> Config.xcconfig"
end

# 3. Also set on the project-level configs so Xcode's variable resolution sees them
%w[Debug Release].each do |name|
  bc = project.build_configurations.find { |c| c.name == name } or next
  bc.base_configuration_reference = xc_ref
  puts "project/#{name}: baseConfigurationReference -> Config.xcconfig"
end

project.save
puts "saved."
