# frozen_string_literal: true

module Cuprite
  # Lowers IR to .mcfunction commands.
  #
  # Conventions:
  # - Locals are fake players "$<fn>.<var>" in <ns>.vars, globals are "$<name>"
  #   in <ns>.globals, registers and constants live in <ns>.rt.
  # - nil is an unset score; booleans are 0/1.
  # - A method's return value is left in "$ret <ns>.rt".
  class Codegen
    attr_reader :names, :constants

    def initialize(program, types, names, pack, test_mode: false)
      @program = program
      @types = types
      @names = names
      @pack = pack
      @test_mode = test_mode
      @constants = Set.new
      @block_count = 0
    end

    def generate
      @program.functions.each_value { |fn| generate_function(fn) }
    end

    # Resource path of the function implementing Ruby method `name` (§4.5).
    def function_path(name)
      @program.functions.fetch(name) # must exist
      @paths ||= begin
        index = 0
        @program.functions.keys.to_h do |n|
          if n.match?(/\A[a-z0-9_]+\z/) && !n.start_with?("__")
            [n, n]
          else
            [n, "__m/#{index += 1}"]
          end
        end
      end
      @paths.fetch(name)
    end

    # Score reference "<holder> <objective>" for an operand slot.
    def ref(slot)
      case slot
      when IR::Local then "$#{slot.fn}.#{slot.name} #{names.vars}"
      when IR::Global then "#{slot.name} #{names.globals}"
      when :ret then "$ret #{names.rt}"
      else raise ArgumentError, "not a slot: #{slot.inspect}"
      end
    end

    def rt(register) = "$#{register} #{names.rt}"

    private

    def generate_function(fn)
      @fn = fn
      lines = []
      fn.maybe_unassigned.each { |v| lines << "scoreboard players reset #{ref(v)}" }
      lines.concat(compile_block(fn.body))
      @pack.add_function(function_path(fn.name), lines)
    end

    def compile_block(block)
      out = []
      block.each { |ins| compile_instr(ins, out) }
      out
    end

    def compile_instr(ins, out)
      case ins
      when IR::Move then move(ins.dst, ins.src, out)
      when IR::Return
        move(:ret, ins.src, out)
        out << "return 0"
      else
        raise Error, "codegen: unsupported instruction #{ins.class}"
      end
    end

    # dst = src, where src may be a constant, a slot, or nil.
    def move(dst, src, out)
      case src
      when IR::Const
        out << if src.value.nil?
                 "scoreboard players reset #{ref(dst)}"
               else
                 "scoreboard players set #{ref(dst)} #{src.value}"
               end
      else
        return if src == dst

        if @types.nilable?(src)
          out << "scoreboard players reset #{ref(dst)}"
          out << "execute if score #{ref(src)} matches #{ANY} run scoreboard players operation #{ref(dst)} = #{ref(src)}"
        else
          out << "scoreboard players operation #{ref(dst)} = #{ref(src)}"
        end
      end
    end

    ANY = "-2147483648.."
  end
end
