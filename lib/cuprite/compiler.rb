# frozen_string_literal: true

require "prism"
require_relative "ir"
require_relative "frontend"
require_relative "types"
require_relative "call_graph"
require_relative "codegen"
require_relative "runtime"

module Cuprite
  # Pipeline (design §2): Prism AST → IR → type inference → code generation.
  class Compiler
    attr_reader :names

    # test_mode: also mirror program output into data storage so a test
    # harness can read it back (design §3).
    def initialize(source, namespace:, debug: false, file: "(source)", test_mode: false)
      @source = source
      @names = Names.new(namespace)
      @debug = debug
      @file = file
      @test_mode = test_mode
    end

    def compile
      result = Prism.parse(@source, filepath: @file)
      unless result.errors.empty?
        err = result.errors.first
        raise CompileError.new("syntax error: #{err.message}", file: @file, line: err.location.start_line)
      end

      program = Frontend.new(file: @file).build(result.value)
      types = Types.infer(program, file: @file)
      pack = Pack.new(names.ns)
      codegen = Codegen.new(program, types, names, pack, test_mode: @test_mode, file: @file)
      codegen.generate
      Runtime.new(program, names, pack, codegen, debug: @debug).generate
      pack
    end
  end
end
