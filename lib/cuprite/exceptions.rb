# frozen_string_literal: true

module Cuprite
  # Exception classes and their integer IDs (design §7). IDs are assigned in
  # depth-first preorder, so a class and its subclasses form one contiguous
  # range and `rescue C` is a single `matches lo..hi` test.
  class ExceptionTable
    BUILTIN = {
      "Exception" => nil,
      "StandardError" => "Exception",
      "RuntimeError" => "StandardError",
      "ArgumentError" => "StandardError",
      "TypeError" => "StandardError",
      "ZeroDivisionError" => "StandardError",
      "NameError" => "StandardError",
      "NoMethodError" => "NameError",
      "Cuprite::AlreadyRunningError" => "StandardError"
    }.freeze

    def initialize
      @parent = BUILTIN.dup
    end

    def known?(name) = @parent.key?(name)

    def define(name, parent)
      raise ArgumentError, "unknown superclass #{parent}" unless known?(parent)

      @parent[name] = parent
      @ids = nil
    end

    def id(name) = ranges.fetch(name).first

    # The IDs matched by `rescue name`.
    def range(name) = ranges.fetch(name)

    def names = @parent.keys

    def name_of(id) = ranges.find { |_, r| r.first == id }&.first

    private

    def ranges
      @ids ||= begin
        children = Hash.new { |h, k| h[k] = [] }
        @parent.each { |c, p| children[p] << c }
        out = {}
        counter = 0
        visit = lambda do |c|
          first = counter += 1
          children[c].each { |k| visit.call(k) }
          out[c] = first..counter
        end
        visit.call("Exception")
        out
      end
    end
  end
end
