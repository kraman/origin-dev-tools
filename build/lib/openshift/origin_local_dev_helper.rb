module Origin
  module OriginLocalDevHelper
    # Obtain a list of tests to run, organized by testing queues. Tests that are part of the same queue will be run
    # sequentially but different queues may be run in parallel.
    #
    # @param options [Hash] Thor options hash
    #   - include_extended: run base and extended tests
    #   - include_coverage: run tests and calculate code coverage
    #   - include_cucumber: ??
    #   - exclude_broker: skip broker tests
    #   - exclude_runtime: skip runtime tests
    #   - exclude_site: skip site/console tests
    #   - exclude_rhc: skip CLI tests
    # @return [Array] List of test queues. Each queue is an Array of test entries.
    def get_test_list(options, broker_hostname="localhost")
      test_queues = [[], [], [], []]
        
      extended_tests = nil
      if options.include_extended
        extended_tests = []
        extended_tests = options.include_extended.split(",").map do |extended_test|
          extended_test.strip
        end
      end

      if options.include_extended
        extended_tests.each do |extended_test|
          case extended_test
          when 'broker'
            test_queues[0] << ["REST API Group 1", "su -c \"cucumber #{CUCUMBER_OPTIONS} -t @broker_api1 openshift-test/tests\"", {:retry_individually => true}]
            test_queues[1] << ["REST API Group 2", "su -c \"cucumber #{CUCUMBER_OPTIONS} -t @broker_api2 openshift-test/tests\"", {:retry_individually => true}]
            test_queues[2] << ["REST API Group 3", "su -c \"cucumber #{CUCUMBER_OPTIONS} -t @broker_api3 openshift-test/tests\"", {:retry_individually => true}]
            test_queues[3] << ["REST API Group 4", "su -c \"cucumber #{CUCUMBER_OPTIONS} -t @broker_api4 openshift-test/tests\"", {:retry_individually => true}]              
          when 'runtime'
            test_queues[0] << ["Extended Runtime Group 1", "su -c \"cucumber #{CUCUMBER_OPTIONS} -t @runtime_extended1 openshift-test/tests\""]
            test_queues[1] << ["Extended Runtime Group 2", "su -c \"cucumber #{CUCUMBER_OPTIONS} -t @runtime_extended2 openshift-test/tests\""]
            test_queues[2] << ["Extended Runtime Group 3", "su -c \"cucumber #{CUCUMBER_OPTIONS} -t @runtime_extended3 openshift-test/tests\""]
          when 'site'
            puts "Warning: Site tests are currently not supported"
          when 'rhc'
            test_queues[0] << ["RHC Extended", "su -c \"cucumber #{CUCUMBER_OPTIONS} -t @rhc_extended openshift-test/tests\"", {:retry_individually => true}]
            test_queues[1] << ["RHC Integration", "cd openshift-test/rhc && RHC_SERVER=#{broker_hostname} QUIET=1 bundle exec \"cucumber #{CUCUMBER_OPTIONS} features\"", {:retry_individually => true}]
          else
            puts "Not supported for extended: #{extended_test}"
            exit 1
          end
        end
      elsif options.include_coverage?
        #test_queues[0] << ["OpenShift Origin Node Unit Coverage", "cd openshift-test/node; rake rcov; cp -a coverage /tmp/rhc/openshift_node_coverage"]
        #test_queues[1] << ["OpenShift Origin Broker Unit and Functional Coverage", "cd openshift-test/broker; rake rcov; cp -a test/coverage /tmp/rhc/openshift_broker_coverage"]
      elsif options.include_cucumber
        timeout = @@SSH_TIMEOUT
        timeout = @@SSH_TIMEOUT_OVERRIDES[options.include_cucumber] if not @@SSH_TIMEOUT_OVERRIDES[options.include_cucumber].nil?
        test_queues[0] << [options.include_cucumber, "cucumber #{CUCUMBER_OPTIONS} -t @#{options.include_cucumber} openshift-test/tests", {:timeout => timeout}]
      elsif options.include_web?
        puts "Warning: Tests for the website are currently not supported"
      else

        unless options.exclude_broker?
          test_queues[0] << ["OpenShift Origin Broker Functional", "cd openshift-test/broker; su -c \"bundle exec rake test:functionals\""]
          test_queues[1] << ["OpenShift Origin Broker Integration", "cd openshift-test/broker; su -c \"bundle exec rake test:integration\""]
          test_queues[1] << ["OpenShift Origin Broker Unit 1", "cd openshift-test/broker; su -c \"bundle exec rake test:oo_unit1\""]
          test_queues[1] << ["OpenShift Origin Broker Unit 2", "cd openshift-test/broker; su -c \"bundle exec rake test:oo_unit2\""]
          test_queues[2] << ["Broker Cucumber", "su -c \"cucumber --strict -f html --out /tmp/rhc/broker_cucumber.html -f progress -t @broker -t ~@rhel-only openshift-test/tests\""]
        end

        unless options.exclude_runtime?
          #test_queues[3] << ["Runtime Unit", "cd openshift-test/node; su -c \"rake unit_test\""]
          (1..4).each do |i|
            test_queues[i-1] << ["Runtime Group #{i.to_s}", "su -c \"cucumber #{CUCUMBER_OPTIONS} -t @runtime#{i.to_s} openshift-test/tests\""]
          end
        end

        unless options.exclude_site?
        end

        unless options.exclude_rhc?
        end
      end
      test_queues
    end
  end
end