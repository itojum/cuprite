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
      @entry = path_setting(data, "entry", "src/main.rb")
      @output = path_setting(data, "output", "build")
      @debug = data.fetch("debug", false)
      raise ConfigError, "cuprite.yml: debug must be true or false" unless [true, false].include?(@debug)

      @world = data["world"]
      raise ConfigError, "cuprite.yml: world must be a non-empty path" unless @world.nil? || non_empty_string?(@world)
    end

    def entry_path = File.expand_path(entry, root)

    # The pack is written to <output>/<namespace>/.
    def pack_dir = File.join(File.expand_path(output, root), namespace)

    def world_datapack_dir
      return nil unless world

      File.join(File.expand_path(world, root), "datapacks", namespace)
    end

    private

    def path_setting(data, key, default)
      value = data.fetch(key, default)
      raise ConfigError, "cuprite.yml: #{key} must be a non-empty path" unless non_empty_string?(value)

      value
    end

    def non_empty_string?(value) = value.is_a?(String) && !value.strip.empty?
  end
end
