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
      @changed = true if @types[slot].size != before
    end

    def add_return(fn_name, type_set)
      before = @returns[fn_name].size
      @returns[fn_name].merge(type_set)
      @changed = true if @returns[fn_name].size != before
    end

    def visit_function(fn)
      fn.maybe_unassigned.each { |v| add(v, [:nil]) }
      IR.each_instr(fn.body) { |ins| visit(fn, ins) }
    end

    def visit(fn, ins)
      case ins
      when IR::Move then add(ins.dst, of(ins.src))
      when IR::Return then add_return(fn.name, of(ins.src))
      end
    end

    def check
      @types.each do |slot, t|
        next unless t.include?(:int) && t.include?(:bool)

        raise CompileError.new("#{describe(slot)} may hold both Integer and true/false, which cannot be represented",
                               file: @file)
      end
      @returns.each do |name, t|
        next unless t.include?(:int) && t.include?(:bool)

        raise CompileError.new("method #{name} may return both Integer and true/false", file: @file)
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
