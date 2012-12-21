# we will need ssh with some different options for git clones
GIT_SSH_PATH=File.expand_path(File.dirname(__FILE__)) + "/ssh-override"

module Origin
  module OriginEc2DevHelper
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
    
    # OpenShift Origin specific version of RemoteHelper#Build
    #
    # @param name [String] Tag name of new instance. Final tag will be <tag name>_<tag number>
    # @param build_num [Integer] Tag number of new image. Final tag will be <tag name>_<tag number>
    # @param image [String] EC2 AMI base image to launch
    # @param conn [AWS::EC2] EC2 connection instance
    # @param options [Hash] Thor options hash
    #   - install_required_packages: Perform a YUM update on the instance.
    def build_impl(name, build_num, image, conn)
      $amz_options[:block_device_mappings] = {"/dev/sdb" => "ephemeral0"}

      puts "Launching AMI: #{image.id} - #{image.name}"
      instance = launch_instance(image, name + "_" + build_num, 1)

      hostname = instance.dns_name
      puts "Done"
      puts "Hostname: #{hostname}"
      
      ret, out = 0, nil
      begin
        if options.install_required_packages?
          puts "Starting yum update"
          out, ret = ssh(hostname, "su -c \"yum -y update\"", 60 * 20, true, 1)
          print_and_exit(ret, out) if ret != 0
          print_highlighted_output("Update Output", out)
        end

        puts "Installing packages required for build"
        out, ret = ssh(hostname, "su -c \"yum install -y git rubygems rubygem-thor\"", 60 * 10, true, 1)
        print_and_exit(ret, out) if ret != 0
        print_highlighted_output("Install Output", out)

        puts "Creating ephemeral storage mount"
        out, ret = ssh(hostname, "su -c \"umount -l /mnt ; if [ ! -b /dev/xvdb ]; then /sbin/mke2fs /dev/xvdb; fi; mkdir -p /mnt && mount /dev/xvdb /mnt && chown -R ec2-user:ec2-user /mnt/\"", 60 * 10, true, 1)
        print_and_exit(ret, out) if ret != 0

        puts "Cloning bare repositories"
        init_repos(hostname, true, nil, "/mnt")
        clone_commands, working_dirs = '', ''

        if options.install_from_local_source?
          puts "Performing clean install from local source..."
          clone_commands, working_dirs = sync_available_sibling_repos(hostname, "/mnt")
        else
          SIBLING_REPOS.each do |repo_name, repo_dirs|
            working_dirs += "#{repo_name} "
            clone_commands += "git clone #{repo_name}-bare #{repo_name}; "
            clone_commands += "pushd #{repo_name}; git checkout #{options.branch}; popd; "
          end
        end
        out, ret = ssh(hostname, "cd /mnt; rm -rf #{working_dirs}; #{clone_commands}", 60 * 5, true, 2)
        print_and_exit(ret, out) if ret != 0
        puts "Done"

        #if options[:extra_rpm_dir]
        #  if File.exist? options[:extra_rpm_dir]
        #    out, ret = ssh(hostname, "mkdir -p /mnt/origin-server/build/extras", 60, true, 1)
        #    files = Dir.glob("#{options[:extra_rpm_dir]}/*.rpm")
        #    files.each do |file|
        #      scp_to(hostname, file, "/mnt/origin-server/build/extras/", 60*10, 5)
        #    end
        #
        #    out, ret = ssh(hostname, "su -c \"cd /mnt/origin-server/build/extras && yum install -y *.rpm\"", 60 * 20, true, 1)
        #  else
        #    puts "!!!Warning!!!"
        #    puts "Directory containing extra rpms not found. Skipping..."
        #    puts "!!!Warning!!!"
        #  end
        #end
      
        puts "Installing pre-requisite packages"
        out, ret = ssh(hostname, "cd /mnt/origin-dev-tools && su -c \"build/devenv install_required_packages\"", 60 * 30, true, 1)
        print_and_exit(ret, out) if ret != 0
        print_highlighted_output("Install Output", out)

        # Add the paths to the users .bashrc file
        out, ret = ssh(hostname, "echo \"export PATH=/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:$PATH\" >> ~/.bashrc", 60, true, 1)

        if options.install_from_source? || options.install_from_local_source?
          puts "Installing SELinux policies..."
          out, ret = ssh(hostname, "su -c \" yum install -y http://kojipkgs.fedoraproject.org//packages/selinux-policy/3.10.0/164.fc17/noarch/selinux-policy-3.10.0-164.fc17.noarch.rpm http://kojipkgs.fedoraproject.org//packages/selinux-policy/3.10.0/164.fc17/noarch/selinux-policy-targeted-3.10.0-164.fc17.noarch.rpm http://kojipkgs.fedoraproject.org//packages/selinux-policy/3.10.0/164.fc17/noarch/selinux-policy-devel-3.10.0-164.fc17.noarch.rpm\"", 60 * 5, true, 1)
          print_and_exit(ret, out) unless ret == 0 || out.match(/Nothing to do/)
            
          puts "Installing Origin packages..."
          out, ret = ssh(hostname, "cd /mnt/origin-dev-tools && su -c \"build/devenv build\"", 60 * 20, true, 1)
          print_and_exit(ret, out) if ret != 0

          #puts "Running broker setup..."
          #out, ret = ssh(hostname, "su -c /usr/sbin/oo-setup-broker", 60 * 20, true, 1)
          #print_and_exit(ret, out) if ret != 0
        end
        
        #out, ret = ssh(hostname, "su -c \"cd /mnt && chown -R ec2-user:ec2-user .\"", 60 * 2, true, 1)
        #print_and_exit(ret, out) if ret != 0
        #puts "Done"
    
        image_id = nil
        if options[:register]
          # reset the eth0 network config to remove the HWADDR
          puts "Removing HWADDR and DNS entries from eth0 network config..."
          reset_eth0_dns_config(hostname)
          
          manifest = rpm_manifest(hostname)              
          registered_ami = register_image(conn, instance, name + '_' + build_num, manifest)
          image_id = registered_ami.id
        end

        # Register broker dns and restart the network
        unless options.install_required_packages?  
          post_launch_setup(hostname)
          restart_services_remote(hostname)
        end

        unless options.skip_verify? || options.install_required_packages?
          scp_remote_tests(hostname, options.branch, "~")
          test_impl(name + '_' + build_num, hostname, instance, conn, options, image_id)
        end
        puts "Done."
      ensure
        begin
          terminate_instance(instance) if options.terminate?
        rescue
          # suppress termination errors - they have been logged already
        end
      end
    end
    
    
    def reset_eth0_dns_config(hostname)
      # reset the eth0 network config to add the dns entries
      cmd = %{
su -c \"echo \\\"DEVICE=eth0
BOOTPROTO=dhcp
ONBOOT=yes\\\" > /etc/sysconfig/network-scripts/ifcfg-eth0\"

su -c \"/etc/init.d/network restart\"
su -c \"service named restart\"
}
      out, ret = ssh(hostname, cmd, 60 * 5, true, 1)
      print_and_exit(ret, out) if ret != 0
    end
  end
end