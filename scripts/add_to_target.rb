#!/usr/bin/env ruby
# Add source files to an Xcode target, mirroring how existing references are
# stored in this project (name = basename, path = path from the project root,
# group tree = folder tree).
#
#   ruby scripts/add_to_target.rb <target> <path/from/project/root.swift>...
#
# Targets: OmniTAKMobile (app), OmniTAKTests (unit tests).
require 'xcodeproj'

target_name = ARGV.shift or abort "usage: add_to_target.rb <target> <file>..."
project = Xcodeproj::Project.open(File.expand_path('../OmniTAK.xcodeproj', __dir__))
target = project.targets.find { |t| t.name == target_name } or abort "no target #{target_name}"

ARGV.each do |rel|
  abort "missing file #{rel}" unless File.exist?(File.expand_path("../#{rel}", __dir__))
  if project.files.find { |f| f.path == rel }
    puts "already referenced: #{rel}"
    next
  end
  # Walk/create groups along the folder path. Groups in this project carry no
  # path of their own (file references hold the full path), so new groups are
  # created the same way.
  group = project.main_group
  File.dirname(rel).split('/').each do |component|
    child = group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && (c.name == component || c.path == component) }
    unless child
      child = group.new_group(component)
      child.path = nil
      child.source_tree = '<group>'
    end
    group = child
  end
  ref = group.new_reference(rel)
  ref.name = File.basename(rel)
  ref.path = rel
  ref.source_tree = '<group>'
  ref.last_known_file_type = 'sourcecode.swift'
  target.add_file_references([ref])
  puts "added #{rel} -> #{target_name}"
end
project.save
