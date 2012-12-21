#!/usr/bin/env ruby

$: << File.expand_path(File.dirname(__FILE__))

require 'rubygems'
require 'thor'
require 'fileutils'
require 'lib/openshift'
require 'pp'
require 'yaml'

include FileUtils

module OpenShift
  class Builder < Thor
    
    desc "terminate TAG", "Terminates the instance with the specified tag"
    method_option :verbose, :type => :boolean, :desc => "Enable verbose logging"
    method_option :region, :required => false, :desc => "Amazon region override (default us-east-1)"
    def terminate(tag)
      options.verbose? ? @@log.level = Logger::DEBUG : @@log.level = Logger::ERROR
      conn = connect(options.region)
      instance = find_instance(conn, tag, true, false, ssh_user)
      terminate_instance(instance, true) if instance
    end

    desc "launch NAME", "Launches the latest DevEnv instance, tagging with NAME"
    method_option :verifier, :type => :boolean, :desc => "Add verifier functionality (private IP setup and local tests)"
    method_option :branch, :default => "master", :desc => "Launch a devenv image from a particular branch"
    method_option :verbose, :type => :boolean, :desc => "Enable verbose logging"
    method_option :express_server, :type => :boolean, :desc => "Set as express server in express.conf"
    method_option :ssh_config_verifier, :type => :boolean, :desc => "Set as verifier in .ssh/config"
    method_option :instance_type, :required => false, :desc => "Amazon machine type override (default '#{TYPE}')"
    method_option :region, :required => false, :desc => "Amazon region override (default us-east-1)"
    method_option :image_name, :required => false, :desc => "AMI ID or DEVENV name to launch"
    def launch(name)
      options.verbose? ? @@log.level = Logger::DEBUG : @@log.level = Logger::ERROR

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

    desc "test TAG", "Runs the tests on a tagged instance and downloads the results"
    method_option :terminate, :type => :boolean, :desc => "Terminate the instance when finished"
    method_option :verbose, :type => :boolean, :desc => "Enable verbose logging"
    method_option :official, :type => :boolean, :desc => "For official use.  Send emails, etc."
    method_option :exclude_broker, :type => :boolean, :desc => "Exclude broker tests"
    method_option :exclude_runtime, :type => :boolean, :desc => "Exclude runtime tests"
    method_option :exclude_site, :type => :boolean, :desc => "Exclude site tests"
    method_option :exclude_rhc, :type => :boolean, :desc => "Exclude rhc tests"
    method_option :include_cucumber, :required => false, :desc => "Include a specific cucumber test (verify, internal, node, api, etc)"
    method_option :include_coverage, :type => :boolean, :desc => "Include coverage analysis on unit tests"
    method_option :include_extended, :required => false, :desc => "Include extended tests"
    method_option :disable_charlie, :type => :boolean, :desc=> "Disable idle shutdown timer on dev instance (charlie)"
    method_option :mcollective_logs, :type => :boolean, :desc=> "Don't allow mcollective logs to be deleted on rotation"
    method_option :profile_broker, :type => :boolean, :desc=> "Enable profiling code on broker"
    method_option :include_web, :type => :boolean, :desc => "Include running Selenium tests"
    method_option :sauce_username, :required => false, :desc => "Sauce Labs username"
    method_option :sauce_access_key, :required => false, :desc => "Sauce Labs access key"
    method_option :sauce_overage, :type => :boolean, :desc => "Run Sauce Labs tests even if we are over our monthly minute quota"
    method_option :region, :required => false, :desc => "Amazon region override (default us-east-1)"
    def test(tag)
      options.verbose? ? @@log.level = Logger::DEBUG : @@log.level = Logger::ERROR

      conn = connect(options.region)
      instance = find_instance(conn, tag, true, true, ssh_user)
      hostname = instance.dns_name

      test_impl(tag, hostname, instance, conn, options)
    end

    desc "sanity_check TAG", "Runs a set of sanity check tests on a tagged instance"
    method_option :verbose, :type => :boolean, :desc => "Enable verbose logging"
    method_option :region, :required => false, :desc => "Amazon region override (default us-east-1)"
    def sanity_check(tag)
      options.verbose? ? @@log.level = Logger::DEBUG : @@log.level = Logger::ERROR

      conn = connect(options.region)
      instance = find_instance(conn, tag, true, true, ssh_user)
      hostname = instance.dns_name

      sanity_check_impl(tag, hostname, instance, conn, options)
    end

    

  end #class
end #module
