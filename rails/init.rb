require File.join(File.dirname(__FILE__), '..', 'lib', 'more')

config.after_initialize {
  Less::More.add_source_path File.join(Rails.root, 'app', 'stylesheets') if File.directory?(File.join(Rails.root, 'app', 'stylesheets'))
  Rails.plugins.each do |plugin|
    Less::More.add_source_path File.join(plugin.directory, 'app', 'stylesheets') if File.directory?(File.join(plugin.directory, 'app', 'stylesheets'))
  end
  
  if Less::More.page_cache?
    Less::More.parse 
  else
    Less::More.clean 
  end
}