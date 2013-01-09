require 'logger'

module Origin
  module SetupHelper
    BUILD_REQUIREMENTS = ["tito","yum-plugin-priorities","git","make","wget","redhat-lsb"]
    BUILD_GEM_REQUIREMENTS = ["aws-sdk"]
    
    # Ensure that openshift mirror repository and all build requirements are installed. 
    # On RHEL6, it also verifies that the build script is running within SCL-Ruby 1.9.3.
    def ensure_build_requirements
      raise "Unsupported Operating system. Currently the OpenShift Origin build scripts only work with Fedora 17 and RHEL 6 releases." unless File.exist?("/etc/redhat-release")
      packages = BUILD_REQUIREMENTS.select{ |rpm| `rpm -q #{rpm}`.match(/is not installed/) }
      if packages.length > 0
        puts "You are the following packages which are required to run this build script. Installing..."
        puts packages.map{|p| "\t#{p}"}.join("\n")
        run "yum install -y #{packages.join(" ")}"
      end

      create_openshift_deps_rpm_repository
      if RUBY_VERSION != "1.9.3"
        if `lsb_release -i`.gsub(/Distributor ID:\s*/,'').strip == "RedHatEnterpriseServer" or `lsb_release -i`.gsub(/Distributor ID:\s*/,'').strip == "CentOS"
          puts "Unsupported ruby version #{RUBY_VERSION}. Please ensure that you are running within a ruby193 scl container:\n"
          puts "\tyum install scl-utils ruby193\n\tscl enable ruby193 /bin/bash\n"
          exit
        else
          puts "Unsupported ruby version #{RUBY_VERSION}. Please ensure that you are running Ruby 1.9.3\n"
          exit
        end
      end
    end
    
    # Create a RPM repository for OpenShift Origin dependencies available on the mirror.openshift.com site
    def create_openshift_deps_rpm_repository
      if `lsb_release -i`.gsub(/Distributor ID:\s*/,'').strip == "RedHatEnterpriseServer" or `lsb_release -i`.gsub(/Distributor ID:\s*/,'').strip == "CentOS"
        url = "https://mirror.openshift.com/pub/openshift-origin/rhel-6/$basearch/"
      else
        url = "https://mirror.openshift.com/pub/openshift-origin/fedora-17/$basearch/"
      end
      
      unless File.exist?("/etc/yum.repos.d/openshift-origin-deps.repo")
        create_file "/etc/yum.repos.d/openshift-origin-deps.repo" do
          %{
[openshift-origin-deps]
name=openshift-origin-deps
baseurl=#{url}
gpgcheck=0
enabled=1
          }
        end
      end
    end
    
    # Force synchronous stdout
    STDOUT.sync, STDERR.sync = true

    # Setup logger
    @@log = Logger.new(STDOUT)
    @@log.level = Logger::DEBUG

    # Returns the default logger class
    def log
      @@log
    end
    
    # Prints the title of the section and prints the output with begining and ending markers.
    #
    # @param title [String] Title of the section
    # @param out [String] Output to print
    def print_highlighted_output(title, out)
      puts
      puts "------------------ Begin #{title} ------------------------"
      puts out
      puts "------------------- End #{title} -------------------------"
      puts
    end
    
    def print_and_exit(ret, out)
      if ret != 0
        puts "Exiting with error code #{ret}"
        puts "Output: #{out}"
        exit ret
      end
    end
  end
end