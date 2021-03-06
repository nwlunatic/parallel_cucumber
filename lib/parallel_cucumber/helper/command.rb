module ParallelCucumber
  module Helper
    module Command
      class TimedOutError < RuntimeError; end
      class << self
        def wrap_block(log_decoration, block_name, logger)
          [$stdout, $stderr].each(&:flush)
          logger << format(log_decoration['start'] + "\n", block_name) if log_decoration['start']
          [$stdout, $stderr].each(&:flush)
          yield
        ensure
          [$stdout, $stderr].each(&:flush)
          logger << format(log_decoration['end'] + "\n", block_name) if log_decoration['end']
          [$stdout, $stderr].each(&:flush)
        end

        ONE_SECOND = 1

        def exec_command(env, desc, script, logger, log_decoration = {}, timeout: 30, capture: false) # rubocop:disable Metrics/ParameterLists, Metrics/LineLength
          block_name = ''
          if log_decoration['worker_block']
            if log_decoration['start'] || log_decoration['end']
              block_name = "#{"#{env['TEST_USER']}-w#{env['WORKER_INDEX']}>"} #{desc}"
            end
          end
          logger << format(log_decoration['start'] + "\n", block_name) if log_decoration['start']
          full_script = "#{script} 2>&1"
          env_string = env.map { |k, v| "#{k}=#{v}" }.sort.join(' ')
          logger << "== Running command `#{full_script}` at #{Time.now}\n== with environment variables: #{env_string}\n"
          pstat = nil
          pout = nil
          capture &&= ''
          out_string = ''
          begin
            completed = begin
              pin, pout, pstat = Open3.popen2e(env, full_script)
              logger << "Command has pid #{pstat[:pid]}\n"
              pin.close
              out_reader = Thread.new do
                begin
                  loop do
                    io_select = IO.select([pout], [], [], ONE_SECOND)
                    unless io_select || pstat.alive?
                      logger << "\n== Terminating because io_select=#{io_select} when pstat.alive?=#{pstat.alive?}\n"
                      break
                    end
                    next unless io_select
                    # Windows doesn't support read_nonblock!
                    partial = pout.readpartial(8192)
                    capture += partial if capture
                    out_string = log_until_incomplete_line(logger, out_string + partial)
                  end
                rescue EOFError
                  logger << "\n== EOF is normal exit, #{pstat.inspect}\n"
                rescue => e
                  logger << "\n== Exception in out_reader due to #{e.inspect} #{e.backtrace}\n"
                ensure
                  logger << out_string
                  logger << ["\n== Left out_reader at #{Time.now}; ",
                             "pipe=#{pstat.status}+#{pstat.status ? '≤no value≥' : pstat.value}\n"].join
                end
              end
              throw TimedOutError unless out_reader.join(timeout)
              out_reader.value # Should terminate with pstat
              pout.close
              if pstat.status
                logger << "== Thread #{pstat.inspect} is not dead"
                if pstat.join(3)
                  logger << "== Thread #{pstat.inspect} joined late"
                else
                  pstat.terminate # Just in case
                  logger << "== Thread #{pstat.inspect} terminated"
                end # Make an effort to reap
              end
              pstat.value # reap already-terminated child.
              "Command completed #{pstat.value} at #{Time.now}"
            end
            logger << "#{completed}\n"
            return pstat.value.success? ? capture || true : false
          rescue TimedOutError
            out_reader.exit
            tree = Helper::Processes.ps_tree
            pid = pstat[:pid].to_s
            unless Helper::Processes.ms_windows?
              logger << "Timeout, so trying SIGUSR1 to trigger watchdog stacktrace #{pstat[:pid]}=#{full_script}"
              Helper::Processes.kill_tree('SIGUSR1', pid, logger, tree)
              logger << %x(ps -ax)
              sleep 2
            end

            logger << "Timeout, so trying SIGINT at #{pstat[:pid]}=#{full_script}"

            log_copy = new Thread { pout.each_line { |l| logger << l } }
            log_copy.exit unless log_copy.join(2)

            pout.close

            wait_sigint = 15
            logger << "Timeout #{timeout}s was reached. Sending SIGINT(2), SIGKILL after #{wait_sigint}s."
            begin
              Helper::Processes.kill_tree('SIGINT', pid, logger, tree)
              timed_out = wait_sigint.times do |t|
                break if Helper::Processes.all_pids_dead?(pid, logger, nil, tree)
                logger << "Wait dead #{t} pid #{pid}"
                sleep 1
              end
              if timed_out
                logger << "Process #{pid} lasted #{wait_sigint}s after SIGINT(2), so SIGKILL(9)! Fatality!"
                Helper::Processes.kill_tree('SIGKILL', pid, logger, nil, tree)
                logger << "Tried SIGKILL #{pid}!"
              end
              logger << "About to reap root #{pid}"
              pstat.value # reap root - everything else should be reaped by init.
              logger << "Reaped root #{pid}"
            end
          rescue => e
            logger.debug("Exception #{pstat ? pstat[:pid] : "pstat=#{pstat}=nil"}")
            trace = e.backtrace.join("\n\t").sub("\n\t", ": #{$ERROR_INFO}#{e.class ? " (#{e.class})" : ''}\n\t")
            logger.error("Threw for #{full_script}, caused #{trace}")
          ensure
            logger << format(log_decoration['end'] + "\n", block_name) if log_decoration['end']
          end
          logger.error("*** UNUSUAL TERMINATION FOR: #{script}")
          nil
        end

        def log_until_incomplete_line(logger, out_string)
          loop do
            line, out_string = out_string.split(/\n/, 2)
            return line || '' unless out_string
            logger << line
            logger << "\n"
          end
        end
      end
    end
  end
end
