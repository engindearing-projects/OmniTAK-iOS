require 'xcodeproj'
p = Xcodeproj::Project.open(File.expand_path('../OmniTAKMobile.xcodeproj', __dir__))
t = p.targets.find { |x| x.name == 'OmniTAKMobile' }
m = p.main_group['OmniTAKMobile']; f = m['Features']; n = f['Networking']; s = n['Services']
[f,n,s].each { |g| g.path=nil; g.source_tree='<group>' } if s
rel='OmniTAKMobile/Features/Networking/Services/TAKRestAPIClient.swift'
if s.files.find { |x| x.display_name=='TAKRestAPIClient.swift' }
  puts 'already referenced'
else
  ref=s.new_reference(rel); ref.last_known_file_type='sourcecode.swift'; t.add_file_references([ref]); puts "Added #{rel}"
end
p.save
