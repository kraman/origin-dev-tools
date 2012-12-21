require "parseconfig"
require "timeout"

module Origin
  module TestHelper
    @@SSH_TIMEOUT = 4800
    @@SSH_TIMEOUT_OVERRIDES = { "benchmark" => 172800 }
    
    # Copies all the tests for different repositories into a single directory so that tests can be run from there.
    def prepare_test_dirs
      puts "Preparing tests directory"
      empty_directory "#{repo_parent_dir}/openshift-test"
      remove_dir "#{repo_parent_dir}/openshift-test/tests"
      FileUtils.ln_s "#{repo_parent_dir}/origin-server/controller/test/cucumber", "#{repo_parent_dir}/openshift-test/tests"
      remove_dir "/tmp/rhc"
      empty_directory "/tmp/rhc/junit"
    
      SIBLING_REPOS.each do |repo_name, repo_dirs|
        repo_dir = "#{repo_parent_dir}/#{repo_name}"
        inside(repo_dir) do
          run "git archive --prefix openshift-test/#{::OPENSHIFT_ARCHIVE_DIR_MAP[repo_name] || ''} --format=tar HEAD | (cd #{repo_parent_dir} && tar --warning=no-timestamp -xf -);"
        end
      end
    end
    
    # Test harness that can be used to run tests locally or via ssh depending on the test_proc being used
    # Tests in different queues may be run in parallel. Failing tests are retried 2 times to avoid intermittent issues.
    #
    # @param test_proc [Proc] Function to use to run the actual test.
    def run_tests(test_proc)
      if File.exists?("/etc/openshift/node.conf")
        config = ParseConfig.new("/etc/openshift/node.conf")
        broker_hostname = config.get_value("PUBLIC_HOSTNAME")
      else
        broker_hostname = "localhost"
      end
      
      test_queues = get_test_list(options, broker_hostname)
      
      failures = []
      threads = []
      retry_threshold = 0        
      
      test_queues.each_index do |idx|
        puts "Executing batch ##{idx}"
        
        test_queue = test_queues[idx]
        retry_threshold += 8 * test_queue.length
        tests = []        
        
        tests = test_queue.map do |test|
          {
            test_base_path: repo_parent_dir,
            broker_hostname: broker_hostname,
            cmd: test[1], 
            title: test[0], 
            retry_individually: options[:retry_individually] ? true : false,
            timeout: options[:timeout] ? options[:timeout] : @@SSH_TIMEOUT
          }
        end
        threads << test_proc.call(tests, failures)
      end
      
      threads.each do |t|
        t.join
      end
      failures.uniq!
        
      if failures.length > 0 && failures.length <= retry_threshold
        (1..2).each do |x|
          puts "\n"*5
          puts "="*75
          puts "Retrying failures (Pass #{x})...\n"
          puts "#{failures.map{|f| f[:title]}.join("\n")}\n\n"
          
          FileUtils.rm_rf "/tmp/rhc"
          FileUtils.mkdir_p "/tmp/rhc/junit"
          
          new_failures = []
          thread = test_proc.call(failures, new_failures)
          thread.join
          break if new_failures.count == 0
          failures = new_failures
          failures.uniq!          
        end
      elsif failures.length > retry_threshold
        exit 1
      end
      
      puts "\n"*5
      puts "="*75
      puts "Unresolved failures:\n"
      puts failures.map{|f| "#{f[:title]}\n\t#{f[:cmd]}\n"}
    end
    
    # Starts a new thread to run tests and record failures
    #
    # @param tests [Array] List of tests to run in this thread
    # @param failures [Array] Output param to store list of failed tests
    # @param prending_jobs [Array] Input/Output param to store a list of still running tasks
    # @param block Function to use to run the actual test.
    # @return [Thread] Thread object running the tests
    def run_tests_in_thread(tests, failures, prending_jobs, &block)
      start_time = Time.new    
      Thread.new {
        multi = tests.length > 1
        tests.each do |test|
          output, exit_code = yield(test)
          retry_individually = test[:retry_individually] || false
    
          if exit_code != 0
            retry_title = ""
            retry_command = ""
            
            if output.include?("Failing Scenarios:") && output =~ /cucumber openshift-test\/tests\/.*\.feature:\d+/
              output.lines.each do |line|
                if line =~ /cucumber openshift-test\/tests\/(.*\.feature):(\d+)/
                  test_file = $1
                  scenario = $2
                  if retry_individually
                    retry_title   = test[:title]
                    retry_command = "su -c \"cucumber #{CUCUMBER_OPTIONS} openshift-test/tests/#{test_file}:#{scenario}\""
                  else
                    retry_title   = "#{test[:title]} (#{test_file})"                    
                    retry_command = "su -c \"cucumber #{CUCUMBER_OPTIONS} openshift-test/tests/#{test_file}\""
                  end
                end
              end
            elsif retry_individually && output.include?("Failure:") && output.include?("rake_test_loader")
              found_test = false
              output.lines.each do |line|
                if line =~ /\A(test_\w+)\((\w+Test)\) \[\/.*\/(test\/.*_test\.rb):(\d+)\]:/
                  found_test = true
                  test_name = $1
                  class_name = $2
                  file_name = $3
    
                  # determine if the first part of the command is a directory change
                  # if so, include that in the retry command
                  chdir_command = ""
                  if test[:cmd] =~ /\A(cd .+?; )/
                    chdir_command = $1
                  end
                  
                  retry_title = "#{class_name} (#{test_name})"
                  retry_command = "#{chdir_command} ruby -Ilib:test #{file_name} -n #{test_name}"
                end
              end
              unless found_test
                retry_title = test[:title]
                retry_command = test[:cmd]
              end
            else
              retry_title = test[:title]
              retry_command = test[:cmd]
            end
            
            unless retry_command.empty?
              failures.push({
                cmd: retry_command,
                title: retry_title,
                retry_individually: retry_individually,
                timeout: test[:timeout],
                test_base_path: test[:test_base_path],
                broker_hostname: test[:broker_hostname]
              })
            end
          end
    
          prending_jobs.delete(test)
          if prending_jobs.length > 0
            mins, secs = (Time.new - start_time).abs.divmod(60)
            puts "Still Running Tests (#{mins}m #{secs.to_i}s):"
            puts prending_jobs.join("\n")
          end
        end
      }
    end
    
    # Function to run a test in the local host. Failing tests are added to the failures array.
    #
    # @param tests [Array] List of tests to run sequentially
    # @param failures [Array] Output param. Will be populated by a list of failing tests
    # @return [Thread] Thread object representing the thread in which the tests are running
    def local_test_proc(tests, failures)
      pending_jobs = []
      pending_jobs += tests.map{ |test| test[:title] }
      run_tests_in_thread(tests, failures, pending_jobs) do |test|
        cmd = test[:cmd]
        title = test[:title]
        timeout = test[:timeout] || 0
        base_path = test[:test_base_path]
        output = ""
        exit_code = 1
    
        begin
          Timeout::timeout(timeout) do
            output = `cd #{base_path}; #{cmd}`.chomp
            exit_code = $?.exitstatus
            print_highlighted_output(cmd, output)
          end
        rescue Timeout::Error
          log.error "Command #{cmd} timed out"
        end
    
        [output, exit_code]
      end
    end  
  end
end