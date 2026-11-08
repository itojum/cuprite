# frozen_string_literal: true

module Cuprite
  # `cuprite build [-c cuprite.yml]`
  class CLI
    USAGE = "usage: cuprite build [-c CONFIG]"

    def initialize(out: $stdout, err: $stderr)
      @out = out
      @err = err
    end

    def run(argv)
      args = argv.dup
      command = args.shift
      case command
      when "build" then build(args)
      when "version", "--version", "-v"
        @out.puts "cuprite #{VERSION}"
        0
      else
        @err.puts USAGE
        command.nil? || %w[help --help -h].include?(command) ? 0 : 2
      end
    end

    private

    def build(args)
      config_path = "cuprite.yml"
      until args.empty?
        case (arg = args.shift)
        when "-c", "--config" then config_path = args.shift or return usage_error
        else return usage_error("unknown argument #{arg}")
        end
      end

      config = Config.load(config_path)
      raise ConfigError, "entry file #{config.entry} not found" unless File.file?(config.entry_path)

      source = File.read(config.entry_path)
      pack = Compiler.new(source, namespace: config.namespace, debug: config.debug, file: config.entry).compile
      pack.write(config.pack_dir)
      @out.puts "wrote #{config.pack_dir}"
      if (world_dir = config.world_datapack_dir)
        pack.write(world_dir)
        @out.puts "copied to #{world_dir}"
      end
      0
    rescue Error => e
      @err.puts "cuprite: #{e}"
      1
    end

    def usage_error(message = nil)
      @err.puts "cuprite: #{message}" if message
      @err.puts USAGE
      2
    end
  end
end
