require 'lib/openshift/amz.rb'
require 'lib/openshift/git.rb'
require 'lib/openshift/ssh.rb'

module Origin
  # Functions to build, sync and test code on EC2 machines
  module RemoteHelper
    include Origin::Amazon
    include Origin::Git
    include Origin::SSH
    
    # Launch a new EC2 instance from a preexisting AMI or build a new one from scratch to install and test OpenShift.
    #
    # @param name [String]
    # @param build_num [Integer]
    # @param options [Hash] Thor options hash
    #   - instance_type:
    #   - region:
    #   - install_required_packages:
    #   - branch:
    def build_ami(name, build_num)
      # Override the machine type to launch if necessary
      $amz_options[:instance_type] = options[:instance_type] if options[:instance_type]

      # Establish a new connection
      conn = connect(options.region)

      image = nil
      if options.install_required_packages?
        # Create a new builder instance
        if options.region?(nil)
          image = conn.images[AMI["us-east-1"]]
        elsif AMI[options.region].nil?
          puts "No AMI specified for region:" + options.region
          exit 1
        else
          image = conn.images[AMI[options.region]]
        end
      else
        # Get the latest devenv base image and create a new instance
        filter = devenv_base_branch_wildcard(options.branch)
        image = get_latest_ami(conn, filter)
      end
      
      build_impl(name, build_num, image, conn)
    end
    
    # Checkout the OpenShift source repositories on the EC2 instance
    #
    # @param hostname [String] FQDN of the remote instance
    # @param replace [Boolean] Delete and recreate the repository
    # @param remote_repo_parent_dir [String] Path to clone the repositories into
    def init_repos(hostname, replace=true, repo=nil, remote_repo_parent_dir="/root")
      git_clone_commands = ''

      SIBLING_REPOS.each do |repo_name, repo_dirs|
        if repo.nil? or repo == repo_name
          repo_git_url = SIBLING_REPOS_GIT_URL[repo_name]
          git_clone_commands += "if [ ! -d #{remote_repo_parent_dir}/#{repo_name}-bare ]; then\n" unless replace
          git_clone_commands += "rm -rf #{remote_repo_parent_dir}/#{repo_name}; git clone --bare #{repo_git_url} #{remote_repo_parent_dir}/#{repo_name}-bare;\n"
          git_clone_commands += "fi\n" unless replace
        end
      end
      ssh(hostname, git_clone_commands, 240, false, 10)
    end
    
    # Update the repository on the EC2 instance with changes from the local repository
    #
    # @param repo_name [String] The name of the local repository
    # @param hostname [String] FQDN of the EC2 instance
    # @param remote_repo_parent_dir [String] Path to parent directory of the repository on the remote instance.
    # @param verbose [Boolean] print sync output
    def sync_repo(repo_name, hostname, remote_repo_parent_dir="/root", verbose=false)
      temp_commit

      begin
        # Get the current branch
        branch = get_branch

        puts "Synchronizing local changes from branch #{branch} for repo #{repo_name} from #{File.basename(FileUtils.pwd)}..."
        init_repos(hostname, false, repo_name, remote_repo_parent_dir)

        exitcode = run(<<-"SHELL", :verbose => verbose)
          #######
          # Start shell code
          export GIT_SSH=#{GIT_SSH_PATH}
          #{branch == 'origin/master' ? "git push -q #{SSH_LOGIN}@#{hostname}:#{remote_repo_parent_dir}/#{repo_name}-bare master:master --tags --force; " : ''}
          git push -q #{SSH_LOGIN}@#{hostname}:#{remote_repo_parent_dir}/#{repo_name}-bare #{branch}:master --tags --force

          #######
          # End shell code
          SHELL
        puts "Done"
      ensure
        reset_temp_commit
      end
    end
    
    # Update the remote instance with code changes from a local repository if it exists on the local machine
    # @param repo_name [String] The name of the local repository
    # @param repo_dir [String] Path to the local repository
    # @param hostname [String] FQDN of the EC2 instance
    # @param remote_repo_parent_dir [String] Path to parent directory of the repository on the remote instance.
    def sync_sibling_repo(repo_name, repo_dir, hostname, remote_repo_parent_dir="/root")
      exists = File.exists?(repo_dir)
      inside(repo_dir) do
        sync_repo(repo_name, hostname, remote_repo_parent_dir)
      end if exists
      exists
    end
    
    # Update the remote instance with code changes from all local repositories
    # @param hostname [String] FQDN of the EC2 instance
    # @param remote_repo_parent_dir [String] Path to parent directory of the repository on the remote instance.
    # @return [String] commands to run remotely for cloning to standard working dirs
    # @return [String] The names of those working dirs
    def sync_available_sibling_repos(hostname, remote_repo_parent_dir="/root")
      working_dirs = ''
      clone_commands = ''
      SIBLING_REPOS.each do |repo_name, repo_dirs|
        repo_dirs.each do |repo_dir|
          if sync_sibling_repo(repo_name, repo_dir, hostname, remote_repo_parent_dir)
            working_dirs += "#{repo_name} "
            clone_commands += "git clone #{repo_name}-bare #{repo_name}; "
            break # just need the first repo found
          end
        end
      end
      return clone_commands, working_dirs
    end
    
    def launch_instance(name)
      ami = choose_ami_for_launch(options)

      # Override the machine type to launch if necessary
      $amz_options[:instance_type] = options[:instance_type] if options[:instance_type]

      if ami.nil?
        puts "No image name '#{options[:image_name]}' found!"
        exit(1)
      else
        puts "Launching latest instance #{ami.id} - #{ami.name}"
      end

      instance = launch_instance(ami, name, 1, ssh_user)
      hostname = instance.dns_name
      puts "Done"
      puts "Hostname: #{hostname}"

      puts "Sleeping for #{SLEEP_AFTER_LAUNCH} seconds to let node stabilize..."
      sleep SLEEP_AFTER_LAUNCH
      puts "Done"

      update_facts_impl(hostname)
      post_launch_setup(hostname)
      setup_verifier(hostname, options.branch) if options.verifier?

      validate_instance(hostname, 4)

      update_api_file(instance) if options.ssh_config_verifier?
      update_ssh_config_verifier(instance) if options.ssh_config_verifier?
      update_express_server(instance) if options.express_server?

      home_dir=File.join(ENV['HOME'], '.openshiftdev/home.d')
      if File.exists?(home_dir)
        Dir.glob(File.join(home_dir, '???*'), File::FNM_DOTMATCH).each {|file|
          puts "Installing ~/#{File.basename(file)}"
          scp_to(hostname, file, "~/", File.stat(file).mode, 10, ssh_user)
        }
      end

      puts "Public IP:       #{instance.public_ip_address}"
      puts "Public Hostname: #{hostname}"
      puts "Site URL:        https://#{hostname}"
      puts "Done"
    end
    
    # Find an AMI that satisfies a set of filter options
    # @param [Hash] options
    #  - region: EC2 region ID
    #  - branch: OpenShift Origin branch used to create the AMI
    #  - image_name: (Optional) Specific AMI Image name to launch
    # @return AWS ami
    def choose_ami_for_launch(options)
      # Get the latest devenv image and create a new instance
      conn = connect(options.region)
      filter = choose_filter_for_launch_ami(options)
      if options[:image_name]
        filter = options[:image_name]
        ami = get_specific_ami(conn, filter)
      else
        ami = get_latest_ami(conn, filter)
      end
      ami
    end

    def choose_filter_for_launch_ami(options)
      devenv_branch_wildcard(options.branch)
    end
    
    def devenv_branch_wildcard(branch)
      wildcard = nil
      if branch == 'master'
        wildcard = "#{DEVENV_NAME}_*"
      else
        wildcard = "#{DEVENV_NAME}-#{branch}_*"
      end
      wildcard
    end
    
    def devenv_base_branch_wildcard(branch)
      wildcard = nil
      if branch == 'master'
        wildcard = "#{DEVENV_NAME}-base_*"
      else
        wildcard = "#{DEVENV_NAME}-#{branch}-base_*"
      end
      wildcard
    end
    
    # Get the hostname from a tag lookup or assume it's SSH accessible directly
    # Only look for a tag if the --tag option is specified
    #
    # @param name [String] Name or tag of the host being looked up
    # @return [String] FQDN of the instance
    def get_host_by_name_or_tag(name)
      return name unless options && options.tag?
      
      instance = find_instance(connect(options.region), name, true, true)
      if not instance.nil?
        return instance.dns_name
      else
        puts "Unable to find instance with tag: #{name}"
        exit 1
      end
    end
    
    # Terminate a OpenShift Origin ec2 instance
    def terminate_instance(tag, region)
      conn = connect(region)
      instance = find_instance(conn, tag, true, false)
      if instance.nil?
        puts "No instance found in region #{region} with tag #{tag}"
      else
        terminate_ec2_instance(instance, true)
      end
    end
  end
end