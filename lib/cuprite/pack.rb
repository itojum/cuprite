# frozen_string_literal: true

require "fileutils"
require "json"
require "digest"

module Cuprite
  # An in-memory data pack: a map from relative path to file content.
  class Pack
    # Data pack format for Minecraft Java Edition 26.3 (design §1).
    FORMAT = [121, 0].freeze

    attr_reader :files

    def initialize(namespace, description: "Compiled by Cuprite")
      @ns = namespace
      @files = {}
      @files["pack.mcmeta"] = JSON.pretty_generate(
        "pack" => { "description" => description, "min_format" => FORMAT, "max_format" => FORMAT.first }
      ) + "\n"
    end

    def add_function(path, lines)
      file = "data/#{@ns}/function/#{path}.mcfunction"
      raise Error, "duplicate function #{path}" if @files.key?(file)

      @files[file] = lines.join("\n") + "\n"
    end

    def function?(path) = @files.key?("data/#{@ns}/function/#{path}.mcfunction")

    def function_lines(path)
      @files.fetch("data/#{@ns}/function/#{path}.mcfunction").split("\n")
    end

    # Adds entries to a function tag, e.g. tag("minecraft", "load", [...]).
    def tag(namespace, name, values)
      @files["data/#{namespace}/tags/function/#{name}.json"] = JSON.pretty_generate("values" => values) + "\n"
    end

    def tag_values(namespace, name)
      file = @files["data/#{namespace}/tags/function/#{name}.json"]
      file ? JSON.parse(file).fetch("values") : []
    end

    # Writes the pack to dir, replacing whatever was there.
    def write(dir)
      FileUtils.rm_rf(dir)
      @files.each do |rel, content|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
    end
  end
end
