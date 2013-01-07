module Origin
  module SSH
    SSH_CMD = "ssh 2> /dev/null -n -o TCPKeepAlive=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no -i " + RSA
    SCP_CMD = "scp 2> /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no -i " + RSA

    def ssh(hostname, cmd, timeout=60, return_exit_code=false, num_tries=1)
      log.debug "(ssh: hostname = #{hostname} timeout = #{timeout} / cmd = #{cmd})"
      output = ""
      exit_code = 1
      ssh_cmd = "#{SSH_CMD} #{SSH_LOGIN}@#{hostname} '#{cmd} 2>&1'"
      (1..num_tries).each do |i|
        begin
          log.debug(ssh_cmd)
          Timeout::timeout(timeout) do
            output = `#{ssh_cmd}`.chomp
            exit_code = $?.exitstatus
          end
          if exit_code == 0
            break
          elsif i == num_tries
            if num_tries > 1
              puts "\nSSH failed to #{hostname} with exit_code: #{exit_code}  and output: #{output}"
            end
          else
            sleep 10
          end
        rescue Timeout::Error
          log.error "SSH command to #{hostname} timed out (timeout = #{timeout})"
        end
      end
      log.debug "----------------------------\n#{output}\n----------------------------"

      if return_exit_code
        return output, exit_code
      else
        return output
      end
    end

    def scp_from(hostname, remote, local, timeout=60)
      log.debug "(scp_from: timeout = #{timeout}) / local = '#{local}' remote = '#{remote}'"
      output = ""
      begin
        scp_cmd = "#{SCP_CMD} -r #{SSH_LOGIN}@#{hostname}:#{remote} #{local}"
        Timeout::timeout(timeout) { output = `#{scp_cmd}`.chomp }
      rescue Timeout::Error
        log.error "SCP command '#{scp_cmd}' timed out"
      end
      log.debug "----------------------------\n#{output}\n------------------------------"
      return output
    end

    def scp_to(hostname, local, remote, timeout=15, num_tries=5)
      log.debug "(scp_to: timeout = #{timeout}) / local = '#{local}' remote = '#{remote}'"
      output = ""
      scp_cmd = "#{SCP_CMD} -r #{local} #{SSH_LOGIN}@#{hostname}:#{remote} 2>&1"
      (1..num_tries).each do |i|
        begin
          exit_code = 1
          Timeout::timeout(timeout) {
            output = `#{scp_cmd}`
            exit_code = $?.exitstatus
          }
          if exit_code == 0
            break
          elsif i == num_tries
            puts "\nSCP failed to #{hostname} with output: #{output}"
            exit 1
          else
            sleep 10
          end
        rescue Timeout::Error
          log.error "SCP command '#{scp_cmd}' timed out"
        end
      end
      log.debug "----------------------------\n#{output}\n------------------------------"
      return output
    end

    def can_ssh?(hostname)
      ssh(hostname, 'echo Success', CAN_SSH_TIMEOUT,false,1).split[-1] == "Success"
    end
  end
end
