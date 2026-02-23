require 'xcodeproj'

project_path = 'CameraSamsung.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

file_path = 'CameraSamsung/1-second-of-silence.mp3'
group = project.main_group.find_subpath('CameraSamsung', true)
file_reference = group.new_reference(file_path)

target.resources_build_phase.add_file_reference(file_reference)

project.save
puts "Added #{file_path} to Resources Build Phase of #{target.name}"
