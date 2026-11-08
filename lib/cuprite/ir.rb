# frozen_string_literal: true

require "set"

module Cuprite
  # Cuprite IR: three-address instructions over score slots, with structured
  # control flow (blocks nest instead of jumping, because .mcfunction has no
  # goto; each nested block becomes its own function in code generation).
  module IR
    # --- Operands ----------------------------------------------------------

    # A local variable or compiler temporary of function `fn`.
    Local = Data.define(:fn, :name) do
      def to_s = "#{fn}.#{name}"
    end

    # A global variable ($name), persistent across runs (design §4.4).
    Global = Data.define(:name) do
      def to_s = name
    end

    # A compile-time constant. value is an Integer (booleans are 0/1) or nil.
    Const = Data.define(:value, :type) do
      def self.int(v) = new(v, :int)
      def self.bool(v) = new(v ? 1 : 0, :bool)
      def self.nil = new(nil, :nil)
      def to_s = type == :nil ? "nil" : (type == :bool ? (value == 1).to_s : value.to_s)
    end

    # --- Instructions ------------------------------------------------------

    def self.instr(*fields)
      Struct.new(*fields, :line, keyword_init: true)
    end

    # dst = src
    Move = instr(:dst, :src)
    # dst = a <op> b, op in :+ :- :* :/ :% :** (32-bit wrapping)
    Arith = instr(:dst, :op, :a, :b)
    # dst = (a <op> b), op in :== :!= :< :<= :> :>=
    Compare = instr(:dst, :op, :a, :b)
    # dst = lo <= src && src <= hi (lo / hi are Integers or nil for open ends)
    InRange = instr(:dst, :src, :lo, :hi)
    # dst = !src (Ruby truthiness)
    Not = instr(:dst, :src)
    # Runs then_body if cond is truthy, else_body otherwise.
    If = instr(:cond, :then_body, :else_body)
    # Prints lines. Each line is an Array of parts: a String, or
    # [operand, :to_s | :inspect].
    Print = instr(:lines)
    # Repeats body until a Break (or an unwind) leaves it.
    Loop = instr(:body)
    # Leaves the innermost Loop.
    Break = instr()
    # Starts the next iteration of the innermost Loop.
    Next = instr()
    # Return src from the current function.
    Return = instr(:src)
    # dst = fn(args...) for a user method.
    Call = instr(:dst, :fn, :args)

    # --- Program structure -------------------------------------------------

    class Function
      attr_reader :name, :kind, :params, :line, :locals, :maybe_unassigned
      # Literal default values of optional parameters (nil for required ones).
      attr_accessor :body, :defaults

      # kind: :main, :method, :on_load or :on_tick
      def initialize(name, kind:, params: [], line: nil)
        @name = name
        @kind = kind
        @params = params
        @line = line
        @body = []
        @locals = Set.new(params)
        # Locals that may be read before being assigned; they read as nil and
        # are reset on entry.
        @maybe_unassigned = Set.new
        @defaults = []
        @temp_count = 0
      end

      def local(name)
        var = Local.new(self.name, name)
        @locals << var
        var
      end

      def temp
        @temp_count += 1
        local("%#{@temp_count}")
      end

      def entry_point? = kind != :method
    end

    class Program
      attr_reader :functions, :globals

      def initialize
        @functions = {}
        @globals = Set.new
      end

      def add_function(fn)
        @functions[fn.name] = fn
      end

      def main = @functions.fetch("main")
    end

    # Visits every instruction, descending into nested blocks.
    def self.each_instr(block, &visit)
      block.each do |ins|
        visit.call(ins)
        nested_blocks(ins).each { |b| each_instr(b, &visit) }
      end
    end

    def self.nested_blocks(ins)
      ins.class.members.filter_map do |m|
        v = ins[m]
        v if v.is_a?(Array) && v.all? { |x| x.is_a?(Struct) }
      end
    end
  end
end
