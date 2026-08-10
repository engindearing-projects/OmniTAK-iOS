#!/usr/bin/env ruby
#
# Register the Localizable.strings variant group in
# OmniTAK.xcodeproj — one PBXVariantGroup with a child file
# reference per language .lproj, added to the app target's
# resources build phase, plus the language codes in knownRegions.
#
# Idempotent: re-run after adding a new language .lproj and it adds
# only the missing pieces.
#
#     ruby scripts/sync-localization-pbxproj.rb

require 'xcodeproj'
require 'pathname'

ROOT = Pathname.new(__dir__).parent.realpath
PROJ_PATH = ROOT.join('OmniTAK.xcodeproj')
LANGS = %w[en uk pl de fr es]

project = Xcodeproj::Project.open(PROJ_PATH)
app = project.targets.find { |t| t.name == 'OmniTAKMobile' } || project.targets.first
abort 'app target not found' unless app

# --- knownRegions -------------------------------------------------------
LANGS.each do |lang|
  project.root_object.known_regions << lang unless project.root_object.known_regions.include?(lang)
end

# --- Localizable.strings variant group ----------------------------------
resources_group = project.main_group.children.find { |c| c.display_name == 'Resources' } ||
                  project.main_group.new_group('Resources')

# Drop any pre-existing variant group so a re-run is clean.
existing = resources_group.children.find { |c|
  c.is_a?(Xcodeproj::Project::Object::PBXVariantGroup) && c.display_name == 'Localizable.strings'
}
if existing
  app.resources_build_phase.files.dup.each do |bf|
    app.resources_build_phase.remove_build_file(bf) if bf.file_ref == existing
  end
  existing.recursive_children.dup.each { |c| c.remove_from_project rescue nil }
  existing.remove_from_project
end

variant = project.new(Xcodeproj::Project::Object::PBXVariantGroup)
variant.name = 'Localizable.strings'
variant.source_tree = '<group>'
resources_group << variant

LANGS.each do |lang|
  rel = "OmniTAKMobile/Resources/#{lang}.lproj/Localizable.strings"
  abort "missing file: #{rel}" unless ROOT.join(rel).exist?
  ref = project.new(Xcodeproj::Project::Object::PBXFileReference)
  ref.path = rel
  ref.name = lang
  ref.source_tree = '<group>'
  ref.last_known_file_type = 'text.plist.strings'
  variant << ref
end

app.resources_build_phase.add_file_reference(variant)

project.save

puts "registered Localizable.strings variant group:"
LANGS.each { |l| puts "    + #{l}.lproj/Localizable.strings" }
puts "knownRegions: #{project.root_object.known_regions.join(', ')}"
