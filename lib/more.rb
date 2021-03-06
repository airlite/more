# Less::More provides methods for parsing LESS files in a rails application to CSS target files.
# 
# When Less::More.parse is called, all files in Less::More.source_paths will be parsed using LESS
# and saved as CSS files in Less::More.destination_path. If Less::More.compression is set to true,
# extra line breaks will be removed to compress the CSS files.
#
# By default, Less::More.parse will be called for each request in `development` environment and on
# application initialization in `production` environment.

begin
  require 'less'
rescue LoadError => e
  e.message << " (You may need to install the less gem)"
  raise e
end

class Less::More
  DEFAULTS = {
    "production" => {
      :compression        => true,
      :header             => false,
      :destination_path   => "stylesheets"
    },
    "development" => {
      :compression        => false,
      :header             => true,
      :destination_path   => "stylesheets"
    }
  }
  
  HEADER = %{/*\n\n\n\n\n\tThis file was auto generated by Less (http://lesscss.org). To change the contents of this file, edit %s instead.\n\n\n\n\n*/}
  
  class << self
    attr_writer :compression, :header, :page_cache, :destination_path
    
    # Returns true if compression is enabled. By default, compression is enabled in the production environment
    # and disabled in the development and test environments. This value can be changed using:
    #
    #   Less::More.compression = true
    #
    # You can put this line into config/environments/development.rb to enable compression for the development environments
    def compression?
      get_cvar(:compression)
    end

    # Check wether or not we should page cache the generated CSS
    def page_cache?
      (not heroku?) && page_cache_enabled_in_environment_configuration?
    end
    
    # For easy mocking.
    def page_cache_enabled_in_environment_configuration?
      Rails.configuration.action_controller.perform_caching
    end
    
    # Tells the plugin to prepend HEADER to all generated CSS, informing users
    # opening raw .css files that the file is auto-generated and that the
    # .less file should be edited instead.
    #
    #    Less::More.header = false
    def header?
      get_cvar(:header)
    end
    
    # The path, or route, where you want your .css files to live.
    def destination_path
      get_cvar(:destination_path)
    end
    
    # Gets user set values or DEFAULTS. User set values gets precedence.
    def get_cvar(cvar)
      instance_variable_get("@#{cvar}") || (DEFAULTS[Rails.env] || DEFAULTS["production"])[cvar]
    end
    
    # Returns true if the app is running on Heroku. When +heroku?+ is true,
    # +page_cache?+ will always be false.
    def heroku?
      ENV.any? {|key, value| key =~ /^heroku/i }
    end
    
    # Returns the LESS source paths, see `add_source_path`
    def source_paths
      @source_paths ||= Array.new
    end
    
    # add a source path for LESS files. This directory will be scanned recursively for all *.less files. Files prefixed
    # with an underscore is considered to be partials and are not parsed directly. These files can be included using `@import`
    # statements. *Example partial filename: _form.less*
    #
    # Default value is app/stylesheets
    #
    # Examples:
    #   Less::More.add_source_path "/path/to/less/files"
    #   Less::More.add_source_path Pathname.new("/other/path")
    def add_source_path(path)
      path = Pathname.new(path.to_s)
      @source_paths ||= Array.new
      @source_paths << path unless @source_paths.include?(path)
    end

    # for backwards compatability
    def source_path=(path)
      @source_paths.clear if @source_paths
      add_source_path path
    end
    
    # Checks if a .less or .lss file exists in Less::More.source_paths matching
    # the given parameters.
    #
    #   Less::More.exists?(["screen"])
    #   Less::More.exists?(["subdirectories", "here", "homepage"])
    def exists?(path_as_array)
      return false if path_as_array[-1].starts_with?("_")
      
      pathname = pathname_from_array(path_as_array)
      pathname && pathname.exist?
    end
    
    def cache_path
      File.join(Rails.root, 'tmp', 'less-cache')
    end
            
    # Generates the .css from a .less or .lss file in Less::More.source_paths matching
    # the given parameters.
    #
    #   Less::More.generate(["screen"])
    #   Less::More.generate(["subdirectories", "here", "homepage"])
    #
    # Returns the CSS as a string.
    def generate(path_as_array)
      source = pathname_from_array(path_as_array)
      
      # put together our destination dir and path (need dir so we can create subdirectories)
      destination_dir = File.join(cache_path.to_s, *path_as_array[0...-1])
      destination = File.join(destination_dir, source.basename.to_s.gsub('.less', '.css').gsub('.lss', '.css'))
      
      # check if the destination file exists, and compare the modified times to see if it needs to be written
      if self.page_cache_enabled_in_environment_configuration? && File.exists?(destination) and File.new(destination).mtime >= File.new(source).mtime
        # cached destination file is the same as the source, just return the cached file
        css = File.read(destination)
      else
        # cached file doesn't exist or it's out of date
        if source.extname == ".css"
          # vanilla css
          css = File.read(source)
        else
          # less or lss file, compile it
          engine = File.open(source) {|f| Less::Engine.new(f) }
          css = engine.to_css
          css.delete!("\n") if self.compression?
          css = (HEADER % [source.to_s]) << css if self.header?
        end
        
        if self.page_cache_enabled_in_environment_configuration?
          # make sure the appropriate cache directory exists
          FileUtils.mkdir_p destination_dir
          # write the css to our cache directory
          File.open(destination, "w") {|f|
            f.puts css
          }
        end
      end

      # return the css
      css
    end
    
    # Generates all the .css files.
    def parse
      source_paths.each do |source_path|
        Less::More.all_less_files(source_path).each do |path|
          # Get path
          relative_path = path.relative_path_from(source_path)
          path_as_array = relative_path.to_s.split(File::SEPARATOR)
          path_as_array[-1] = File.basename(path_as_array[-1], File.extname(path_as_array[-1]))

          # Generate CSS
          css = Less::More.generate(path_as_array)

          # Store CSS
          path_as_array[-1] = path_as_array[-1] + ".css"
          # if it's in a plugin, put it under plugin_assets/<plugin>/<destination_path>
          rails_relative_path = path.relative_path_from(Rails.root)
          destination = if rails_relative_path.to_s.start_with?(File.join('vendor', 'plugins'))
            plugin_name = path.relative_path_from(Rails.root.join('vendor', 'plugins')).to_s.split('/').first
            Pathname.new(File.join(Rails.root, "public", 'plugin_assets', plugin_name, Less::More.destination_path)).join(*path_as_array)
          else
            Pathname.new(File.join(Rails.root, "public", Less::More.destination_path)).join(*path_as_array)
          end
          
          if !destination.exist? || source_path.ctime > destination.ctime
            puts "writing #{destination}"
            destination.dirname.mkpath
            File.open(destination, "w") { |f| f.puts css }
          end
        end
      end
    end
    
    # Removes all generated css files.
    def clean
      source_paths.each do |source_path|
        all_less_files(source_path).each do |path|
          relative_path = path.relative_path_from(source_path)
          css_path = relative_path.to_s.sub(/(le?|c)ss$/, "css")
          path_as_array = css_path.to_s.split(File::SEPARATOR)
          rails_relative_path = path.relative_path_from(Rails.root)
          
          css_file = if rails_relative_path.to_s.start_with?(File.join('vendor', 'plugins'))
            plugin_name = path.relative_path_from(Rails.root.join('vendor', 'plugins')).to_s.split('/').first
            Pathname.new(File.join(Rails.root, "public", 'plugin_assets', plugin_name, Less::More.destination_path)).join(*path_as_array)
          else
            Pathname.new(File.join(Rails.root, "public", Less::More.destination_path)).join(*path_as_array)
          end
          if css_file.exist?
            puts "deleting #{css_file}"
            css_file.delete
          end
        end
      end
    end
    
    # Array of Pathname instances for all the less source files.
    def all_less_files(paths = source_paths)
      [paths].flatten.collect do |path|
        Dir[path.join("**", "*.{css,less,lss}").to_s].map! { |f| Pathname.new(f) }
      end.flatten.find_all { |path| !path.basename.to_s.start_with?('_') }
    end
    
    # Converts ["foo", "bar"] into a `Pathname` based on Less::More.source_paths.
    def pathname_from_array(array)
      path_spec = array.dup
      path_spec[-1] = path_spec[-1] + ".{css,less,lss}"
      source_paths.each do |source_path|
        path = Pathname.glob(File.join(source_path.to_s, *path_spec))[0]
        return path if path && path.exist?
      end
      Pathname.glob(File.join(source_paths.first.to_s, *path_spec))[0]
    end
  end
end
