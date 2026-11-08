# frozen_string_literal: true

require "yaml"

module Cuprite
  # Settings read from cuprite.yml (design §2.1).
  class Config
    KEYS = %w[namespace entry output debug world].freeze

    attr_reader :namespace, :entry, :output, :debug, :world, :root

    def self.load(path)
      raise ConfigError, "#{path} not found" unless File.file?(path)

      data = YAML.safe_load_file(path) || {}
      raise ConfigError, "#{path}: expected a mapping" unless data.is_a?(Hash)

      new(data, root: File.dirname(File.expand_path(path)))
    rescue Psych::SyntaxError => e
      raise ConfigError, "#{path}: #{e.message}"
    end

    def initialize(data, root: Dir.pwd)
      unknown = data.keys - KEYS
      raise ConfigError, "unknown key(s) in cuprite.yml: #{unknown.join(', ')}" unless unknown.empty?

      @root = root
      @namespace = data["namespace"] or raise ConfigError, "cuprite.yml: namespace is required"
      Names.new(@namespace) # validates
      @entry = data.fetch("entry", "src/main.rb")
      @output = data.fetch("output", "build")
      @debug = data.fetch("debug", false)
      raise ConfigError, "cuprite.yml: debug must be true or false" unless [true, false].include?(@debug)

      @world = data["world"]
    end

    def entry_path = File.expand_path(entry, root)

    # The pack is written to <output>/<namespace>/.
    def pack_dir = File.join(File.expand_path(output, root), namespace)

    def world_datapack_dir
      return nil unless world

      File.join(File.expand_path(world, root), "datapacks", namespace)
    end
  end
end
