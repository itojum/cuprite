# frozen_string_literal: true

module Cuprite
  # Every name the compiler puts into the world. All compiler-owned state is
  # scoped to the pack namespace (design §5), so two Cuprite packs never share
  # objectives or storage.
  class Names
    NAMESPACE_PATTERN = /\A[a-z0-9_.-]+\z/

    attr_reader :ns

    def initialize(ns)
      raise ConfigError, "invalid namespace #{ns.inspect}" unless ns.is_a?(String) && ns.match?(NAMESPACE_PATTERN)
      raise ConfigError, "namespace #{ns.inspect} is reserved" if ns == "minecraft"
      # The namespace is a directory name that Pack#write replaces recursively.
      raise ConfigError, "invalid namespace #{ns.inspect}" if %w[. ..].include?(ns)

      @ns = ns
    end

    # Objective holding local variables (fake players "$<fn>.<var>").
    def vars = "#{ns}.vars"

    # Objective holding global variables (fake players "$<name>").
    def globals = "#{ns}.globals"

    # Objective holding runtime registers and constants.
    def rt = "#{ns}.rt"

    # Compiler-owned data storage.
    def storage = "#{ns}:__runtime"

    # Storage that mirrors program output in test mode (design §3).
    def test_storage = "#{ns}:__test"

    def function(path) = "#{ns}:#{path}"

    # Score holder for a constant, initialised by __init.
    def const(value) = "#c#{value}"
  end
end
