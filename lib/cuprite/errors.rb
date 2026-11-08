# frozen_string_literal: true

module Cuprite
  class Error < StandardError; end

  # Invalid or missing cuprite.yml settings.
  class ConfigError < Error; end

  # A problem in the Ruby source being compiled. Carries the source location
  # so the CLI can report "file:line: message".
  class CompileError < Error
    attr_reader :file, :line

    def initialize(message, file: nil, line: nil)
      @file = file
      @line = line
      super(message)
    end

    def to_s
      where = [file, line].compact.join(":")
      where.empty? ? super : "#{where}: #{super}"
    end
  end
end
