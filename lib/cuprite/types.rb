# frozen_string_literal: true

module Cuprite
  # Whole-program type inference (design §4.1). A type is a set of
  # :int, :bool and :nil. A slot whose type mixes :int and :bool cannot be
  # represented as a score and is a compile error.
  class Types
    EMPTY = Set.new.freeze

    def self.infer(program, file: nil) = new(program, file).tap(&:run)

    def initialize(program, file)
      @program = program
      @file = file
      @types = Hash.new { |h, k| h[k] = Set.new }
      @returns = Hash.new { |h, k| h[k] = Set.new }
      @lines = {} # slot or [:return, fn] => line where a conflicting type arrived
    end

    # Type of an operand.
    def of(operand)
      case operand
      when IR::Const then Set[operand.type]
      else
        t = @types.fetch(operand, EMPTY)
        t.empty? ? Set[:nil] : t
      end
    end

    def return_type(fn_name)
      t = @returns.fetch(fn_name, EMPTY)
      t.empty? ? Set[:nil] : t
    end

    def nilable?(operand) = of(operand).include?(:nil)

    def run
      loop do
        @changed = false
        @program.functions.each_value { |fn| visit_function(fn) }
        break unless @changed
      end
      check
    end

    private

    def add(slot, type_set)
      before = @types[slot].size
      @types[slot].merge(type_set)
      return if @types[slot].size == before

      @changed = true
      @lines[slot] ||= @line if conflict?(@types[slot])
    end

    def add_return(fn_name, type_set)
      before = @returns[fn_name].size
      @returns[fn_name].merge(type_set)
      return if @returns[fn_name].size == before

      @changed = true
      @lines[[:return, fn_name]] ||= @line if conflict?(@returns[fn_name])
    end

    def conflict?(t) = t.include?(:int) && t.include?(:bool)

    def visit_function(fn)
      # Unassigned globals read as nil, and globals persist across runs.
      @program.globals.each { |g| add(g, [:nil]) }
      fn.maybe_unassigned.each { |v| add(v, [:nil]) }
      IR.each_instr(fn.body) { |ins| visit(fn, ins) }
    end

    def visit(fn, ins)
      @line = ins.line
      case ins
      when IR::Move then add(ins.dst, of(ins.src))
      when IR::Arith then add(ins.dst, [:int])
      when IR::Compare, IR::InRange, IR::Not then add(ins.dst, [:bool])
      when IR::Try then [ins.flag, ins.flag2, ins.saved_ctl, ins.saved_exc].each { |v| add(v, [:int]) }
      when IR::Return then add_return(fn.name, fn.entry_point? ? [:nil] : of(ins.src))
      when IR::Call
        callee = @program.functions.fetch(ins.fn)
        callee.params.zip(ins.args).each { |param, arg| add(param, of(arg)) }
        add(ins.dst, return_type(ins.fn))
      end
    end

    def check
      @returns.each do |name, t|
        next unless conflict?(t)

        raise CompileError.new("method #{name} may return both Integer and true/false",
                               file: @file, line: @lines[[:return, name]])
      end
      @types.each do |slot, t|
        next unless conflict?(t)

        raise CompileError.new("#{describe(slot)} may hold both Integer and true/false, which cannot be represented",
                               file: @file, line: @lines[slot])
      end
    end

    def describe(slot)
      case slot
      when IR::Global then "global #{slot.name}"
      when IR::Local
        slot.name.start_with?("%") ? "an expression in #{slot.fn}" : "variable #{slot.name} in #{slot.fn}"
      else slot.to_s
      end
    end
  end
end
