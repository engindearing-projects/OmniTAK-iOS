#!/usr/bin/env ruby
# Wire the Ditto peer-to-peer mesh into the Xcode project:
#   1. add the DittoSwiftPackage SPM dependency (pinned exactly)
#   2. link the DittoSwift product into the app target
#   3. register the new Swift sources with the OmniTAK target
#
# Pinned to an EXACT version on purpose. Ditto peers must run compatible
# protocol versions to sync, and OmniTAK ships on two platforms that have to
# mesh with each other — so iOS and Android move together, deliberately, rather
# than drifting apart on an "up to next major" rule.
#
# Idempotent — safe to re-run.
require 'xcodeproj'

DITTO_REPO    = 'https://github.com/getditto/DittoSwiftPackage'
DITTO_VERSION = '5.0.3'
DITTO_PRODUCT = 'DittoSwift'

project_path = File.expand_path('../OmniTAK.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'OmniTAK' } or abort 'OmniTAK target not found'

# ---------------------------------------------------------------- SPM package
pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:repositoryURL) && r.repositoryURL == DITTO_REPO
end

if pkg
  puts "= package already referenced (#{DITTO_REPO})"
else
  pkg = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  pkg.repositoryURL = DITTO_REPO
  pkg.requirement = { 'kind' => 'exactVersion', 'version' => DITTO_VERSION }
  project.root_object.package_references << pkg
  puts "+ added package #{DITTO_REPO} @ #{DITTO_VERSION}"
end

# Keep the pin honest even if the package was added by hand at another version.
if pkg.requirement != { 'kind' => 'exactVersion', 'version' => DITTO_VERSION }
  pkg.requirement = { 'kind' => 'exactVersion', 'version' => DITTO_VERSION }
  puts "~ repinned to exactVersion #{DITTO_VERSION}"
end

# ------------------------------------------------------------- product -> target
dep = target.package_product_dependencies.find { |d| d.product_name == DITTO_PRODUCT }
unless dep
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = DITTO_PRODUCT
  dep.package = pkg
  target.package_product_dependencies << dep
  puts "+ linked product #{DITTO_PRODUCT}"
else
  puts "= product #{DITTO_PRODUCT} already linked"
end

# The product also needs a build file in the Frameworks phase, or it resolves
# but never links and every `import DittoSwift` fails at compile time.
frameworks = target.frameworks_build_phase
already = frameworks.files.any? { |f| f.product_ref && f.product_ref.product_name == DITTO_PRODUCT }
unless already
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  frameworks.files << bf
  puts "+ added #{DITTO_PRODUCT} to Frameworks build phase"
else
  puts "= #{DITTO_PRODUCT} already in Frameworks build phase"
end

# ----------------------------------------------------------------- source files
# Features lives at the project root, not under an OmniTAKMobile group — the
# target was renamed to OmniTAK and the group tree flattened with it.
features = project.main_group['Features'] || project.main_group.new_group('Features', nil)
features.path = nil; features.source_tree = '<group>'
mesh = features['Mesh'] || features.new_group('Mesh', nil)
mesh.path = nil; mesh.source_tree = '<group>'
services = mesh['Services'] || mesh.new_group('Services', nil)
services.path = nil; services.source_tree = '<group>'
views = mesh['Views'] || mesh.new_group('Views', nil)
views.path = nil; views.source_tree = '<group>'

new_files = {
  services => ['OmniTAKMobile/Features/Mesh/Services/DittoMeshService.swift'],
  views    => ['OmniTAKMobile/Features/Mesh/Views/DittoMeshSettingsView.swift']
}

new_files.each do |group, paths|
  paths.each do |rel|
    abs = File.expand_path("../#{rel}", __dir__)
    unless File.exist?(abs)
      puts "! missing on disk, skipping: #{rel}"
      next
    end
    basename = File.basename(rel)
    existing = group.files.find { |f| f.display_name == basename }
    ref = existing || group.new_reference(abs)
    ref.source_tree = '<group>'
    if target.source_build_phase.files_references.include?(ref)
      puts "= #{basename} already in target"
    else
      target.add_file_references([ref])
      puts "+ #{basename}"
    end
  end
end

project.save
puts "saved #{project_path}"
