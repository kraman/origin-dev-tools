# we will need ssh with some different options for git clones
GIT_SSH_PATH=File.expand_path(File.dirname(__FILE__)) + "/ssh-override"

module Origin
  module OriginEc2DevHelper
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
      instance = launch_ec2_instance(image, name + "_" + build_num, 1)

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
          puts "Installing Origin packages..."
          out, ret = ssh(hostname, "cd /mnt/origin-dev-tools && su -c \"build/devenv build\"", 60 * 20, true, 1)
          print_and_exit(ret, out) if ret != 0

          puts "Running broker setup..."
          out, ret = ssh(hostname, "su -c /usr/sbin/oo-setup-broker", 60 * 20, true, 1)
          print_and_exit(ret, out) if ret != 0
        end

        # reset the eth0 network config to remove the HWADDR
        puts "Removing HWADDR and DNS entries from eth0 network config..."
        reset_eth0_dns_config(hostname)
        
        image_id = nil
        if options[:register]
          manifest = rpm_manifest(hostname)              
          registered_ami = register_image(conn, instance, name + '_' + build_num, manifest)
          image_id = registered_ami.id
          puts "Registered image #{image_id}"
        end

        # Register broker dns and restart the network
        unless options.install_required_packages?  
          post_launch_setup(hostname)
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
    
    def post_launch_setup(hostname)
      # reset the eth0 network config to add the dns entries
      puts "Registering broker dns..."
      cmd = %{
ext_address=`/sbin/ip addr show dev eth0 | grep inet | cut -d/ -f1 | rev | cut -d \" \" -f1 | rev`
su -c \"/usr/sbin/oo-register-dns -h broker -n $ext_address\"
            }
      out, ret = ssh(hostname, cmd, 60 * 5, true, 1)
      print_and_exit(ret, out) if ret != 0
    end
    
    def reset_eth0_dns_config(hostname)
      # reset the eth0 network config to add the dns entries
      cmd = %{
su -c \"echo \\\"DEVICE=eth0
BOOTPROTO=dhcp
DNS1=127.0.0.1
DNS2=8.8.8.8
DNS3=8.8.4.4
ONBOOT=yes\\\" > /etc/sysconfig/network-scripts/ifcfg-eth0\"

su -c \"/etc/init.d/network restart\"
su -c \"service named restart\"
}
      out, ret = ssh(hostname, cmd, 60 * 5, true, 1)
      print_and_exit(ret, out) if ret != 0
    end
    
    def rpm_manifest(hostname)
      print "Retrieving RPM manifest.."
      manifest = ssh(hostname, 'rpm -qa | grep -E "(rhc|openshift)" | grep -v cartridge', 60, false, 1)
      manifest = manifest.split("\n").sort.join(" / ")
      # Trim down the output to 255 characters
      manifest.gsub!(/rubygem-([a-z])/, '\1')
      manifest.gsub!('openshift-origin-', '')
      manifest.gsub!('mcollective-', 'mco-')
      manifest.gsub!('.fc17', '')
      manifest.gsub!('.noarch', '')
      manifest.gsub!(/\.git\.[a-z0-9\.]+/, '')
      manifest = manifest[0..254]
      puts "Done"
      return manifest
    end
  end
end