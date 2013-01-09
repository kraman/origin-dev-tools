require 'thor'
require 'lib/openshift/tito'

module Origin
  module BuildHelper
    include Tito
    # Given a list of RPMs, install then if they are not already installed locally
    #
    # @param list [Array] List of RPM names to install
    # @param skip_broken [Boolean] Ignore RPMs that cannot be installed
    # @return [Array] List of installed RPMs
    def install_rpms(list,skip_broken=false)
      list = list - verify_rpms(list)
      args = ""
      args = "--skip-broken" if skip_broken
      list.map!{ |rpm| "'#{rpm}'"}
      unless list.empty?
        if run "yum install -y #{args} #{list.join(" ")}" 
          list
        else
          raise "Unable to install required packages"
        end
      else
        []
      end
    end
    
    # Given a list of RPMs, un-install then if they are installed locally
    #
    # @param list [Array] List of RPM names to un-install
    # @return [Array] List of uninstalled RPMs
    def erase_rpms(list)
      list = verify_rpms(list)
      list.map!{ |rpm| "'#{rpm}'"}
      run "yum erase -y #{list.join(" ")}" unless list.empty?
      list
    end
    
    # Updating all RPMs on the system
    def update_rpms
      puts "Updating all packages on the system"
      run("yum update -y")
      puts "Done"
    end
    
    # Given a list of RPMs, check if they are installed locally
    #
    # @param list [Array] List of RPM names to verify
    # @return [Array] List of installed RPMs
    def verify_rpms(list)
      list.select{ |rpm| not `rpm -q '#{rpm}'`.match(/is not installed/) }
    end
    
    # Attempts to install a gem from RPM. Uses rubygems if requested version is not available as an RPM
    #
    # @param gem_list [Hash] Gem name to version map of gems to install locally.
    def install_gems(gem_list)
      if self.distro_name == 'RedHatEnterpriseServer' or self.distro_name ==  'CentOS'
        scl_prefix = "ruby193-"
      else
        scl_prefix = ""
      end

      gem_list.each do |gem_name, version|
        if version.empty?
          `gem list -i #{gem_name}`
          is_installed = ($? == 0)
          next if is_installed
          success = run "yum install -y '#{scl_prefix}rubygem-#{gem_name}'"
          run "gem install #{gem_name}" unless success
        else
          `gem list -i #{gem_name} -v #{version}`
          is_installed = ($? == 0)
          next if is_installed
          success = run "yum install -y '#{scl_prefix}rubygem-#{gem_name} = #{version}'"
          run "gem install #{gem_name} -v #{version}" unless success
        end
      end
    end
    
    # Create a RPM repository for locally built packages.
    #
    # @param clean [Boolean] Delete existing repository if it exists 
    def create_local_rpm_repository(clean=false)
      puts "Setting up local YUM repository entry for RPMs generated in the local build (#{self.origin_rpms_dir})"
      if clean
        remove_dir self.origin_rpms_dir
        remove_dir "/tmp/tito"
      end
      empty_directory self.origin_rpms_dir
      run "createrepo #{self.origin_rpms_dir}"
      unless File.exist?("/etc/yum.repos.d/openshift-origin.repo")
        create_file "/etc/yum.repos.d/openshift-origin.repo" do
          %{
[openshift-origin]
name    = openshift-origin
baseurl = file://#{self.repo_parent_dir}/origin-rpms
gpgcheck= 0
enabled = 1
retries = 0
          }
        end
      end
      run "yum clean all"
    end
  
    # Looks through all the OpenShift Origin package specs and returns a list of RPMs from required to build the packages.
    # Packages listed in the IGNORE_PACKAGES list will not be processed.
    # 
    # @return [Array] List of package names
    def get_required_packages
      
      if self.distro_name == 'RedHatEnterpriseServer' or self.distro_name ==  'CentOS'
        scl_prefix = "ruby193-"
      else
        scl_prefix = ""
      end

      required_packages = []
      ignore_packages = get_ignore_packages
    
      SIBLING_REPOS.each do |repo_name, repo_dirs|
        repo_dirs.each do |repo_dir|
          exists = File.exists?(repo_dir)
          inside(repo_dir) do
            spec_file_list = `find -name *.spec`.split("\n")
            spec_file_list.each do |spec_file|
              package = Package.new(spec_file, File.dirname(spec_file), scl_prefix)
              package_name = package.name
              unless ignore_packages.include?(package.name)
                required_packages += package.build_requires + package.requires
              end
            end
          end if exists
        end
      end
      
      required_packages -= get_packages(true).keys
      required_packages
    end
    
    # Returns a list of OpenShift Origin packages that should be ignored when building or installing RPMs.
    # This list also includes packages that are not compatible with the OS.
    #
    # @param include_unmodified [Boolean] include packages that do not need to be rebuilt (incremental build)
    # @return [Array] List of package names to ignore
    def get_ignore_packages(include_unmodified=false)
      packages = IGNORE_PACKAGES
      if options.include_unmodified?
        build_dirs = get_build_dirs
    
        all_packages = get_packages
        build_dirs.each do |build_info|
          package_name = build_info[0]
          all_packages.delete(package_name)
        end
    
        packages += all_packages.keys
      end
    
      packages
    end
    
    # Returns an array of packages that have been updated and need to be re-built and re-installed
    #
    # @param include_stale [Boolean] Include packages that have been tagged but not synced to the repo
    # @return [Array] List of package entries. Each entry is an Array containing 3 elements:
    #   1. package_name
    #   1. build_dir
    #   1. spec_file
    def get_incremental_build_packages(include_stale=false)
      # Warn on uncommitted changes
      `git diff-index --quiet HEAD`
      puts "WARNING - Uncommitted repository changes" if $? != 0
      
      # Figure out what needs to be built - exclude devenv for syncs
      packages_to_build = get_sync_dirs
      packages_to_build.delete_if do |package|
        package_name = package[0]
        IGNORE_PACKAGES.include? package_name
      end
      
      if include_stale
        stale_packages = get_stale_dirs
        stale_packages.delete_if do |package|
          package_name = package[0]
          IGNORE_PACKAGES.include? package_name
        end
        
        packages_to_build += stale_packages
      end
      packages_to_build
    end
    
    # Builds a package during an incremental build
    #
    # @param package_name [String] RPM name of the package to build
    # @param build_dir [String] Path of directory to build in
    # @param spec_file [String] Path of spec file for the RPM
    # @param retry_failure_with_tag [Boolean] If a package fails to build, tag it and retry the build.
    # @return [Array] List of paths to the RPMs built for the package
    def build_package(package_name, build_dir, spec_file, retry_failure_with_tag=false)
      
      if self.distro_name == 'RedHatEnterpriseServer' or self.distro_name ==  'CentOS'
        scl_prefix = "ruby193-"
      else
        scl_prefix = ""
      end


      remove_dir '/tmp/tito/'
      empty_dir '/tmp/tito/'
      puts "Building in #{build_dir}"
      spec_file = File.expand_path(spec_file)

      inside(File.expand_path("#{build_dir}", File.dirname(File.dirname(File.dirname(File.dirname(__FILE__)))))) do
        # Build the RPM locally
        unless run "tito build --rpm --test"
          package = Package.new(spec_file, File.dirname(spec_file), scl_prefix)
          package_name = package.name
          ignore_packages = get_ignore_packages
          packages = get_packages
          
          #check to see if any build requirements are missing and install them
          required_packages = package.build_requires
          required_packages.delete_if{ |r_package| packages.include?(r_package.name) }
          required_packages.map!{ |r_package| r_package.yum_name_with_version }
          if not required_packages.empty
            install_rpms(required_packages, true)
          else
            if retry_failure_with_tag
              # Tag to trick tito to build
              commit_id = `git log --pretty=format:%%H --max-count=1 %s" % .`
              spec_file_name = File.basename(spec_file)
              version = get_version(spec_file_name)
              next_version = next_tito_version(version, commit_id)
              puts "current spec file version #{version} next version #{next_version}"
              unless run("tito tag --accept-auto-changelog --use-version='#{next_version}'; tito build --rpm --test", :verbose => options.verbose?)
                remove_dir '/tmp/devenv/sync/'
                exit 1
              end
            else
              puts "Package #{package_name} failed to build."
            end
          end
        end
      end
      
      Dir.glob("/tmp/tito/**/*.rpm")
    end

    # Performs an inplace update of an RPM without causing packages dependent on it to uninstall.
    #
    # @param package_name [String] Name of the package being updated
    # @param rpm_list [Array] List of RPMs associated with this package
    def update_openshift_package(package_name, rpm_list)
      unless run("rpm -Uvh --force #{rpm_list.join(" ")}", :verbose => options.verbose?)
        unless run("rpm -e --justdb --nodeps #{package_name}; yum install -y #{rpm_list.join(" ")}", :verbose => options.verbose?)
          remove_dir '/tmp/devenv/sync/'
          exit 1
        end
      end
    end
    
    # Performs an incremental build
    #
    # @param include_stale [Boolean] Include packages that have been tagged but not synced to the repo.
    # @param retry_failure_with_tag [Boolean] If a package fails to build, tag it and retry the build.
    def incremental_build(include_stale=false, retry_failure_with_tag=false)
      packages = get_incremental_build_packages(include_stale)
      packages.each do |package|
        rpm_list = build_package(package[0], package[1], package[2], retry_failure_with_tag)
        update_openshift_package(package[0], rpm_list)
      end
    end
    
    # Build all OpenShift Origin packages. To account for inter-package build dependencies, builds are
    # performed in phases. Any package which is a dependency of another package is built and installed
    # before the dependent package is built.
    #
    # @return [Array] List of names of packages that were built
    def find_and_build_specs
      remove_dir "/tmp/tito"
      packages = get_packages(false, true).values
      
      # Don't consider packages that are in the IGNORE_PACKAGES list or have not been tagged by tito
      built_packages = buildable = packages.select do |p|
        next false if IGNORE_PACKAGES.include? p.name
        
        Dir.chdir(p.dir) { system "git tag | grep '#{p.name}' 2>&1 1>/dev/null" }.tap do |r|
          puts "\n\nSkipping '#{p.name}' in '#{p.dir}' since it is not tagged.\n" unless r
        end
      end

      # Get all build time dependencies that are not part of OpenShift Origin
      installed = buildable.map(&:build_requires).flatten(1).uniq.sort - buildable

      # Sort packages into phases for building
      phases = []
      while not buildable.empty?
        # separate packages that depend on other packages
        installable, has_dependencies = buildable.partition do |p|
          (p.build_requires & buildable).empty? #.any?{ |req| buildable.any?{ |b| req === b } }
        end
        begin
          installable, is_dependent = installable.partition do |p|
            (p.build_requires & has_dependencies).empty? #.any?{ |name| has_dependencies.any?{ |b| name == b.name } }
          end
          has_dependencies.concat(is_dependent)
        end while not is_dependent.empty?

        raise "The packages remaining to install #{dependencies.inspect} have mutual dependencies" if installable.empty?

        phases << installable
        buildable = has_dependencies
      end

      # Install dependencies
      prereqs = installed.map(&:yum_name)
      prereqs.each do |p|
        SKIP_PREREQ_PACKAGES.each do |sp|
          if p.match(/#{sp}/)
            prereqs.delete(p)
            next
          end
        end
      end
      puts "\n\nExcluded RPM prerequisites\n  #{SKIP_PREREQ_PACKAGES.join("\n  ")}" unless SKIP_PREREQ_PACKAGES.empty?
      puts "\n\nInstalling prerequisites\n"
      install_rpms(prereqs)

      prereqs = (phases[1..-1] || []).flatten(1).map(&:build_requires).flatten(1).uniq.sort - installed
      puts "\nPackages that are prereqs for later phases:\n  #{prereqs.join("\n  ")}"

      # Perform phased build
      phases.each_with_index do |phase,i|
        puts "\n#{'='*60}\n\nBuilding phase #{i+1} packages"
        phase.sort.each do |package|
          Dir.chdir(package.dir) do
            puts "\n#{'-'*60}"
            raise "Unable to build #{package.name}" unless run "tito build --rpm --test"
            if prereqs.include? package
              puts "\n    Installing..."
              raise "Unable to install package #{package.name}" unless run("rpm -Uvh --force /tmp/tito/noarch/#{package}*.rpm")
            end
          end
        end
      end
      
      built_packages
    end
  end
end