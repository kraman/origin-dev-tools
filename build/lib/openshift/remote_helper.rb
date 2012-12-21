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
    
    def devenv_base_branch_wildcard(branch)
      wildcard = nil
      if branch == 'master'
        wildcard = "#{DEVENV_NAME}-base_*"
      else
        wildcard = "#{DEVENV_NAME}-#{branch}-base_*"
      end
      wildcard
    end
  end
end