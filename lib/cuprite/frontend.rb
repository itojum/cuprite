# frozen_string_literal: true

module Cuprite
  # Lowers the Prism AST to Cuprite IR.
  class Frontend
    def initialize(file:)
      @file = file
    end

    def build(root)
      @program = IR::Program.new
      main = IR::Function.new("main", kind: :main, line: 1)
      @program.add_function(main)
      with_function(main) do
        value = compile_body(root.statements)
        emit IR::Return.new(src: value)
      end
      @program
    end

    private

    def with_function(fn)
      saved = [@fn, @block]
      @fn = fn
      @block = fn.body
      yield
    ensure
      @fn, @block = saved
    end

    def emit(ins)
      ins.line ||= @line
      @block << ins
      ins
    end

    def error(message, node = nil)
      line = node ? node.location.start_line : @line
      raise CompileError.new(message, file: @file, line: line)
    end

    # Compiles a StatementsNode (or nil) and returns the operand holding the
    # value of its last statement.
    def compile_body(node)
      return IR::Const.nil if node.nil?

      value = IR::Const.nil
      node.body.each { |stmt| value = compile_expr(stmt) }
      value
    end

    def compile_expr(node)
      @line = node.location.start_line
      case node
      when Prism::NilNode then IR::Const.nil
      else error("unsupported syntax: #{node.type}", node)
      end
    end
  end
end
